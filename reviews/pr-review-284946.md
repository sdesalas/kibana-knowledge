# PR Review: #284946 — [Security Solution][Alerting] RulesClient.bulkUpdateRules POC

**PR:** [elastic/kibana#284946](https://github.com/elastic/kibana/pull/284946) by @sdesalas

**Scale:** Substantive PR.

---

### Context / Motivation

This comes from [issue #264894](https://github.com/elastic/kibana/issues/264894) (`RulesClient.bulkUpdate`). Import overwrite ([#275204](https://github.com/elastic/kibana/issues/275204)) and prebuilt `upgrade/_perform` ([#264908](https://github.com/elastic/kibana/issues/264908)) need to rewrite hundreds of existing rules, each with its **own** new body. Today that is N `updateRule` calls. That times out at customer scale ([#249176](https://github.com/elastic/kibana/issues/249176), [#199101](https://github.com/elastic/kibana/issues/199101)).

`bulkEditRules` cannot do this: it applies the **same** patch to every matching rule.

The ticket sketched per-id encrypted SO GETs at concurrency 50, reuse of `bulkEdit` OCC/save, and a `{ rules, errors, total }` return. Reviewers then pushed back:

- Christos ([comment](https://github.com/elastic/kibana/issues/264894#issuecomment-4333902656)): use the PIT finder + `convertRuleIdsToKueryNode`, not N decrypt GETs.
- Banderror on [#264894](https://github.com/elastic/kibana/issues/264894): share OCC/save/API-key/TM infrastructure with `bulkEdit` rather than a second write path.
- Banderror on [#264892](https://github.com/elastic/kibana/issues/264892#issuecomment-4408025793): a full `bulkCreateRulesSo` throw can still have written some docs; wiping every new API key is the wrong fix.

The PR answers those in `bulk_update_rules_tradeoffs.md`: own orchestrator (create-many shape), PIT load, reload-and-PUT on 409s, copy the invalidate-new-on-fail / old-on-success policy inside batches, do **not** patch `saveBulkUpdatedRules`. The alerting method does **not** flip `enabled`; import overwrite does that afterwards via `bulkEnableRules` / `bulkDisableRules`.

GitHub currently lists both #264894 and #264892 under `closingIssuesReferences`. The PR body only *relates* #264892 and explicitly does not fix it.

---

### Validating the issue — does this PR address it?

**The performance problem is real. The PR adds the missing primitive and wires both callers. It does not match the ticket on tests, return shape, or `bulkEdit` sharing — those are documented tradeoffs, not accidents.**

- **Where the problem manifests** — Detection import overwrite and prebuilt upgrade currently fall through to `updateRule` (or a pMap of `upgradePrebuiltRule`). Each call is a decrypt GET, a key mint, an SO write, a TM call. At hundreds/thousands of rules the HTTP socket times out.
- **Why the old approach was a problem** — `bulkEdit` is “one patch, many ids.” Import/upgrade hand in a different body per id. There was no alerting API for that.
- **How the PR fixes it** — `RulesClient.bulkUpdateRules` loads a batch via PIT, authorizes once, writes via `bulkCreateRulesSo({ overwrite: true })`, remints keys for enabled rules, then `taskManager.bulkUpdateSchedules` grouped by new interval. Security Solution import overwrite and `upgrade/_perform` (same-type) call it.
- **Residual caveat** — Import lookup is one `findInstalledRulesByRuleIds` per chunk. Upgrade still does N `getRuleByRuleId` after the handler already loaded current rules. Alerting-layer `bulkUpdateRules` has no unit/integration tests; import-client tests cover overwrite, thrown bulk update, and enable-after-update.

Stated intent vs diff: the ticket was “add `RulesClient.bulkUpdate`.” This PR also implements the two downstream wirings (#275204, #264908). Return type is `{ successfulIds, errors, total }` at the alerting layer; import callers only get `{ rule_id }`.

---

### Summary

Adds `RulesClient.bulkUpdateRules`: a batched, per-id full overwrite of existing alerting rules. The method itself does not turn rules on or off. 409s from the executor’s `lastRun` write are retried on the failed rows only. Import overwrite (`overwrite=true`) and same-type prebuilt upgrade now go through this path instead of N `updateRule` / `upgradePrebuiltRule` calls.

Import overwrite honors the file’s `enabled` after the batch via `bulkEnableRules` / `bulkDisableRules`. Create-on-import uses `bulkCreateRules`. Type-change prebuilt upgrades still delete+create. Import chunks and alerting `batchSize` share `RULE_IMPORT_BATCH_SIZE` (200).

---

### Files touched

**Alerting primitive (the new write path)**
- `alerting/server/application/rule/methods/bulk_update/{bulk_update_rules,utils,types,index}.ts` — orchestrator, PIT load, prepare/merge, OCC retry, TM grouping.
- `alerting/server/application/rule/methods/update/types/update_rule_data.ts` — `enabled?: never` so callers cannot type-pass an on/off flip.
- `alerting/server/rules_client/rules_client.ts`, `rules_client/common/constants.ts`, `alerting/server/index.ts`, `rules_client.mock.ts` — public method, batch-size caps (10 / 100 / 500), 10k hard limit.
- `alerting/common/rule_circuit_breaker_error_message.ts` — `bulkUpdate` copy.

**Review notes in-tree**
- `bulk_update_rules_tradeoffs.md` — nine tradeoffs, meant for inline GitHub comments. Not product docs.

**Security Solution callers**
- `detection_rules_client` interface + impl + mock — `bulkUpdateRules` / `bulkUpgradePrebuiltRules`. `importRules` now returns `{ responses: Array<{ rule_id } | error> }` (no `ruleSourceImporter`).
- `methods/bulk_update_rules.ts` — converts `RuleResponse` → `UpdateRuleData` then delegates. Import overwrite calls `rulesClient.bulkUpdateRules` directly.
- `methods/import_rules.ts` — classify conflict / update / create from one installed-rules map. Update → `bulkUpdateRules` (`skipIfUnchanged: true`) then enable/disable. Create → `bulkCreateRules`. Throws become per-rule errors.
- `logic/import/import_rules.ts` — chunks at `RULE_IMPORT_BATCH_SIZE` (200).
- `logic/import/find_installed_rules_by_rule_ids.ts`, `fetch_prebuilt_import_context.ts` — one find + prebuilt asset context per chunk. `rule_source_importer` removed.
- `api/constants.ts` — `RULE_IMPORT_BATCH_SIZE = 200` (timeouts moved here from `timeouts.ts`).
- `methods/bulk_upgrade_prebuilt_rules.ts` — same-type → bulk update; type-change → existing `upgradePrebuiltRule` (delete+create).
- `perform_rule_upgrade_handler.ts` — swaps `upgradePrebuiltRules` (pMap of singles) for `detectionRulesClient.bulkUpgradePrebuiltRules`. Legacy `upgrade_prebuilt_rules.ts` still used by promotion-rule install and the legacy prepackaged path.

---

### Flow trace

**Import overwrite of an existing detection rule** (the path this is for):

1. `POST .../rules/_import?overwrite=true` parses NDJSON. Chunking happens in `logic/import/import_rules.ts` at `RULE_IMPORT_BATCH_SIZE` (200).
2. Each chunk calls `detectionRulesClient.importRules`.
3. One parallel load: exception lists, `fetchPrebuiltImportContext`, `findInstalledRulesByRuleIds` (KQL OR on `params.ruleId`). Then per-rule prep (version, ML authz, exceptions, rule source).
4. Classify from the installed map: conflict / update / create.
5. Update path: `applyRuleUpdate` + `convertRuleResponseToAlertingRule`, then `rulesClient.bulkUpdateRules` with `batchSize: 200` and `skipIfUnchanged: true`. Create path: `bulkCreateRules` with the same batch size.
6. Per alerting batch (`runBatch`): PIT decrypt load → `bulkMigrateLegacyActions` → `bulkEnsureAuthorized(Update)` (throw the call) → `validateScheduleLimit` on **enabled** rules whose interval changed (throw the call) → `writeWithRetry`. Import catches those throws and maps them to per-rule errors.
7. `prepareUpdate` (pMap, concurrency 50): schema, rule-type params, actions, `incrementRevision`. If `skipIfUnchanged` and revision did not bump, skip write/key/history. Else mint a key iff the existing rule is enabled (`createNewAPIKeySet({ shouldUpdateApiKey: original.enabled })`), merge onto the original SO, force `enabled: originalRule.enabled`.
8. `bulkCreateRulesSo({ overwrite: true })`. Per-row 409 → invalidate the **new** key for that row, wait 100ms, reload those ids, prepare again, retry (`RetryForConflictsAttempts` = 2). Full throw → invalidate every new key in the batch (the #264892 shape, scoped to the batch).
9. Success rows: invalidate **old** keys (gated on `!apiKeyCreatedByUser`), `updateTaskSchedules` grouped by new interval if `scheduledTaskId` exists and interval changed (on **or** off), `logRuleChanges`. TM errors are logged and swallowed; the id stays in `successfulIds`.
10. Import maps `successfulIds` to `{ rule_id }`. Then `bulkEnableRules` / `bulkDisableRules` for successful ids whose file `enabled` differs from the existing rule.

Same-type prebuilt upgrade is the same from step 5, without `skipIfUnchanged`, after a second round of `getRuleByRuleId` + `applyRuleUpdate` inside `bulkUpgradePrebuiltRules` (the handler already loaded current versions).

---

### Assumptions

- Executor `lastRun` / `executionStatus` writes are the main 409 source, and two retries at 100ms are enough for a running fleet. A real competing edit loses to last-writer-wins after retries.
- `incrementRevision` is a complete enough diff for `skipIfUnchanged`. Action UUIDs keep their existing values (`uuid || v4()`), so a no-op re-import of rules with actions can still skip. Generated-on-missing UUIDs on actions that never had one will bump revision and write.
- Callers never need the persisted rule documents back — only ids. Import HTTP and `detectionRulesClient.importRules` both return `{ rule_id }` (plus errors), not a `RuleResponse`.
- Mixed Update privileges across rule types in one batch are rare enough that failing the whole call is acceptable. Detection import/upgrade is usually one user, SIEM consumers.
- Disabled rules with a `scheduledTaskId` should have their paused TM task’s interval rewritten (same as `updateRule`). Later enable uses that cadence without rewriting the interval.
- `bulkCreateRulesSo` full throws are rare; import batches at 200, so the #264892 dead-key window is that chunk. A later bulk operation is expected to remint.
- PIT decrypt failure on one document looks like “not found” (per-item error). No fallback to an undecrypted GET, unlike `updateRule`.
- The 10k cap is a backstop. Import’s real cap is `RULE_IMPORT_BATCH_SIZE` (200) per chunk. Upgrade’s loop is still 100.
- `tradeoffs.md` is review scaffolding and will not ship in the alerting plugin long-term.

---

### Risks

- ~~**Import overwrite no longer honors `enabled`.** Old path: `importRule` → `toggleRuleEnabledOnUpdate`. New path: keep the existing on/off. Re-importing `"enabled": true` over disabled rules used to turn them on; now they stay off. The single-rule `importRule` API still toggles — two overwrites, two behaviors. The PR description treats this as intended; tradeoff 2 says callers will do enable/disable after the batch, and they don’t.~~ **FIXED**
  - `updateRules` now collects enable/disable ids and calls `bulkEnableRules` / `bulkDisableRules` only for `successfulIds`.
  - Residual: if enable/disable returns per-item errors, that rule can show as both a `{ rule_id }` success and an error. If `bulkEnableRules` throws, the outer catch skips ids already in `responses` — success, no flip, no error.
- ~~**Circuit-breaker / authz throws are no longer per-item.** `updateRule` throwing “too many runs per minute” used to fail that one import row. `validateScheduleLimit` / `bulkEnsureAuthorized` now throw the `bulkUpdateRules` call. `import_rules.ts` does not catch it. The HTTP route’s outer `catch` returns 400 for the whole request. Earlier route chunks (and earlier inner batches) are already saved. Client sees a failed import; server has a partial one.~~ **ADDRESSED (import only)**
  - Import’s outer `try/catch` maps a thrown `bulkUpdateRules` / `bulkCreateRules` onto remaining rule_ids as per-item errors. HTTP import stays 200 with a mixed result list. Earlier `RULE_IMPORT_BATCH_SIZE` chunks keep their responses.
  - Upgrade (`bulkUpgradePrebuiltRules`) still does not catch the throw.
- ~~**Uncommitted chunk 500 makes inner batching real.** Committed import chunk is 50 < default `batchSize` 100, so the inner loop never splits. At 500, you get five inner batches. An authz/circuit-breaker throw on batch 3 leaves batches 1–2 persisted, then the HTTP 400 above. Also 500 concurrent `getRuleByRuleId` finds per chunk (`Promise.all`).~~ **DONE**
  - Uncommitted 500 is gone. Outer chunk and `batchSize` share `RULE_IMPORT_BATCH_SIZE` (200). No nested inner batches on import.
- **No tests for a new public `RulesClient` method.** OCC retry, skip-if-unchanged, key invalidation on partial vs full throw, disabled+interval TM update, circuit breaker, authz-throw-the-call — none of it has a unit or integration test. Existing `detection_rules_client.import_rules.test.ts` still mocks `importRule` and only covers `overwriteRules: false`. Overwrite-enabled tests live on `importRule`, which this path no longer uses.
  - **Partial:** import-client tests now cover overwrite, mixed create/update, thrown `bulkUpdateRules`, and enable-after-update. Alerting-layer `bulkUpdateRules` still has no tests.
- **#264892 still applies per batch.** Full `bulkCreateRulesSo` throw invalidates every new key in that batch, including for docs ES may have written. Those rules keep a dead key until the next write. Documented; not closed.
- **Upgrade double-fetches.** `perform_rule_upgrade_handler` already loaded current rules. `bulkUpgradePrebuiltRules` calls `getRuleByRuleId` per asset anyway (another find each). Extra ES load and a TOCTOU between the revision check and the write.
- **GitHub may auto-close #264892.** `closingIssuesReferences` includes it. The PR does not fix that ticket.

---

### Open questions

1. ~~Is dropping `enabled` on import overwrite a product decision, or an unfinished tradeoff 2? If product: the docs/API need to say overwrite does not change on/off. If unfinished: the caller still needs a `bulkEnable` / `bulkDisable` pass after the batch, like `toggleRuleEnabledOnUpdate` did.~~ **DONE** — unfinished toggle; callers now do `bulkEnable` / `bulkDisable` after the batch.
2. ~~Should `import_rules.ts` / `bulkUpgradePrebuiltRules` catch `bulkUpdateRules` throws (circuit breaker, authz) and turn them into per-item or per-chunk errors, instead of failing the HTTP request after a partial save?~~ **ADDRESSED (import only)** — `import_rules.ts` catches and maps to per-rule errors. `bulkUpgradePrebuiltRules` still lets the throw bubble.
3. ~~Is `CHUNK_PARSED_OBJECT_SIZE = 500` meant to land? Tradeoff 9 says import stays at 50 and callers chunk. The method already inner-chunks at 100. 500 is the first time those two layers nest on import.~~ **DONE** — 500 never landed. Shared `RULE_IMPORT_BATCH_SIZE = 200` for outer chunk and `batchSize`.
4. Ticket asked for `{ rules, errors, total }`. Callers only get ids. Is that enough for upgrade telemetry / import UI, or will someone need the persisted revision/`updated_at` next?
   - Import now returns `{ rule_id }` only (`ImportRuleSuccess`). Thinner than before.
5. Should `bulkUpgradePrebuiltRules` take the already-loaded current rules from the handler instead of N `getRuleByRuleId` calls?
6. Is `bulk_update_rules_tradeoffs.md` staying in `alerting/server/...` after review, or is it PR-only scaffolding?
7. Confirm #264892 should **not** close when this merges.

---

### Notes for your codebase map

- Alerting now has three bulk write shapes: **create-many** (`bulkCreateRules`, persist-first + demote), **edit-many** (`bulkEditRulesOcc`, one patch + `retryIfBulkEditConflicts`), **update-many** (`bulkUpdateRules`, per-id bodies + reload-and-PUT). They share primitives (`bulkCreateRulesSo`, `createNewAPIKeySet`, PIT decrypt, `invalidateKeys`) but not orchestrators.
- `updateRule` / `bulkUpdateRules` never flip `enabled`. Detection create/update/patch/import-single do it afterwards via `toggleRuleEnabledOnUpdate` → `enableRule` / `disableRule`. Bulk import overwrite currently skips that follow-up.
- `incrementRevision` is the “did anything editable change?” signal. `skipIfUnchanged` is just “don’t write if revision would not bump.”
- TM interval is rewritten for disabled rules that still have a `scheduledTaskId` (disable keeps the paused task on purpose — see `rule_so_task_consistency.md`). Circuit breaker only counts **enabled** interval changes.
- Detection `getRuleByRuleId` is a `findRules` on `params.ruleId`, not an SO get-by-id. Cheap-looking loops of it are still N ES searches.
- Prebuilt upgrade still has two implementations: new `bulkUpgradePrebuiltRules` on `upgrade/_perform`, old `upgradePrebuiltRules` pMap on promotion-rule install and the legacy prepackaged path.

---

### Review activities

1. **Rechecked risks/questions after `da7eaf43af4` (import overwrite rewrite).** Working tree is clean; the uncommitted 50→500 chunk is gone. Import overwrite was rewritten in that commit.

   - One `findInstalledRulesByRuleIds` (KQL OR, cap `RULE_IMPORT_BATCH_SIZE` 200) instead of N `getRuleByRuleId`.
   - Outer chunk and `bulkUpdateRules` / `bulkCreateRules` `batchSize` share that 200.
   - `updateRules` toggles `enabled` via `bulkEnableRules` / `bulkDisableRules` on `successfulIds` only.
   - Whole-batch throws become per-rule errors; HTTP import no longer 400s the request.
   - Tests cover overwrite, thrown `bulkUpdateRules`, and enable-after-update.
   - Residual: enable/disable failure after a recorded success can emit both a success and an error (or success only, no flip, if the enable call throws).
   - Unchanged: upgrade still N `getRuleByRuleId`; no alerting `bulkUpdateRules` tests; #264892 still in `closingIssuesReferences`; `tradeoffs.md` still in-tree; import return is `{ rule_id }` only.
   - Rewrote header → Assumptions to match the post-`da7eaf43af4` import path. Risks / open questions left as-is.
