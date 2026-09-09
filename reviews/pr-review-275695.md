# PR Review: #275695 — [Security Solution] Optimize `rules/_import` (create path) via `bulkCreateRules()`

**PR:** [elastic/kibana#275695](https://github.com/elastic/kibana/pull/275695) by @sdesalas

**Scale:** Substantive.

**Ownership (team: `@elastic/security-detection-engineering`):**
- **Your team's files (39):** every path in this PR matches `/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management` — *reviewed in full, not just this bucket*
- **Other teams' files:** none
- **Unowned:** none

---

### Context / Motivation

[#264909](https://github.com/elastic/kibana/issues/264909) asked to wire `POST /api/detection_engine/rules/_import` through `rulesClient.bulkCreateRules()` for **new** rules, replacing the per-rule create loop. The expected win was ~3x on large imports. Overwrite stays per-rule until `bulkUpdate` lands ([#275204](https://github.com/elastic/kibana/issues/275204)).

The issue originally mentioned a `bulkCreateRulesEnabled` feature flag and a sample patch from [#271722](https://github.com/elastic/kibana/pull/271722). This PR dropped the flag — the bulk create path is the only create path once it merges. That’s intentional, and the PR treats FTR coverage in [#280553](https://github.com/elastic/kibana/pull/280553) / [#280531](https://github.com/elastic/kibana/issues/280531) as the safety net.

> Wire the `rules/_import` flow to use `rulesClient.bulkCreateRules()` for new rules, replacing the existing per-rule loop.

> Existing rules with `overwriteRules: true` can fall back to per-rule for now.

> This replaces the previous import create path **unconditionally** — no feature flag.

---

### Validating the issue — does this PR address it?

**The concern is technically valid. The PR addresses the create-path bottleneck, with a leftover sequential overwrite path and a stricter whole-batch failure mode than today.**

- **Where the problem manifests** — on `main`, the route chunks at 50 and `detectionRulesClient.importRules` runs `Promise.all` over `importRule()`, which does `getRuleByRuleId` + `rulesClient.create` (or `update`) per rule. That’s one find and one create per rule, times every rule in the file.
- **Why the old approach was a problem** — a 1000-rule import is ~1000 alerting creates (plus ~1000 finds). That’s the timeout / wall-time problem in [#249176](https://github.com/elastic/kibana/issues/249176).
- **How the PR fixes it** — one KQL find per outer chunk, then one `rulesClient.bulkCreateRules()` for the new-rule subset. Payload construction matches `createRule()` (`applyRuleDefaults` → `convertRuleResponseToAlertingRule` → `enabled ?? false`).
- **Residual caveat** — overwrite is still `pMap` + `rulesClient.update`. Mixed create+overwrite files still pay the slow path for existing `rule_id`s. And `bulkCreateRules` pre-checks (schedule-limit, authz) throw for the **whole call**, which is stricter than per-rule `create`.

---

### Summary

New rules on `rules/_import` go through `rulesClient.bulkCreateRules()` in chunks of 200, with no feature flag. Existing `rule_id`s still update one-by-one. The old `importRule()` method and `RuleSourceImporter` class are gone; their jobs live in a new `methods/import_rules/` folder (validate → split → overwrite / create). HTTP response shape is still `{ rule_id, status_code }` / per-rule errors. Stated intent matches the diff. The extra surface is the folder split and deleting the singular import API, not a second feature.

---

### Files touched

**Route + constants**
- `api/rules/import_rules/route.ts` — drops the 50-rule chunk and `RuleSourceImporter`; installs the prebuilt package once; forwards `changeTracking.action: ruleImport` + `metadata.bulkCount`.
- `api/constants.ts` — `timeouts.ts` renamed; adds `RULE_IMPORT_BULK_CREATE_BATCH_SIZE` (200) and `RULE_IMPORT_BULK_UPDATE_CONCURRENCY` (50).
- `api/rules/bulk_actions/route.ts`, `api/rules/export_rules/route.ts` — import path only (`timeouts` → `constants`).

**Orchestrator**
- `logic/import/import_rules.ts` — chunks at 200 and calls `detectionRulesClient.importRules` per batch. Maps successes to `{ rule_id }` only; `conflict` → 409, everything else → 400.

**Detection Rules Client**
- `detection_rules_client.ts` / `detection_rules_client_interface.ts` — `importRule` removed; `importRules` takes `rules` + options and returns `{ successes, errors }`. After the pipeline it emits `DETECTION_RULE_IMPORT_EVENT` once per success.
- `methods/import_rule.ts` — deleted. No remaining callers.

**New import pipeline (`methods/import_rules/`)**
- `import_rules.ts` — parallel lookups, validate, split, overwrite, create; concatenates `{ successes, errors }`; outer try/catch turns throws into per-rule errors.
- `validate_rules_to_import.ts` — version default, ML auth, exception refs, `rule_source`.
- `split_into_groups.ts` — conflict / overwrite / create.
- `create_rules.ts` — uuid pairing + `bulkCreateRules`; keeps `id` / `type` / `rule_source` on each success for telemetry.
- `overwrite_rules.ts` — `pMap` + `rulesClient.update` + `toggleRuleEnabledOnUpdate`; same success shape.
- `fetch_prebuilt_import_context.ts` / `find_installed_rules_by_rule_ids.ts` — replace `RuleSourceImporter.setup()`.
- Helpers moved with the folder: `calculate_rule_source_for_import`, `check_rule_exception_references`, `convert_rule_to_import_to_rule_response`, `gather_referenced_exceptions`, `errors`.

**Deleted**
- `logic/import/rule_source_importer/*` — package install moved to the route; asset/installed-rule fetches inlined.

**Tests**
- New/rewritten DRC + helper + orchestrator tests. `import_rule.test.ts` and `rule_source_importer.test.ts` deleted. Route suite is still `describe.skip`.

---

### Flow trace

1. `POST /api/detection_engine/rules/_import` parses NDJSON, imports exceptions/connectors, dedups `rule_id`s, migrates action IDs, validates actions/response actions.
2. Route calls `ensureLatestRulesPackageInstalled` once, then `logic/import/import_rules` with `changeTracking: { action: ruleImport, metadata: { bulkCount } }`.
3. Orchestrator chunks at 250 and calls `detectionRulesClient.importRules` per chunk.
4. DRC `importRules` runs three lookups in parallel: referenced exception lists, prebuilt assets (`fetchLatestVersions` + `fetchDeprecatedRules` + `fetchAssetsByVersion`), installed rules via a quoted KQL OR-list on `params.ruleId`.
5. `validateRulesToImport` per rule: prebuilt-without-version → error and skip; ML auth fail → error and skip; missing exception list → **warning error, rule still proceeds** with the dangling ref stripped; version defaults to 1; `rule_source` / `immutable` calculated.
6. `splitIntoGroups`: unknown `rule_id` → create; existing + overwrite → update; existing + no overwrite → 409.
7. Overwrite: `applyRuleUpdate` + `rulesClient.update` + `toggleRuleEnabledOnUpdate`, concurrency 50.
8. Create: `applyRuleDefaults` + convert + `bulkCreateRules({ batchSize: 200 })`. Caller-generated uuids are re-paired to `rule_id`.
9. If anything in the try throws (find, prebuilt fetch, `bulkCreateRules` pre-check), remaining `rule_id`s that aren’t already in `successes` or `errors` get that error message.
10. Client emits `DETECTION_RULE_IMPORT_EVENT` for each success (`ruleId` is the SO `id`). Orchestrator maps successes to `{ rule_id }` and errors to `BulkError`. Route uses `successes.length` for `success_count`.

---

### Assumptions

- `rulesClient.bulkCreateRules` from [#269340](https://github.com/elastic/kibana/pull/269340) is a faithful bulk equivalent of `rulesClient.create` for SIEM rules (API keys, task scheduling, connector secrets, change history). The create payload is copied from `createRule()`.
- Callers always cap a single `importRules` invocation at `RULE_IMPORT_BULK_CREATE_BATCH_SIZE` (200). That’s what keeps the KQL OR-list under ES’s 1024 `max_clause_count` floor. Only the orchestrator enforces it; the DRC method does not.
- `findRules({ perPage: ruleIds.length })` will actually return all matches. No extra pagination.
- In-file duplicate `rule_id`s are gone before this pipeline — `getTupleDuplicateErrorsAndUniqueRules` in the route.
- `bulkCreateRules` echoes `options.id` in `successfulIds` / `errors[].rule.id`. Pairing depends on that. Same pattern as `bulkCreatePrebuiltRules`.
- Route-level `RULES_API_ALL` means alerting `bulkEnsureAuthorized` won’t reject a mixed-type batch for rule-type privileges. If that’s ever not true, one unauthorized type fails the whole create batch.
- `allowMissingConnectorSecrets` is create-only. Overwrite never passed it on `main` either.
- Exception-list “errors” are warnings: the rule is still created/updated with the ref removed. Same as `main`.
- ~~FTR in [#280553](https://github.com/elastic/kibana/pull/280553) / [#280531](https://github.com/elastic/kibana/issues/280531) is the contract-parity net. This PR’s own checklist still has that unverified.~~ STALE — FTR landed and is on this branch; CI has been running it.

---

### Risks

1. **Whole-batch schedule-limit fail.** `bulkCreateRules` sums every **enabled** interval, then throws before any writes if the circuit breaker trips — the whole chunk fails, including disabled rules in that chunk. Mixed files are possible. Customer fix is the same as today’s cap hit: delete the uploaded rules in the space, disable some, re-upload. LOW PRIORITY. Extra engineering (split/retry/alerting) has questionable ROI. Instead, dropping the batch 250->200 (already wanted) mitigates the blast radius. See review activity 5.
2. **Exception-list warnings hide the real error.** `checkRuleExceptionReferences` pushes a warning **and** keeps the rule importable. The outer catch builds `responded` from every error `ruleId`. If `bulkCreateRules` later throws, that rule does not get the real failure message. The client sees “Reference has been removed” and `success_count: 0` — the warning implies the import continued. Why this is risky: dangling exception list + schedule-limit/authz throw in the same chunk.
3. ~~**No feature flag, FTR dependency not checked off.** Create-path contract changes go out to every import on merge. Unit tests cover the new pipeline; the route suite is still `describe.skip`; the PR’s own checklist still has FTR + manual + perf matrix open.~~ STALE — FTR ([#280553](https://github.com/elastic/kibana/pull/280553)) landed 2026-07-27, is on this branch, and has been running in CI. See review activity 4.
4. **`RULE_IMPORT_BULK_CREATE_BATCH_SIZE` is provisional (200).** Raising it toward 500 without splitting the KQL find reintroduces a whole-batch ES clause failure. The helper test guards the current constant, not a future bump at the call site.
5. **Create-error pairing can drop a row.** If `successfulIds` / `errors[].rule.id` don’t match the uuid map, `createRules` skips the row and does not throw, so the outer catch won’t backfill it. Unlikely if alerting keeps echoing `options.id`; there’s no test that the map is complete after a bulk response.
6. **Per-rule conversion isolation is untested on this path.** `createRules` wraps `applyRuleDefaults` / convert in try/catch so one bad rule shouldn’t fail the batch. `bulkCreatePrebuiltRules` has a test for that; this suite doesn’t.
7. **Duplicate-import race (TOCTOU), possibly worse.** `rule_id` uniqueness is still check-then-create. Lookup is per 200-chunk, then a long `bulkCreateRules`. Two overlapping POSTs of the same file can both see empty and both create. Pre-existing ([#176207](https://github.com/elastic/kibana/issues/176207)); this PR likely makes it easier (chunk 50 → 200, one snapshot covers a slow 200-wide insert). See review activity 1.

---

### Open questions

1. ~~**(Risk 1)** For an all-enabled file that overflows the schedule cap, is “fail the whole 200-chunk” the contract you want, or “import until the cap, fail the rest” (today’s per-rule `create`)? Mixed enabled/disabled is not a real upload shape.~~ Accepted — mixed is possible; customer already deletes-and-reuploads on a cap hit; don’t go over and above. Batch 200 mitigates. See review activity 5.
2. **(Risk 2)** Should the outer catch treat exception-list warnings as non-terminal, so a later whole-batch throw still attaches the real error?
3. **(Risk 4)** Is 200 locked enough to merge, or does this wait on the 100/200/250/300/500 × 1000/2000 × enabled/disabled matrix in the PR?
4. ~~**(Risk 3)** Has [#280553](https://github.com/elastic/kibana/pull/280553) / [#280531](https://github.com/elastic/kibana/issues/280531) actually landed on `main` and been re-run against this branch? The checklist says no.~~ STALE — yes, landed, merged into this branch, running in CI.
5. The skipped route test still expects ML authz to come back as **403**; the orchestrator maps every non-conflict error to **400** (same as `main`). If that suite gets unskipped, that case will fail — is 400 the public contract?

---

### Notes for your codebase map

- Detection-rule import is now a pipeline inside `methods/import_rules/`: lookup → validate → split → overwrite | create. The singular `importRule()` API is gone.
- `RuleSourceImporter` is gone. Package install is a route-level `ensureLatestRulesPackageInstalled`. Asset + installed-rule fetches are plain functions (`fetchPrebuiltImportContext`, `findInstalledRulesByRuleIds`).
- Installed-rule lookup by `rule_id` is a quoted KQL OR-list on `alert.attributes.params.ruleId`. The existing `findRules({ ruleIds })` option filters **SO** `alert.id`, not signature `rule_id` — don’t use it here. The old `fetchInstalledRulesByIds` did the same KQL without quoting; this helper is stricter.
- `createRules` is the same shape as `bulkCreatePrebuiltRules`: caller uuid, `applyRuleDefaults`, `enabled ?? false`, re-pair `successfulIds`.
- `bulkCreateRules` preValidate throws on authz and schedule-limit **before any ES writes**. Per-rule schema/interval failures stay in `errors`. Task-schedule failures exclude only the enabled subset.
- Exception-list failures on import are warnings: error object + rule still created with the ref stripped. That’s older behavior, now more visible because the catch uses those errors as “already handled.”
- Outer chunk size used to be 50 (`CHUNK_PARSED_OBJECT_SIZE` in the route). It’s now 200, shared with `bulkCreateRules`’s `batchSize`.

---

### Review activities

1. **Local debugging: Duplicate-import race (1000 uploaded → 2000 persisted) — Risk 7.** Pre-existing TOCTOU ([#176207](https://github.com/elastic/kibana/issues/176207#issuecomment-4903270379)), possibly aggravated here by larger batches. Checked whether this PR looks up all `rule_id`s up front (vs per-batch) and whether the h2o2 120s browser retry explains a clean 2×.

- Lookup is per 200-rule chunk, not once for the whole file. `logic/import/import_rules.ts` chunks; each `methods/import_rules/import_rules.ts` call runs `findInstalledRulesByRuleIds` for that batch only.
- The race is TOCTOU inside the batch: one find snapshot, then a long `bulkCreateRules` (API keys, tasks, SO write). `createRules` mints new `uuidv4()` SO ids; alerting uniqueness is on SO id, not `params.ruleId`.
- Two overlapping POSTs of the same file can both see empty for the same 200 ids and both create. Sequential batches do not protect each other — batch 2 looks up different ids.
- This is pre-existing ([#176207](https://github.com/elastic/kibana/issues/176207)): `rule_id` uniqueness is check-then-create, not enforced at persist. Old path raced per rule (`getRuleByRuleId` then `create`). This PR likely aggravated it — chunk grew 50 → 200, and one snapshot now covers a slow 200-wide insert, so a concurrent find is more likely to miss the whole batch.
- A clean 2000 is two lockstep imports on an empty space (or a pause after find). A late retry after batch 1 committed would mix 409s with duplicates, not a full 2×.

2. **Walked Maxim’s `a385ffc` refactor** (“Move rule import logic under detection rules client”) to understand intent, what moved, and leftover route wiring.

- Aim was Georgii’s review, not a drive-by tidy: in-place replacement of the old import ([review summary](https://github.com/elastic/kibana/pull/275695#pullrequestreview-4663885834)), decompose the fat file into single-purpose functions ([T18](https://github.com/elastic/kibana/pull/275695#discussion_r3570188905)), reuse `importRules` ([T14](https://github.com/elastic/kibana/pull/275695#discussion_r3570058501)), drop `RuleSourceImporter` ([T19](https://github.com/elastic/kibana/pull/275695#discussion_r3570203724)).
- **13 files / 7 modules** renamed from `logic/import/` into `detection_rules_client/methods/import_rules/`: `calculate_rule_source_for_import`, `check_rule_exception_references`, `convert_rule_to_import_to_rule_response` (from `import/converters/`), `errors`, `fetch_prebuilt_import_context`, `find_installed_rules_by_rule_ids`, `gather_referenced_exceptions`. Orchestrator `logic/import/import_rules.ts` stayed put.
- Apart from those moves: `importRule` deleted from client/interface/mock (and `DETECTION_RULE_IMPORT_EVENT` with it); old `methods/import_rules.ts` split into `validateRulesToImport` / `splitIntoGroups` / `createRules` / `overwriteRules`; overwrite inlined to `rulesClient.update` instead of calling `importRule` (no second `getRuleByRuleId`). Tests and the constants comment retargeted. Batch size was still 100 in this commit.
- Route `ensureLatestRulesPackageInstalled` is **not** in `a385ffc`. It landed in Steven’s [6849b48](https://github.com/elastic/kibana/commit/6849b48d224e) when `RuleSourceImporter` was removed. The old `setup()` called it once (flag-guarded) before asset lookup; the route now does that once per request so `fetchPrebuiltImportContext` / `calculateRuleSourceForImport` don’t treat every Elastic `rule_id` as custom on a cluster with no package installed.

3. **Restored import telemetry and split mixed results into `{ successes, errors }`.** [f401ceb](https://github.com/elastic/kibana/commit/f401ceb919a9) — T12 / T22 / T26 / T27.

- Old `importRule()` emitted `DETECTION_RULE_IMPORT_EVENT` after every successful create **and** overwrite. Payload used SO `id` as `ruleId` (not signature `rule_id`), plus `ruleType` / `isPrebuilt` / `isCustomized`. After Maxim’s refactor the pipeline only returned `{ rule_id }`, so the event disappeared.
- Emit from `DetectionRulesClient.importRules` after the pipeline — same home as install/revert. Do **not** thread `analytics` into helpers, refetch from ES, invent a bulk event, or run `convertAlertingRuleToRuleResponse` just for telemetry (a Zod fail after a successful write would look like an import error).
- `ImportRuleSuccess` is `{ rule_id, telemetry: RuleLifecycleTelemetryData }`. `RuleLifecycleTelemetryData` lives in `rule_lifecycle_telemetry.ts` as `Pick<RuleResponse, 'id' | 'type' | 'rule_source'>`. Create keeps the minted uuid + import `type` + calculated `ruleSource` on the pending map; overwrite uses `existingRule.id` + the same type/source. Failures/conflicts/throws emit nothing. `sendRuleLifecycleTelemetryEvent` still swallows errors.
- Client, pipeline, `createRules`, and `overwriteRules` all return `{ successes, errors }` instead of a mixed `responses` / union array. Order does not matter — HTTP is `success_count` + an errors bag. Exception-list warnings can appear in **both** lists (warning + created rule); that matches `main`.
- Orchestrator maps successes to `{ rule_id }` only. Public import response is unchanged. Unused `ImportRegular` / `isImportRegular` / `isBulkError` deleted from `detection_engine/routes/utils.ts`. `isCustomizedPrebuiltRule` widened to `Pick<RuleResponse, 'rule_source'>` so telemetry doesn’t need a full `RuleResponse`.

4. **Risk 3 — FTR checkbox is a stale PR description.** [#280553](https://github.com/elastic/kibana/pull/280553) merged 2026-07-27 (`1e717b1aee01`); [#280531](https://github.com/elastic/kibana/issues/280531) is the closed audit issue, not a second PR. Both are on `main` and already in this branch (ancestor of HEAD; last merge from `main` today). The import FTR files (`import_rules_at_batch_boundary`, overwrite-at-boundary, concurrent, by-type, identity) are here. The unchecked “Land / verify FTR…” box is leftover. Manual + perf checkboxes are still open; route Jest suite is still `describe.skip`.

5. **Risk 1 — mixed files, customer remediation, don’t over-build.**

- Mixed files are possible. Worst create-path case: one overflowing enabled rule fails its **chunk** (not the whole file), including disabled rules in that chunk. Later all-disabled chunks still import. Import honors file `enabled` on create and overwrite (`toggleRuleEnabledOnUpdate`).
- Customer remediation on a schedule-cap hit: delete the uploaded rules in the space, disable some, re-upload. They need that anyway — on `main` an all-enabled overflow also leaves a partial import to clean up.
- Workarounds on our side (split enabled/disabled, catch-and-retry disabled, import-until-cap, alerting Phase A3) have low return. Not worth going over and above.
- Lowering `RULE_IMPORT_BULK_CREATE_BATCH_SIZE` to 200 is wanted anyway and shrinks the blast radius (lose 200 on overflow, not 250). Doesn’t need a split.

6. **[#284946](https://github.com/elastic/kibana/pull/284946) bulkUpdate wiring as a lens on [#275695](https://github.com/elastic/kibana/pull/275695).** Same import pipeline, overwrite instead of create. What it chose differently points at leftover [#275695](https://github.com/elastic/kibana/pull/275695) gaps.

- **Risk 1 / schedule-limit:** update already picked “400 that batch + leftovers, keep earlier successful ids.” Create still throws the whole `bulkCreateRules` call. Same customer delete-and-reupload; the two paths won’t match when both land.
- **Risk 2:** overwrite overflow in [#284946](https://github.com/elastic/kibana/pull/284946) *returns* errors, so it won’t trip the outer catch. Create schedule-limit and **authz** (both PRs throw the whole call) still will. Exception-list warnings hiding the real error stay a create/authz problem.
- **Risk 5 pairing:** [#284946](https://github.com/elastic/kibana/pull/284946) has more maps (skip / success / toggle-fail). Same hole: if alerting’s id echo misses, the row is dropped and the catch doesn’t backfill. Worth a completeness assert on the create path.
- **Enabled:** create sets it inline. Overwrite cannot — [#284946](https://github.com/elastic/kibana/pull/284946) does `bulkEnable` / `bulkDisable` after. [#275695](https://github.com/elastic/kibana/pull/275695) overwrite still `toggleRuleEnabledOnUpdate` per rule (safer, slower). Not a [#275695](https://github.com/elastic/kibana/pull/275695) bug; don’t treat create’s inline `enabled` as the overwrite contract.
- **`allowMissingConnectorSecrets`:** [#284946](https://github.com/elastic/kibana/pull/284946) passes it on overwrite. [#275695](https://github.com/elastic/kibana/pull/275695) overwrite does not (same as `main`). Don’t change that here.
- Structure: [#284946](https://github.com/elastic/kibana/pull/284946) is still the fat `import_rules.ts` + mixed `responses`. Rebase onto `methods/import_rules/` after this merges.

7. **[#284946](https://github.com/elastic/kibana/pull/284946) [`bulk_update_rules_tradeoffs.md`](https://github.com/elastic/kibana/pull/284946/changes#r3797333625) — only [#264892](https://github.com/elastic/kibana/issues/264892) applies here.** Other rows are update-only (enabled flip, OCC 409, PIT decrypt, skip-unchanged) or already logged (schedule-limit throw, authz throw, pairing).

- [`bulkCreateRules`](https://github.com/elastic/kibana/blob/3a59c977fef76/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts#L397-L417) still invalidates **every** minted key in the batch if `bulkCreateRulesSo` throws mid-index. Rules that already landed can lose their keys. [#264892](https://github.com/elastic/kibana/issues/264892)
- [Tradeoff 4](https://github.com/elastic/kibana/pull/284946/changes#r3797341055) skipped fixing this (batches shrink the window; no SDHs). This PR is the SIEM create caller. Same call: don’t fix in [#275695](https://github.com/elastic/kibana/pull/275695); it’s alerting’s.

8. **Focused review: test coverage.** DRC `import_rules.test.ts` + helper + orchestrator suites cover the happy path, conflict/overwrite split, per-row re-pair, whole-batch throw → per-rule errors, ML/version skip, exception-warning-still-creates, telemetry emit/no-emit, and outer chunking. Gaps below.

- Confirmed **Risk 5** — no test that `successfulIds` / `errors[].rule.id` miss the uuid map (row dropped, catch does not backfill). [`create_rules.ts`](x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/import_rules/create_rules.ts) 106–125.
- Confirmed **Risk 6** — no conversion-isolation test on this path. Sibling [`bulk_create_prebuilt_rules.test.ts:367`](x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.bulk_create_prebuilt_rules.test.ts) has one.
- **Risk 2** has no regression: exception warning then `bulkCreateRules` throw is untested, so the catch treating the warning as “already handled” is unchecked.
- Route suite still `describe.skip` ([`route.test.ts:48`](x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/import_rules/route.test.ts)); even unskipped it mocks `importRules`, so new route wiring (`ensureLatestRulesPackageInstalled`, `changeTracking`, `success_count`) has no unit test. **Q5** still live. FTR is the HTTP net.
- No unit for overwrite `toggleRuleEnabledOnUpdate`. FTR `import_rules_with_overwrite.ts` covers it.
- `allowMissingConnectorSecrets` is never asserted on the `bulkCreateRules` call.
- Test name “prebuilt rule without a version is rejected before any lookup” is wrong — find/prebuilt already ran; it only skips create.

