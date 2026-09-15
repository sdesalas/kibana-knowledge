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

Georgii approved 2026-09-14 after a local review of the create path. Two findings from that pass were filed as follow-ups so this PR can merge: [#290911](https://github.com/elastic/kibana/issues/290911) (prebuilt install, not import) and [#290918](https://github.com/elastic/kibana/issues/290918) (raise the 10 MB import payload cap after overwrite is bulk). Next highest-impact work is overwrite via `bulkUpdate` ([#275204](https://github.com/elastic/kibana/issues/275204)). See review activities 10–12.

---

### Files touched

**Route + constants**
- `api/rules/import_rules/route.ts` — drops the 50-rule chunk and `RuleSourceImporter`; installs the prebuilt package once; forwards `changeTracking.action: ruleImport` + `metadata.bulkCount`; calls `detectionRulesClient.importRules` directly (no orchestrator).
- `api/constants.ts` — `timeouts.ts` renamed; adds `RULE_IMPORT_BULK_CREATE_BATCH_SIZE` (200) and `RULE_IMPORT_BULK_UPDATE_CONCURRENCY` (50).
- `api/rules/bulk_actions/route.ts`, `api/rules/export_rules/route.ts` — import path only (`timeouts` → `constants`).

**Orchestrator**
- `logic/import/import_rules.ts` — **deleted** in [9452e6a](https://github.com/elastic/kibana/commit/9452e6a009a3). Chunking now lives in DRC `importRules`. Route maps `ImportRuleError` to HTTP 400/409.

**Detection Rules Client**
- `detection_rules_client.ts` / `detection_rules_client_interface.ts` — `importRule` removed; `importRules` takes `rules` + options and returns `{ successes, errors }`. After the pipeline it emits `DETECTION_RULE_IMPORT_EVENT` once per success.
- `methods/import_rule.ts` — deleted. No remaining callers.

**New import pipeline (`methods/import_rules/`)**
- `import_rules.ts` — outer chunk at 200; parallel lookups, validate, split, overwrite, create; concatenates `{ successes, errors }`; per-chunk try/catch turns throws into per-rule errors. Comment that outer batching should move to `route.ts` if file-level streaming is attempted ([3f244b7](https://github.com/elastic/kibana/commit/3f244b7b3e672c780b0be19d7400f0ef3e0eba27)).
- `validate_rules_to_import.ts` — version default, ML auth, exception refs, `rule_source`.
- `create_rules.ts` — uuid pairing + `bulkCreateRules`; keeps `id` / `type` / `rule_source` on each success for telemetry.
- `overwrite_rules.ts` — `pMap` + `rulesClient.update` + `toggleRuleEnabledOnUpdate`; same success shape.
- `fetch_prebuilt_import_context.ts` / `find_installed_rules_by_signature_ids.ts` — replace `RuleSourceImporter.setup()`.
- Helpers moved with the folder: `calculate_rule_source_for_import`, `check_rule_exception_references`, `convert_rule_to_import_to_rule_response`, `gather_referenced_exceptions`, `errors`.

**Deleted**
- `logic/import/rule_source_importer/*` — package install moved to the route; asset/installed-rule fetches inlined.

**Tests**
- New/rewritten DRC + helper + orchestrator tests. `import_rule.test.ts` and `rule_source_importer.test.ts` deleted. Route suite rewritten and unskipped in [c906dd4](https://github.com/elastic/kibana/commit/c906dd4cbb2b) — five tests, `route.ts` wiring only. See review activity 9.

---

### Flow trace

1. `POST /api/detection_engine/rules/_import` parses NDJSON, imports exceptions/connectors, dedups `rule_id`s, migrates action IDs, validates actions/response actions.
2. Route calls `ensureLatestRulesPackageInstalled` once, then `detectionRulesClient.importRules` with `changeTracking: { action: ruleImport, metadata: { bulkCount } }`. Maps `conflict` → 409, everything else → 400.
3. DRC `importRules` chunks at 200 (`batchSize` default `RULE_IMPORT_BULK_CREATE_BATCH_SIZE`) and runs three lookups per chunk: referenced exception lists, prebuilt assets (`fetchLatestVersions` + `fetchDeprecatedRules` + `fetchAssetsByVersion`), installed rules via a quoted KQL OR-list on `params.ruleId`.
4. `validateRulesToImport` per rule: prebuilt-without-version → error and skip; ML auth fail → error and skip; missing exception list → **warning error, rule still proceeds** with the dangling ref stripped; version defaults to 1; `rule_source` / `immutable` calculated.
5. Split: unknown `rule_id` → create; existing + overwrite → update; existing + no overwrite → 409. (`split_into_groups` was inlined.)
6. Overwrite: `applyRuleUpdate` + `rulesClient.update` + `toggleRuleEnabledOnUpdate`, concurrency 50.
7. Create: `applyRuleDefaults` + convert + `bulkCreateRules({ batchSize: 200 })`. Caller-generated uuids are re-paired to `rule_id`.
8. If anything in the try throws (find, prebuilt fetch, `bulkCreateRules` pre-check), remaining `rule_id`s that aren’t already in `successes` or `errors` get that error message.
9. Client emits `DETECTION_RULE_IMPORT_EVENT` for each success (`ruleId` is the SO `id`). Route maps successes to `{ rule_id }` and errors to `BulkError`, then uses `successes.length` for `success_count`.

---

### Assumptions

- `rulesClient.bulkCreateRules` from [#269340](https://github.com/elastic/kibana/pull/269340) is a faithful bulk equivalent of `rulesClient.create` for SIEM rules (API keys, task scheduling, connector secrets, change history). The create payload is copied from `createRule()`.
- Outer and inner batch size share `RULE_IMPORT_BULK_CREATE_BATCH_SIZE` (200). DRC encapsulates the outer chunk; the route does not. Leftover chunks still pass `batchSize: 200`, not the leftover count, so alerting’s 10–500 `batchSize` range is satisfied. See review activity 12.
- `findRules({ perPage: ruleIds.length })` will actually return all matches. No extra pagination.
- In-file duplicate `rule_id`s are gone before this pipeline — `getTupleDuplicateErrorsAndUniqueRules` in the route.
- `bulkCreateRules` echoes `options.id` in `successfulIds` / `errors[].rule.id`. Pairing depends on that. Same pattern as `bulkCreatePrebuiltRules`.
- Route-level `RULES_API_ALL` means alerting `bulkEnsureAuthorized` won’t reject a mixed-type batch for rule-type privileges. If that’s ever not true, one unauthorized type fails the whole create batch.
- `allowMissingConnectorSecrets` is create-only. Overwrite never passed it on `main` either.
- Exception-list “errors” are warnings: the rule is still created/updated with the ref removed. Same as `main`.
- ~~FTR in [#280553](https://github.com/elastic/kibana/pull/280553) / [#280531](https://github.com/elastic/kibana/issues/280531) is the contract-parity net. This PR’s own checklist still has that unverified.~~ STALE — FTR landed and is on this branch; CI has been running it.

---

### Risks

1. **Whole-batch schedule-limit fail.** `bulkCreateRules` sums every **enabled** interval, then throws before any writes if the circuit breaker trips — the whole chunk fails, including disabled rules in that chunk. Mixed files are possible. Customer fix is the same as today’s cap hit: delete the uploaded rules in the space, disable some, re-upload. LOW PRIORITY. SKIP. Extra engineering (split/retry/alerting) has questionable ROI. Instead, dropping the batch 250->200 (already wanted) mitigates the blast radius. See review activity 5.
2. ~~**Exception-list warnings hide the real error.** `checkRuleExceptionReferences` pushes a warning **and** keeps the rule importable. The outer catch builds `responded` from every error `ruleId`. If `bulkCreateRules` later throws, that rule does not get the real failure message. The client sees “Reference has been removed” and `success_count: 0` — the warning implies the import continued. Why this is risky: dangling exception list + schedule-limit/authz throw in the same chunk. **Same hole, extra case (activity 13):** `createRules` conversion errors never return when `bulkCreateRules` throws, so those rules also get the throw message instead of the conversion one. Sibling `bulkCreatePrebuiltRules` already catches locally and backfills every pending id — this path relies on the outer catch instead.~~ **Dropped — low priority, skip this PR. See activity 15.**
3. ~~**No feature flag, FTR dependency not checked off.** Create-path contract changes go out to every import on merge. Unit tests cover the new pipeline; the PR’s own checklist still has FTR + manual + perf matrix open.~~ STALE — FTR ([#280553](https://github.com/elastic/kibana/pull/280553)) landed 2026-07-27, is on this branch, and has been running in CI. See review activity 4.
4. **`RULE_IMPORT_BULK_CREATE_BATCH_SIZE` is provisional (200).** Raising it toward 500 without splitting the KQL find reintroduces a whole-batch ES clause failure. The helper test guards the current constant, not a future bump at the call site.
5. ~~**Create-error pairing can drop a row.** If `successfulIds` / `errors[].rule.id` don’t match the uuid map, `createRules` skips the row and does not throw, so the outer catch won’t backfill it. Unlikely if alerting keeps echoing `options.id` (verified against source — activity 14); there’s no test that the map is complete after a bulk response. **(Clarified — activity 13)** A silent drop with no prior warning can make the HTTP envelope `success: true` while `success_count < rules_count`.~~ **Dropped — assumption holds today; skip this PR. See activity 15.**
6. ~~**Per-rule conversion isolation is untested on this path.** `createRules` wraps `applyRuleDefaults` / convert in try/catch so one bad rule shouldn’t fail the batch. `bulkCreatePrebuiltRules` has a test for that; this suite doesn’t.~~ **Dropped — skip this PR. See activity 15.**
7. ~~**Duplicate-import race (TOCTOU), possibly worse.** `rule_id` uniqueness is still check-then-create. Lookup is per 200-chunk, then a long `bulkCreateRules`. Two overlapping POSTs of the same file can both see empty and both create. Pre-existing ([#176207](https://github.com/elastic/kibana/issues/176207)); this PR likely makes it easier (chunk 50 → 200, one snapshot covers a slow 200-wide insert). See review activity 1.~~ **Dropped — pre-existing, already ticketed as #176207. Skip this PR. See activity 15.**

---

### Open questions

1. ~~**(Risk 1)** For an all-enabled file that overflows the schedule cap, is “fail the whole 200-chunk” the contract you want, or “import until the cap, fail the rest” (today’s per-rule `create`)? Mixed enabled/disabled is not a real upload shape.~~ Accepted — mixed is possible; customer already deletes-and-reuploads on a cap hit; don’t go over and above. Batch 200 mitigates. See review activity 5.
2. ~~**(Risk 2)** Should the outer catch treat exception-list warnings as non-terminal, so a later whole-batch throw still attaches the real error? Alternative that also keeps conversion errors: catch inside `createRules` the way `bulkCreatePrebuiltRules` already does (activity 13–14).~~ **Dropped — low priority, skip this PR. See activity 15.**
3. ~~**(Risk 4)** Is 200 locked enough to merge, or does this wait on the 100/200/250/300/500 × 1000/2000 × enabled/disabled matrix in the PR?~~ Accepted — Georgii: keep 200 for this PR; further batch-size work lives in [#273514](https://github.com/elastic/kibana/issues/273514). See review activity 11.
4. ~~**(Risk 3)** Has [#280553](https://github.com/elastic/kibana/pull/280553) / [#280531](https://github.com/elastic/kibana/issues/280531) actually landed on `main` and been re-run against this branch? The checklist says no.~~ STALE — yes, landed, merged into this branch, running in CI.
5. ~~The skipped route test still expects ML authz to come back as **403**; the orchestrator maps every non-conflict error to **400** (same as `main`). If that suite gets unskipped, that case will fail — is 400 the public contract?~~ Closed — 400 is the live contract (since #212761). FTR `import_rules_ess.ts` asserts it. See review activity 9.

---

### Notes for your codebase map

- Detection-rule import is now a pipeline inside `methods/import_rules/`: lookup → validate → split → overwrite | create. The singular `importRule()` API is gone.
- `RuleSourceImporter` is gone. Package install is a route-level `ensureLatestRulesPackageInstalled`. Asset + installed-rule fetches are plain functions (`fetchPrebuiltImportContext`, `findInstalledRulesByRuleIds`).
- Installed-rule lookup by `rule_id` is a quoted KQL OR-list on `alert.attributes.params.ruleId`. The existing `findRules({ ruleIds })` option filters **SO** `alert.id`, not signature `rule_id` — don’t use it here. The old `fetchInstalledRulesByIds` did the same KQL without quoting; this helper is stricter (`findInstalledRulesBySignatureIds`).
- `createRules` is the same shape as `bulkCreatePrebuiltRules`: caller uuid, `applyRuleDefaults`, `enabled ?? false`, re-pair `successfulIds`.
- `bulkCreateRules` preValidate throws on authz and schedule-limit **before any ES writes**. Per-rule schema/interval failures stay in `errors`. Task-schedule failures exclude only the enabled subset.
- Exception-list failures on import are warnings: error object + rule still created with the ref stripped. That’s older behavior, now more visible because the catch uses those errors as “already handled.”
- Outer chunk size used to be 50 (`CHUNK_PARSED_OBJECT_SIZE` in the route). It’s now 200 inside DRC `importRules`, shared with `bulkCreateRules`’s `batchSize`. Route still reads the whole NDJSON up front.

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

4. **Risk 3 — FTR checkbox is a stale PR description.** [#280553](https://github.com/elastic/kibana/pull/280553) merged 2026-07-27 (`1e717b1aee01`); [#280531](https://github.com/elastic/kibana/issues/280531) is the closed audit issue, not a second PR. Both are on `main` and already in this branch (ancestor of HEAD; last merge from `main` today). The import FTR files (`import_rules_at_batch_boundary`, overwrite-at-boundary, concurrent, by-type, identity) are here. The unchecked “Land / verify FTR…” box is leftover. Manual + perf checkboxes are still open. Route Jest suite is no longer skipped — see review activity 9.

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
- No unit for overwrite `toggleRuleEnabledOnUpdate`. FTR `import_rules_with_overwrite.ts` covers it.
- `allowMissingConnectorSecrets` is never asserted on the `bulkCreateRules` call.
- Test name “prebuilt rule without a version is rejected before any lookup” is wrong — find/prebuilt already ran; it only skips create.

9. **Route suite rewrite + ML-authz is 400, not 403.** [c906dd4](https://github.com/elastic/kibana/commit/c906dd4cbb2b). [PR comment on the deleted `describe.skip`](https://github.com/elastic/kibana/pull/275695#discussion_r3967795257).

- Old skipped test swapped `importRule` throwing `HttpAuthzError` for `importRules` resolving `{ errors: [createRuleImportErrorObject(...)] }`. `importRule` is gone. `validateRulesToImport` catches `HttpAuthzError` and returns a per-rule error with no status (same swallow already on `main`). Orchestrator maps conflict → 409, everything else → **400**. Create/update/patch stay 403 because those routes let `HttpAuthzError` escape.
- Pre-#212761 (`importRulesLegacy` → throw) produced per-rule **403**. Current path (FF on since March 2025, still `main`) is **400**. The skipped test’s 403 was leftover from `transformBulkError` reading `err.statusCode`. Restoring 403 would be a contract change. **Q5** closed.
- Suite was skipped in [#212761](https://github.com/elastic/kibana/pull/212761) (Maxim) when the prebuilt-customization path became the default. It mocked `detectionRulesClient.importRules` plus Alerting `rulesClient`, Actions, ES, and ML authz. Conflict / overwrite / ML cases never left `security_solution` — they asserted mock output. Real code that ran was `route.ts` plus stream parse / dedupe / schema.
- Unskip experiment: 14 failed / 3 passed. Passes never hit the new route wiring. Rewrote to five route-only unit tests: `.html` → 400; collaborator throw → 500; package install + `changeTracking` / overwrite / response shape; `allowMissingConnectorSecrets`; error-bucket concat. Jest **5 passed**.
- Deleted cases mapped to existing FTR in `rule_import_export/` (and one prebuilt missing-`rule_id` FTR). Gaps: no 9999 FTR (10 + 8000 instead); custom missing `rule_id` message is now Zod, not `Required`; 3-rule overwrite-true batch is close, not exact. Exceptions/connectors envelope is in trial `import_rules.ts` — `returns the full import response shape on success`.
- Added FTR `import_rules_ess.ts` — hunter imports ML + query; HTTP 200, ML `status_code: 400`, query still created. FTR **1 passing**.
- Comment framing: saying the old suite “went beyond unit-test coverage of `route.ts`” overstates it. It *looked* like a pipeline suite. It tested mocks. FTR is the real multi-layer coverage.

10. **Georgii’s 14 Sep review — create path good; two unrelated follow-ups filed.** [Review comment](https://github.com/elastic/kibana/pull/275695#issuecomment-5663697131). [APM](https://github.com/elastic/kibana/pull/275695#issuecomment-5663963876). [Steven’s reply + tickets](https://github.com/elastic/kibana/pull/275695#issuecomment-5665565254).

- ~20 prebuilt export/import sets (100 → all rules), empty space and already-populated. Create path (a few `bulkCreateRules` under the hood) was noticeably faster than `main`. APM on new-rule import looks clean.
- Overwrite (`overwrite: true`) is still the unoptimized path. APM: ~5000 outgoing ES requests per ~1100 rules over ~25s. At 300 spaces in parallel that could saturate the cluster. Same residual as the summary: next work is [#275204](https://github.com/elastic/kibana/issues/275204).
- Unrelated to this PR: installing AWS-tagged prebuilts (`Data Source: AWS`) immediately showed upgrades. Reproduced as `SPECIFIC_RULES` + a tag the latest asset dropped. Filed [#290911](https://github.com/elastic/kibana/issues/290911), edited after creation, linked from the PR comment. Raised in [#security-detection-engineering-experience-dex](https://elastic.slack.com/archives/C09S1NKF8HX/p1789400933455199) to prioritize (FYI Yara; Kseniia agreed it needs fixing).
- Also unrelated: import 400 after ~1050–1150 rules. `maxRuleImportPayloadBytes` default 10 MB ([`config.ts`](https://github.com/elastic/kibana/blob/afaff8e5cff2eb70013664badebdcd5eff0ce4ea/x-pack/solutions/security/plugins/security_solution/server/config.ts#L26-L27); Hapi `maxBytes` in [`route.ts`](https://github.com/elastic/kibana/blob/afaff8e5cff2eb70013664badebdcd5eff0ce4ea/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/import_rules/route.ts#L54-L58)). Full prebuilt export cannot be re-imported. Filed [#290918](https://github.com/elastic/kibana/issues/290918), edited after creation, linked from the PR comment, parented under [#273509](https://github.com/elastic/kibana/issues/273509). Do it after [#275204](https://github.com/elastic/kibana/issues/275204).

11. **Georgii APPROVED with nits (14 Sep).** [Review](https://github.com/elastic/kibana/pull/275695#pullrequestreview-5198828473). Create-path numbers LGTM (especially with `refresh=false`). Nits, not merge blockers:

- Keep batch size 200 here; further tuning in [#273514](https://github.com/elastic/kibana/issues/273514). Perf testing needs to get cheaper because we’ll do it regularly. [constants.ts](https://github.com/elastic/kibana/pull/275695#discussion_r4006016697).
- Encapsulate outer batching in `detectionRulesClient.importRules` (optional `batchSize`, default `RULE_IMPORT_BULK_CREATE_BATCH_SIZE`), pass it through to `createRules`, comment why outer and inner share the size. [import_rules.ts orchestrator](https://github.com/elastic/kibana/pull/275695#discussion_r4007156002).
- Inject the prebuilt rule assets client; don’t construct it in the import method. [import_rules.ts](https://github.com/elastic/kibana/pull/275695#discussion_r4007324234).
- Comment each `PrebuiltImportContext` property. [fetch_prebuilt_import_context.ts](https://github.com/elastic/kibana/pull/275695#discussion_r4007355144).
- Rename `findInstalledRulesByRuleIds` → `findInstalledRulesBySignatureIds`, typed `RuleSignatureId[]`. [find_installed_rules_by_rule_ids.ts](https://github.com/elastic/kibana/pull/275695#discussion_r4007370181).
- Liked the route-test rewrite comment. [route.test.ts](https://github.com/elastic/kibana/pull/275695#discussion_r4006133276).

Nits were addressed the next day and pushed as [9452e6a](https://github.com/elastic/kibana/commit/9452e6a009a3) (including deleting the leftover `logic/import/import_rules.ts` pass-through so the route calls the DRC method directly).

12. **Keep DRC batching so #275695 can merge (15 Sep).** [DM](https://elastic.slack.com/archives/D09DQRW6Z88/p1789463332737809?thread_ts=1789374469.548209). [Comment](https://github.com/elastic/kibana/commit/3f244b7b3e672c780b0be19d7400f0ef3e0eba27). Patch parked at `.knowledge/patches/import_rules.batching.surfaced.to.route.ts.patch`.

- After 9452e6a, Steven wanted to reverse Georgii’s encapsulate-batching nit: chunk in `route.ts` so a later change can stream the file instead of holding every rule in memory. Route still fully parses NDJSON first (exceptions/connectors sit at the end of the file), so that move would not stream today — it only sets the layering.
- `create_rules` forwards the 200 constant as `bulkCreateRules` `batchSize`, including leftover chunks of 1–9. Alerting requires `batchSize` in 10–500; 200 is inside that. We need to be careful not to pass `bulkInputs.length` in the future, because alerting `bulkCreateRules()` throws below 10 and 400s those leftover rules via the outer catch. That code is not on the PR so not a problem.
- Georgii: current import NDJSON is not streamable (mixed entity types with cross-deps); massive imports belong in a future async API. ([reply](https://elastic.slack.com/archives/D09DQRW6Z88/p1789465442495409))
- Steven parked the route-chunking patch, added a DRC comment that outer batching should move to `route.ts` if file-level streaming is attempted ([3f244b7](https://github.com/elastic/kibana/commit/3f244b7b3e672c780b0be19d7400f0ef3e0eba27)), and will merge when CI passes. Batching stays inside DRC as Georgii asked.

13. **Focused review: error handling.** Layer-boundary pass over the import pipeline (`import_rules` → validate / overwrite / create → route). Confirmed **Risk 2** (raised again below) and refined **Risk 5**. One new mechanism on Risk 2, no new risk number.

- `importRules` is a per-item-partial-success API with one whole-batch escape hatch: the per-chunk `catch` stamps remaining `rule_id`s. `responded` includes exception-list warnings, so a later A2/A3 throw leaves those rules on “Reference has been removed” (**Risk 2**, **Q2** still open).
- `createRules` accumulates conversion errors, then `await bulkCreateRules` with no local catch. A throw discards those local errors — the outer catch overwrites them with the throw message. Sibling `bulkCreatePrebuiltRules` (lines 55–91) already catches and backfills every pending id; adopting that here would also stop warnings from hiding the real error.
- Pairing miss after a *returned* bulk result does not throw, so the outer catch never backfills (**Risk 5**). HTTP `success` is `errors.length === 0`, so a silent drop can report `success: true` with `success_count` short.
- Overwrite `update` then `toggleRuleEnabledOnUpdate`: toggle fail reports an error after the SO write. Same as `main`. Not new.
- Route maps conflict → 409, everything else → 400; `importRules` itself should not reject. Package-install throw is still a route 500 after exceptions/connectors already imported — same as the old `RuleSourceImporter.setup()` placement.

14. **Focused review: solution-integration.** Read `bulkCreateRules` (`bulk_create_rules.ts`) against what this caller assumes.

- **Throw vs return, verified.** A1 (schema/interval/registry) → per-item `errors`. A2 `bulkEnsureAuthorized` → **throws**. A3 schedule-limit → **throws**. B1 prepare / B2 task-schedule / B3 SO (including a whole-call `bulkCreateRulesSo` throw) → **returns** `{ successfulIds, errors }`. Outer catch only fires for A2/A3 (plus find/prebuilt/lookup throws). B3 key-invalidation on a mid-index SO throw is still alerting [#264892](https://github.com/elastic/kibana/issues/264892) — caller pairing works because B3 does not propagate.
- **Id echo holds.** `options.id` is the id used in A1 errors, B-phase errors, and `successfulIds` (`so.id`). Pairing assumption is good; the skip-if-null is the leftover hole (**Risk 5**).
- **Sibling already solved the throw.** `bulkCreatePrebuiltRules` localizes A2/A3 to the create inputs. Import leaves that to the outer catch, which is why warnings (and pre-throw conversion errors) go stale. That’s the integration fix for **Risk 2** / **Q2**.
- **Non-findings:** `allowMissingConnectorSecrets` is per-item and used in `prepareRule` → `validateActions`. `changeTracking` is forwarded; alerting defaults to `ruleCreate` only if omitted. Leftover chunks still pass `batchSize: 200`, inside alerting’s 10–500. `find` `perPage: ruleIds.length` is enough unless the space already has duplicate `rule_id`s (Risk 7 leftovers); caller ignores `total`.

15. **Interview: leftover risks.** Steven: Risk 2 / Q2 is low priority — skip this PR. Risk 5 skipped — `options.id` echo holds; no current trigger. Risk 7 skipped — pre-existing, already #176207. Risk 6 skipped — no conversion-isolation test this PR. No code change, no new follow-up on these.
