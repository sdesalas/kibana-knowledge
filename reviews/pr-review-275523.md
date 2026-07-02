# PR Review: #275523 — [Security Solution][Detection Engine] Optimizes prebuilt rule installation endpoint

**PR:** [elastic/kibana#275523](https://github.com/elastic/kibana/pull/275523) by @jr-araque

**Scale:** Substantive — new client method, handler rewrite, new conversion path, 417 lines of tests. Touches the hot path for installing ~1900 prebuilt rules.

**Ownership:** All 7 files are under `x-pack/solutions/security/plugins/security_solution/.../detection_engine/` — squarely `@elastic/security-detection-rule-management` / Detection Engineering territory. The one external dependency (`rulesClient.bulkCreateRules`) is owned by the alerting/response-ops team but is *consumed* here, not modified.

---

## Context / Motivation
d
Resolves [#264907](https://github.com/elastic/kibana/issues/264907). Prebuilt rule install currently loops in batches of 100 and calls `createPrebuiltRule` one-by-one through a promise pool (concurrency 20), producing ~1900 individual SavedObject writes for a full install. That's slow, and concurrent installs across multiple spaces have previously caused OOM on low-memory instances ([security-team#11822](https://github.com/elastic/security-team/issues/11822), [#188090](https://github.com/elastic/kibana/issues/188090)).

The issue explicitly flags a hard constraint:

> **WARNING:** verify memory headroom is maintained by testing on an ECH **1GB** instance — install all prebuilt rules and monitor heap usage.

The dependency (`RulesClient.bulkCreateRules`) landed in [#269340](https://github.com/elastic/kibana/pull/269340).

## Validating the issue — does this PR address it?

The concern is valid and the PR addresses it correctly. The old path in `create_prebuilt_rules.ts` fans out via `initPromisePool` → `createPrebuiltRule` → `rulesClient.create`, one SO write per rule. The new path fetches assets in chunks of 500 and hands each chunk to `rulesClient.bulkCreateRules`, which internally batches SO writes in groups of 100 (`DEFAULT_BULK_CREATE_BATCH_SIZE`) using `bulkCreateRulesSo`. That collapses ~1900 round-trips to ~20 bulk writes. The author's numbers (~5x faster, ~99% fewer ES round-trips) are consistent with that structural change.

The memory angle is the real subtlety: passing all 1900 rules at once pushed RSS over the 1GB limit because the converted array and the framework's validation copy coexist. The 500-chunk handler loop keeps only one chunk of assets live at a time (each iteration's `batch`/`ruleAssets` is block-scoped and GC-eligible before the next fetch). This is a reasonable mitigation — but see Open questions: it's still pending verification on real ECH 1GB hardware.

## Summary

Replaces the sequential promise-pool install loop with a true bulk write. Adds a new `bulkCreatePrebuiltRules` method to the detection rules client that converts a chunk of prebuilt rule assets and delegates to `rulesClient.bulkCreateRules()`. The handler now iterates the install queue in chunks of 500, fetching assets and bulk-creating per chunk. The API request/response shape is unchanged. `createPrebuiltRules` (the old path) is left in place — it still has 4 other callers, so this is additive rather than a full replacement.

## Files touched

- **Handler** — `perform_rule_installation_handler.ts`: swaps the `while (queue.length) { splice(0,100); createPrebuiltRules() }` loop for a `for` loop stepping in 500s, calling `detectionRulesClient.bulkCreatePrebuiltRules`. Drops the `lodash.pick` (the new result type is already exactly `{id, rule_id, version}`).
- **New method** — `methods/bulk_create_prebuilt_rules.ts`: the core of the PR. Validates ML auth once per unique type, filters unsupported types, converts each asset to the alerting-rule shape, pre-assigns a UUID per rule, calls `bulkCreateRules`, then maps `successfulIds` and framework errors back to per-rule results/errors.
- **Client wiring** — `detection_rules_client.ts` (4-line delegate w/ `withSecuritySpan`), `detection_rules_client_interface.ts` (new args/result types), `__mocks__/detection_rules_client.ts` (mock entry).
- **Constant** — `constants.ts`: adds `PREBUILT_RULES_BULK_CREATE_BATCH_SIZE = 500`.
- **Tests** — `detection_rules_client.bulk_create_prebuilt_rules.test.ts`: 417 lines, 12 unit tests.

## Flow trace (ALL_RULES install)

1. Handler resolves clients, ensures the rules package is installed, builds `ruleInstallQueue` of `{rule_id, version}` (license-restricted rules excluded via `excludeLicenseRestrictedRules`).
2. Loop steps `i += 500`; each iteration slices a `batch` of ≤500 and calls `ruleAssetsClient.fetchAssetsByVersion(batch)` → `ruleAssets`.
3. `bulkCreatePrebuiltRules({ rules: ruleAssets })` → `validateRules`: dedupes rule types into a `Set`, runs `validateMlAuth` once per type, caches any error per type. Rules whose type failed ML auth, or whose `type` isn't in `ruleTypeMappings`, go straight to `errors`.
4. For each valid rule: `applyRuleDefaults({...rule, immutable: true})`, then `convertRuleResponseToAlertingRule(...)` + `{alertTypeId, consumer: SERVER_APP_ID, enabled: rule.enabled ?? false}`. A fresh `uuidv4()` is stored in `itemById` and set as `options.id`. Per-rule conversion is wrapped in try/catch so one bad rule doesn't sink the chunk.
5. `rulesClient.bulkCreateRules<RuleParams>({ rules: bulkInputs, changeTracking: {action: ruleInstall, metadata: {bulkCount: rules.length}} })`.
6. Framework `preValidate` runs schema/registry/param checks per rule (per-rule errors), then `bulkEnsureAuthorized` (throws whole-request on any unauthorized type/consumer pair), then schedule-limit check (only for `enabled` rules → no-op here since all disabled).
7. Framework writes in internal batches of 100; per-row SO errors (e.g. 409) come back in `errors` with `{message, status, rule:{id,name}}`.
8. Back in `bulkCreatePrebuiltRules`: `successfulIds` → `results` via `itemById` lookup (`{id, rule_id: asset.rule_id, version: asset.version}`); `bulkErrors` → `errors` via `itemById.get(err.rule.id)`, attaching `statusCode` from `err.status`. A top-level `catch` maps any thrown framework error onto **every** item in the chunk.
9. Handler pushes `results` into `installedRules`, `errors` into `ruleErrors`, then `aggregatePrebuiltRuleErrors` collapses errors by message (reads `item.rule_id`, `item.name`, `getErrorStatusCode(error)` → `error.statusCode`).

I checked the type/shape hand-offs and they line up: `BulkCreatePrebuiltRulesResultItem` is `{id, rule_id, version}`, identical to `InstalledRuleBasicInfo`; the error `item` is a `PrebuiltRuleAsset` (has `rule_id` + `name`), which is what `aggregatePrebuiltRuleErrors` reads; and the manually-attached `statusCode` is exactly what `getErrorStatusCode` looks for.

## Assumptions

- **`options.id` is honoured by the framework.** The `successfulIds`→`results` correlation relies on `bulkCreateRules` using the caller-supplied `options.id` as the SO id. Confirmed in `bulk_create_rules.ts`: `inputs` maps `rule.options?.id ?? generateId()`, and per-row outcomes key on `so.id`. Holds.
- **All prebuilt security rule types share one authz pair** (`security` consumer + a security `alertTypeId`), so the framework's all-or-nothing `bulkEnsureAuthorized` won't partially fail. Likely true in practice, but it's a behavior change from per-rule authz (see Risks).
- **Some assets *can* carry `enabled: true`.** Not an assumption but a confirmed fact: `enabled: rule.enabled ?? false` was added in commit `ea82838` specifically because hardcoding `false` broke Cypress Coverage Overview tests that install mock assets with `enabled: true`. Real prebuilt rules still install disabled, so the schedule-limit circuit breaker stays a no-op in production, but the code correctly honours the field.
- **Chunk of 500 is within framework limits.** `MAX_RULES_NUMBER_FOR_BULK_OPERATION = 10000` and `MAX_BULK_CREATE_BATCH_SIZE = 500`; the PR passes 500 rules per call and lets the framework use the default internal batch of 100. Fine. The 500-vs-1000 tradeoff was discussed on the PR — 1000 shaves ~10% off wall-clock but 500 was kept deliberately as the safer memory ceiling.
- **`fetchAssetsByVersion` handles 500 ids per call** (up from the old 100). Confirmed intentional — the handler-level 500-chunk was the fix for the unbounded-fetch concern, so this is by design rather than an oversight.

## Risks (ordered)

1. ~~**Memory on ECH 1GB is still unverified.**~~ **RESOLVED** (see Review activities #1). Verified on ECH via [comment 4854966432](https://github.com/elastic/kibana/pull/275523#issuecomment-4854966432): with the `security_oom_testing` deployment plan and change-tracking enabled, the PR sits on par with main — ~4x faster install and ~20% lower peak memory. The OOM testing pipeline was also run (builds 1758/1759/1770/1775). The original unbounded-`fetchAssetsByVersion` concern I raised was resolved mid-review by moving the 500-chunk boundary up into the handler (commits `6d1c192`, `afd40f5`). Core risk is closed.
2. **All-or-nothing authz per chunk.** `bulkEnsureAuthorized` throws for the whole request on any unauthorized type/consumer pair; the top-level `catch` then maps that single failure onto all ≤500 items as errors. The old per-rule path would only have failed the offending rules. Low practical risk for prebuilt rules (uniform authz), but it's a real semantic change — one unexpected authz edge fails a whole chunk.
3. **Cross-chunk partial persistence.** If chunk N succeeds and chunk N+1 throws at the handler level, chunk N's rules are already persisted. Author documents this as low severity and self-correcting on retry (409 per already-created rule). Reasonable, but the handler `for` loop has no try/catch, so a throw from `bulkCreatePrebuiltRules` (only happens if something outside its own try/catch throws — e.g. `fetchAssetsByVersion`) propagates to the outer handler catch and returns a 500 with earlier chunks already written. Matches prior behavior roughly, but worth being explicit about.
4. **Conversion logic is duplicated from `create_rule.ts`.** The `applyRuleDefaults` + `convertRuleResponseToAlertingRule` + `{alertTypeId, consumer, enabled}` block is copy-pasted. If `createRule`'s conversion changes (e.g. a new required field), the bulk path silently drifts. Not a correctness bug today, but a maintenance trap — a shared helper would keep the two in lockstep. Given prebuilt rules already diverge from custom rules, this matters.
5. **`bulkCount` change-tracking metadata regressed for large installs.** Flagged by the bot reviewer and worth tracking. The old handler set `bulkCount: ruleInstallQueue.length` (the **total** install count) once before the loop; `createPrebuiltRules` then spread `...changeTracking?.metadata` last so the total always won. The new method sets `bulkCount: rules.length` where `rules` is the per-handler-batch chunk (≤500). So a full ~1900-rule install now writes `bulk_count = 500` (or the final partial batch) into each rule's change-history entry instead of the true total. Low severity — persisted audit metadata only, not the API response — but silent, and the `change_tracking.ts` integration test only installs 2 rules so nothing catches it. Fixing means plumbing the total count down from the handler into `BulkCreatePrebuiltRulesArgs`, or consciously accepting per-batch semantics and updating the test.
6. **No API integration test.** The linked issue's todo lists "Add API integration tests"; the PR only adds unit tests (checklist item unchecked). The unit tests mock `rulesClient.bulkCreateRules`, so nothing here exercises the real framework batching / 409 / authz paths end-to-end. Note: change-tracking *was* exercised manually on ECH (change history enabled during the memory test), just not in automated integration coverage.

## Open questions

- Has the ECH 1GB heap verification been run yet? What were the numbers under *concurrent* multi-space install (the original OOM scenario), not just a single install? The local `process.memoryUsage()` profiling is useful but isn't the same environment.
- Why 500 as the handler chunk size specifically? It happens to equal `MAX_BULK_CREATE_BATCH_SIZE`, but the framework re-batches internally at 100 anyway — so is 500 purely a memory-ceiling knob? If so, is it robust across rule-size variance (some rules have large `params`), or was it tuned to the current ~1900-rule payload?
- Is the copy-pasted conversion block worth extracting into a shared function used by both `createRule` and `bulkCreatePrebuiltRules`? Any reason it wasn't?
- Does `fetchAssetsByVersion` comfortably handle 500 versions per query (terms/should clause size, ES `max_clause_count`)? The old path only ever asked for 100.
- Is losing the debug logging from `createPrebuiltRules` (rules created / failed / error summary) intentional? The new path is silent on outcomes beyond APM spans.

## Notes for your codebase map

- Prebuilt rule install has two layers: the **handler** (`perform_rule_installation_handler.ts`) does eligibility filtering (already-installed, license-restricted) and batching; the **detection rules client** does the actual conversion + persistence. The client is a plain object of methods assembled in `detection_rules_client.ts`, each wrapped in `withSecuritySpan`.
- `rulesClient.bulkCreateRules` (alerting framework, [#269340](https://github.com/elastic/kibana/pull/269340)) is the true-bulk primitive: `preValidate` (per-rule schema + whole-request authz + schedule limit) then per-batch (default 100) SO writes with per-row error reporting. Authz is **fail-whole-request**; SO write errors are **per-row**. It returns `successfulIds: string[]` only — callers must pre-assign `options.id` to correlate results back to inputs.
- Prebuilt rule SO ids are random UUIDs; `rule_id` (the stable signature id) lives in rule params, not the SO id. So pre-assigning UUIDs client-side is safe.
- Error plumbing convention: security bulk operations return `{item, error}[]`, and `aggregatePrebuiltRuleErrors` collapses by message reading `error.statusCode` — so any error surfaced to the handler must carry `statusCode` to report the right HTTP code (the PR does this manually via `Object.assign`).
- `createPrebuiltRules` (promise-pool path) is retained for 4 other callers: promotion rules, endpoint security, legacy install, SIEM migrations. Only the `_perform` install endpoint moved to bulk.

## Review activities

1. **Confirmed the memory risk (Risk 1) is verified on ECH.** Read the full PR conversation. The author tested the PR image (`4664e73`) against main (`966c275`) on ECH using the `security_oom_testing` deployment plan with change-tracking enabled (`xpack.alerting.ruleChangeTracking.enabled: true`, `ruleChangesHistoryEnabled` experimental flag), and reported the PR "on par with main" — ~4x faster install and ~20% lower peak memory ([comment 4854966432](https://github.com/elastic/kibana/pull/275523#issuecomment-4854966432)). The dedicated OOM testing pipeline was also run across four rounds (builds 1758, 1759, 1770, 1775), including a run with change history enabled. This closes the core constraint from issue #264907.

2. **Traced the evolution of the memory fix through the commit history.** The original implementation converted all ~1900 rules at once and pushed RSS over the 1GB ceiling. In review I raised that `fetchAssetsByVersion(ruleInstallQueue)` was unbounded and would only get worse as the rule count grows (~1900 today, ~50%/yr). The author moved the batch boundary up into the handler (commit `6d1c192`, cleaned up in `afd40f5`), so the handler now fetches 500 assets at a time and `bulkCreatePrebuiltRules` no longer loops internally — peak memory is now proportional to one 500-chunk regardless of total rule count. This resolves the assumption/risk I had flagged around the 500-id fetch.

3. **Checked for orphaned code left behind by the migration.** None found. Grepped the three things the PR detached from: `createPrebuiltRules` (old promise-pool path) still has 4 callers — SIEM migrations install, `install_promotion_rules.ts`, `install_endpoint_security_prebuilt_rule.ts`, and legacy `legacy_create_prepackaged_rules.ts`; `PREBUILT_RULE_BATCH_SIZE = 100` is still used by `perform_rule_upgrade_handler.ts` (the upgrade loop this PR didn't touch); and `createPrebuiltRule` (single-rule method) is still called by `createPrebuiltRules` and has its own tests. The removed `lodash.pick` import was the handler's only `pick` use, so dropping it was clean. Nothing to remove — though `createPrebuiltRules` and `bulkCreatePrebuiltRules` now coexist as parallel install paths with duplicated conversion logic, a possible future consolidation (not this PR's scope).
