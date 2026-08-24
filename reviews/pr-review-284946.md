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

GitHub lists #264894 under `closingIssuesReferences`. The PR body only *relates* #264892 and explicitly does not fix it. #286508 closes neither. See activity #10 / struck Risk #7.

---

### Validating the issue — does this PR address it?

**The performance problem is real. The PR adds the missing primitive and wires both callers. It does not match the ticket on tests, return shape, or `bulkEdit` sharing — those are documented tradeoffs, not accidents.**

- **Where the problem manifests** — Detection import overwrite and prebuilt upgrade currently fall through to `updateRule` (or a pMap of `upgradePrebuiltRule`). Each call is a decrypt GET, a key mint, an SO write, a TM call. At hundreds/thousands of rules the HTTP socket times out.
- **Why the old approach was a problem** — `bulkEdit` is “one patch, many ids.” Import/upgrade hand in a different body per id. There was no alerting API for that.
- **How the PR fixes it** — `RulesClient.bulkUpdateRules` loads a batch via PIT, authorizes once, writes via `bulkCreateRulesSo({ overwrite: true })`, remints keys for enabled rules, then `taskManager.bulkUpdateSchedules` grouped by new interval. Security Solution import overwrite and `upgrade/_perform` (same-type) call it.
- **Residual caveat** — Import lookup is one `findInstalledRulesByRuleIds` per chunk. Upgrade still does N `getRuleByRuleId` after the handler already loaded current rules. Alerting-layer unit tests exist (`bulk_update_rules.test.ts`); integration tests do not. Import-client tests cover overwrite, thrown bulk update, and enable-after-update.

Stated intent vs diff: the ticket was “add `RulesClient.bulkUpdate`.” This PR also implements the two downstream wirings (#275204, #264908). Return type is `{ successfulIds, errors, total }` at the alerting layer; import callers only get `{ rule_id }`.

---

### Summary

Adds `RulesClient.bulkUpdateRules`: a batched, per-id full overwrite of existing alerting rules. The method itself does not turn rules on or off. 409s from the executor’s `lastRun` write are retried on the failed rows only. Import overwrite (`overwrite=true`) and same-type prebuilt upgrade now go through this path instead of N `updateRule` / `upgradePrebuiltRule` calls.

Import overwrite honors the file’s `enabled` after the batch via `bulkEnableRules` / `bulkDisableRules`. Create-on-import uses `bulkCreateRules`. Type-change prebuilt upgrades still delete+create. Import chunks and alerting `batchSize` share `RULE_IMPORT_BATCH_SIZE` (200).

---

### Files touched

**Alerting primitive (the new write path)**
- `alerting/server/application/rule/methods/bulk_update/{bulk_update_rules,utils,types,index}.ts` — orchestrator, PIT load, prepare/merge, OCC retry, TM grouping. `withSpan` names `bulkUpdateRules.runBatch.*` / `putAttempt.*`.
- `alerting/server/application/rule/methods/update/types/update_rule_data.ts` — `enabled?: never` so callers cannot type-pass an on/off flip.
- `alerting/server/rules_client/rules_client.ts`, `rules_client/common/constants.ts`, `alerting/server/index.ts`, `rules_client.mock.ts` — public method, batch-size caps (10 / 100 / 500), 10k hard limit.
- `alerting/common/rule_circuit_breaker_error_message.ts` — `bulkUpdate` copy.

**Review notes in-tree**
- `bulk_update_rules_tradeoffs.md` — ten tradeoffs, meant for inline GitHub comments. Not product docs.

**Security Solution callers**
- `detection_rules_client` interface + impl + mock — `bulkUpdateRules` / `bulkUpgradePrebuiltRules`. `importRules` now returns `{ responses: Array<{ rule_id } | error> }` (no `ruleSourceImporter`).
- `methods/bulk_update_rules.ts` — converts `RuleResponse` → `UpdateRuleData` then delegates. Import overwrite calls `rulesClient.bulkUpdateRules` directly.
- `methods/import_rules.ts` — classify conflict / update / create from one installed-rules map. Update → `getChanges` then `bulkUpdateRules` (changed rules only) then enable/disable. Create → `bulkCreateRules`. Throws become per-rule errors. Passes `matchingAsset` from the batch map so overwrite does not refetch assets per rule.
- `methods/utils/get_changes.ts` — per-key `RuleResponse` diff (missing === `undefined`). Import also ignores `enabled`. Returns the field names that differ.
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
5. Update path: `applyRuleUpdate` (with `matchingAsset` from the batch map), then `getChanges(existing, after, ['enabled'])`. Unchanged ids skip the alerting call but stay in `successfulIds` so enable/disable still runs. Changed ids: `convertRuleResponseToAlertingRule` then `rulesClient.bulkUpdateRules` with `batchSize: 200`. Create path: `bulkCreateRules` with the same batch size.
6. Per alerting batch (`runBatch`): PIT decrypt load → `bulkEnsureAuthorized(Update)` (throw the call) → `validateScheduleLimit` on **enabled** rules whose interval changed (return errors; `circuitBreaker` stamps leftover batches and stops the loop) → `bulkMigrateLegacyActions` → `writeWithRetry`. Authz throws still hit import’s outer catch. Circuit-breaker errors come back on the result. See activity #8.
7. `prepareUpdate` (pMap, concurrency 50): schema, rule-type params, actions, `incrementRevision` (revision number only — always writes). Mint a key iff the existing rule is enabled (`createNewAPIKeySet({ shouldUpdateApiKey: original.enabled })`), merge onto the original SO, force `enabled: originalRule.enabled`.
8. `bulkCreateRulesSo({ overwrite: true })`. Per-row 409 → invalidate the **new** key for that row, wait 100ms, reload those ids, prepare again, retry (`RetryForConflictsAttempts` = 2). Full throw → invalidate every new key in the batch (the #264892 shape, scoped to the batch).
9. Success rows: invalidate **old** keys (gated on `!apiKeyCreatedByUser`), `updateTaskSchedules` grouped by new interval if `scheduledTaskId` exists and interval changed (on **or** off), `logRuleChanges`. TM errors are logged and swallowed; the id stays in `successfulIds`.
10. Import maps `successfulIds` to `{ rule_id }`. Then `bulkEnableRules` / `bulkDisableRules` for successful ids whose file `enabled` differs from the existing rule.

Same-type prebuilt upgrade is the same from step 5, with no skip — always writes — after a second round of `getRuleByRuleId` + `applyRuleUpdate` inside `bulkUpgradePrebuiltRules` (the handler already loaded current versions).

---

### Assumptions

- Executor `lastRun` / `executionStatus` writes are the main 409 source, and two retries at 100ms are enough for a running fleet. A real competing edit loses to last-writer-wins after retries.
- Import skip is `getChanges` on two `RuleResponse`s (ignore id / timestamps / `execution_summary`, and `enabled` at the call site). Per-key compare: a missing key and `undefined` are equal, so `applyRuleDefaults` filling optional fields as `undefined` does not force a write. Same-shape compare, so Cases / actions are in the diff. `applyRuleUpdate` copies `revision` from the existing rule.
- Callers never need the persisted rule documents back — only ids. Import HTTP and `detectionRulesClient.importRules` both return `{ rule_id }` (plus errors), not a `RuleResponse`.
- Mixed Update privileges across rule types in one batch are rare enough that failing the whole call is acceptable. Detection import/upgrade is usually one user, SIEM consumers.
- Disabled rules with a `scheduledTaskId` should have their paused TM task’s interval rewritten (same as `updateRule`). Later enable uses that cadence without rewriting the interval.
- `bulkCreateRulesSo` full throws are rare; import batches at 200, so the #264892 dead-key window is that chunk. A later bulk operation is expected to remint.
- ~~PIT decrypt failure on one document looks like “not found” (per-item error). No fallback to an undecrypted GET, unlike `updateRule`.~~ **WRONG — see activity #10 / Risk #11.** ESO PIT returns the SO with `error` plus stripped attributes. `loadRulesByIds` never checks `so.error`.
- The 10k cap is a backstop. Import’s real cap is `RULE_IMPORT_BATCH_SIZE` (200) per chunk. Upgrade’s loop is still 100.
- `tradeoffs.md` is review scaffolding and will not ship in the alerting plugin long-term.

---

### Risks

1. ~~**Import overwrite no longer honors `enabled`.** Old path: `importRule` → `toggleRuleEnabledOnUpdate`. New path: keep the existing on/off. Re-importing `"enabled": true` over disabled rules used to turn them on; now they stay off. The single-rule `importRule` API still toggles — two overwrites, two behaviors. The PR description treats this as intended; tradeoff 2 says callers will do enable/disable after the batch, and they don’t.~~ **FIXED**
   - `updateRules` now collects enable/disable ids and calls `bulkEnableRules` / `bulkDisableRules` only for `successfulIds`.
   - ~~Residual: if enable/disable returns per-item errors, that rule can show as both a `{ rule_id }` success and an error.~~ **FIXED — see activity #3.** Option A in `294caac1b9d`: record `{ rule_id }` only after enable/disable, and only when that flip succeeded.
   - ~~If `bulkEnableRules` throws, the outer catch skips ids already in `responses` — success, no flip, no error.~~ **WRONG — see activity #3.** `updateRules` throws before it returns the local successes, so the outer catch reports those `rule_id`s as errors. Body saved, no flip, client sees an error.
2. ~~**Circuit-breaker / authz throws are no longer per-item.**~~ **ADDRESSED for the circuit breaker (alerting layer); authz still throws.** See activity #8.
   - `validateScheduleLimit` overflow no longer throws. The overflowing batch fails as a whole (`errors`, status 400). Later inner batches are not run; leftover rules get the same error via `circuitBreaker`. Earlier batches stay in `successfulIds`. Import maps `result.errors`; upgrade maps `bulkErrors`.
   - `bulkEnsureAuthorized` still throws the call. Import’s outer `try/catch` maps that onto remaining rule_ids. Upgrade still lets the throw bubble.
   - `bulkMigrateLegacyActions` runs after the schedule check, so a breaker trip does not delete legacy sidecar SOs / `siem.notification` rules for rows that never write.
3. ~~**Uncommitted chunk 500 makes inner batching real.** Committed import chunk is 50 < default `batchSize` 100, so the inner loop never splits. At 500, you get five inner batches. An authz/circuit-breaker throw on batch 3 leaves batches 1–2 persisted, then the HTTP 400 above. Also 500 concurrent `getRuleByRuleId` finds per chunk (`Promise.all`).~~ **DONE**
   - Uncommitted 500 is gone. Outer chunk and `batchSize` share `RULE_IMPORT_BATCH_SIZE` (200). No nested inner batches on import.
4. ~~**No tests for a new public `RulesClient` method.** OCC retry, key invalidation on partial vs full throw, disabled+interval TM update, circuit breaker, authz-throw-the-call — none of it has a unit or integration test. Existing `detection_rules_client.import_rules.test.ts` still mocks `importRule` and only covers `overwriteRules: false`. Overwrite-enabled tests live on `importRule`, which this path no longer uses.~~ **STALE — see activity #10.** Unit tests landed in `bulk_update_rules.test.ts` (~892 lines, both PRs): OCC, keys, disabled+interval TM, breaker, authz-throw. Integration tests still missing (ticket #264894; #286508 out of scope).
   - Import-client tests cover overwrite, mixed create/update, thrown `bulkUpdateRules`, enable-after-update, and skip-when-unchanged.
5. **#264892 still applies per batch.** Full `bulkCreateRulesSo` throw invalidates every new key in that batch, including for docs ES may have written. Those rules keep a dead key until the next write. Documented; not closed.
6. **Upgrade double-fetches.** `perform_rule_upgrade_handler` already loaded current rules. `bulkUpgradePrebuiltRules` calls `getRuleByRuleId` per asset anyway (another find each). Extra ES load and a TOCTOU between the revision check and the write.
   - Architecture pass: this is the write method re-owning load. Sibling `revertPrebuiltRule` already takes `existingRule: RuleResponse`. See activity #2.
7. ~~**GitHub may auto-close #264892.** `closingIssuesReferences` includes it. The PR does not fix that ticket.~~ **STALE — see activity #10.** #284946 only closes #264894. #286508 closes nothing. Body already says Related, not Fixes.
8. **`IDetectionRulesClient.bulkUpdateRules` is a leaky public passthrough with no external caller.** It re-exports alerting knobs (`batchSize`, `exitEarlyOnError`) and writes `RuleResponse[]` with no ML authz / `applyRuleUpdate` / exception merge. Only `bulkUpgradePrebuiltRules` uses the method file internally. Import overwrite reimplements the same convert-and-delegate against `rulesClient.bulkUpdateRules` directly. A future caller of the client method will skip domain checks. This belongs as a private helper, not on the public interface. See activity #2.
9. **HTTP import and `importRule` are now two write implementations.** Before this PR, `importRules` composed `importRule`. After `da7eaf43af4` they diverge: bulk uses `bulkUpdateRules` + `bulkCreateRules` + `bulkEnable`/`bulkDisable` and returns `{ rule_id }`; single still uses `update` + `toggleRuleEnabledOnUpdate` and returns a `RuleResponse`. `import_rules/route.test.ts` still says the old composition is true. See activity #2.
10. **`prepareUpdate` fetches connectors twice per rule.** `validateActions` and `extractReferences` / `denormalizeActions` each `getBulk` the same ids (concurrency 50). APM pass left this; spans will confirm it, not fix it. See activity #7.
11. ~~**PIT decrypt failure is not “not found” — the stripped SO is merged and overwritten.**~~ **DEFERRED — see activity #11.** Not data corruption: only `apiKey` / `uiamApiKey` are stripped; the rule body write is fine. The leftover is an orphaned old key. Pre-existing on `bulkEditRulesOcc` (silent at the alerting layer) and `updateRule` (logs, still does not revoke the real key). Tradeoff 5; filed [#286812](https://github.com/elastic/kibana/issues/286812). Not fixing in this PR.

---

### Open questions

1. ~~Is dropping `enabled` on import overwrite a product decision, or an unfinished tradeoff 2? If product: the docs/API need to say overwrite does not change on/off. If unfinished: the caller still needs a `bulkEnable` / `bulkDisable` pass after the batch, like `toggleRuleEnabledOnUpdate` did.~~ **DONE** — unfinished toggle; callers now do `bulkEnable` / `bulkDisable` after the batch.
2. ~~Should `import_rules.ts` / `bulkUpgradePrebuiltRules` catch `bulkUpdateRules` throws (circuit breaker, authz) and turn them into per-item or per-chunk errors, instead of failing the HTTP request after a partial save?~~ **ADDRESSED for the circuit breaker** — alerting now returns those as `errors` (activity #8). Authz still throws; import catches, upgrade does not.
3. ~~Is `CHUNK_PARSED_OBJECT_SIZE = 500` meant to land? Tradeoff 9 says import stays at 50 and callers chunk. The method already inner-chunks at 100. 500 is the first time those two layers nest on import.~~ **DONE** — 500 never landed. Shared `RULE_IMPORT_BATCH_SIZE = 200` for outer chunk and `batchSize`.
4. Ticket asked for `{ rules, errors, total }`. Callers only get ids. Is that enough for upgrade telemetry / import UI, or will someone need the persisted revision/`updated_at` next?
   - Import now returns `{ rule_id }` only (`ImportRuleSuccess`). Thinner than before.
5. Should `bulkUpgradePrebuiltRules` take the already-loaded current rules from the handler instead of N `getRuleByRuleId` calls?
6. Is `bulk_update_rules_tradeoffs.md` staying in `alerting/server/...` after review, or is it PR-only scaffolding?
7. ~~Confirm #264892 should **not** close when this merges.~~ **DONE — see activity #10 / struck Risk #7.** Neither PR lists it in `closingIssuesReferences`.
8. Should `IDetectionRulesClient.bulkUpdateRules` stay on the public interface, or become a private helper shared by import overwrite and upgrade? (Risk #8)
10. ~~`skipIfUnchanged` lives in alerting (`incrementRevision` after the PIT load). Import already has `installedRulesById` and could drop no-ops before the call. Stay in alerting, or move the skip to Security Solution?~~ **ADDRESSED — see activity #5.** Tradeoff 10 picked B: skip in the caller. Import uses `getChanges` and does not pass a skip flag. Alerting always writes.
   - `enabled` is ignored in that diff, so enable-only reimport still hits `bulkEnable` / `bulkDisable`.
   - Skipped ids still count as success.
   - ~~Residual: `applyRuleDefaults` can make an otherwise identical file look changed.~~ **FIXED — see activity #6.** Whole-object `isEqual` treated missing vs `undefined` as different. Per-key `getChanges` does not. `updateRules` still has a TODO about an import flag.

---

### Notes for your codebase map

- Alerting now has three bulk write shapes: **create-many** (`bulkCreateRules`, persist-first + demote), **edit-many** (`bulkEditRulesOcc`, one patch + `retryIfBulkEditConflicts`), **update-many** (`bulkUpdateRules`, per-id bodies + reload-and-PUT). They share primitives (`bulkCreateRulesSo`, `createNewAPIKeySet`, PIT decrypt, `invalidateKeys`) but not orchestrators.
- `updateRule` / `bulkUpdateRules` never flip `enabled`. Detection create/update/patch/import-single do it afterwards via `toggleRuleEnabledOnUpdate` → `enableRule` / `disableRule`. Bulk import overwrite does the same follow-up via `bulkEnableRules` / `bulkDisableRules` on `successfulIds`.
- `incrementRevision` only decides the revision *number*. Alerting always writes the list it is given (tradeoff 10, Option B). Import skip is `getChanges` on two `RuleResponse`s before `bulkUpdateRules`. Skipped ids still count as success, so enable/disable still runs. Same-shape compare includes Cases / actions; that closes the old `systemActions`-exclude hole. See OQ #10 / activity #5–#6.
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

2. **Focused review: architecture.** Pass over the PR file list (alerting primitive + detection import/upgrade). Third write orchestrator (own `writeWithRetry`, shared primitives with `bulkCreate`/`bulkEdit`) and `enabled?: never` on `UpdateRuleData` are the right shape. Import chunk and alerting `batchSize` sharing 200 is the right layering. New findings: `IDetectionRulesClient.bulkUpdateRules` is a leaky unused public passthrough (Risk #8, OQ #8); import overwrite bypasses it and reimplements convert-and-delegate; `importRules` no longer composes `importRule` so two import write paths will drift (Risk #9); upgrade still re-owns load via N `getRuleByRuleId` instead of taking the handler’s already-loaded currents the way `revertPrebuiltRule` takes `existingRule` (Risk #6, OQ #5). Leftover `upgradePrebuiltRules` pMap on promotion-rule / legacy prepackaged is now OQ #9. Fixed the stale Notes enable bullet. Checked and clean: no inverted plugin deps, `timeouts.ts` → `constants.ts` is colocation not drive-by, type-change upgrade staying on delete+create is correct, `rule_source_importer` removal + `fetchPrebuiltImportContext` is a good extract.

3. **Risk #1 residual.** Re-read the enable/disable leftover after the import rewrite. Two items:

   - Throw path was a misread. `updateRules` throws before it returns local successes, so the outer catch reports those `rule_id`s as errors (body saved, no flip). Struck that sentence on Risk #1.
   - Per-item enable/disable error was real (success `{ rule_id }` plus an error). Two possible fixes: **A** do not record `{ rule_id }` until after the flip, and skip ids that failed. **B** record success, then remove it when the enable/disable error arrives. Option A in `294caac1b9d`. A per-item `bulkEnableRules` error is now the only result for that rule. Residual **FIXED**.

4. **Missed tradeoff: where `skipIfUnchanged` lives.** Import already loaded `installedRulesById`, so a no-op skip does not have to be an alerting flag. Raised as OQ #10.

   - **Inside alerting:** `incrementRevision` on the decrypted SO. Any caller gets it. Skipped ids stay in `successfulIds`, so import enable/disable still runs when only `enabled` changed. Cost: convert + PIT + prepare still run for no-ops.
   - **Outside, in Security Solution:** drop unchanged rules before `bulkUpdateRules`. Saves that work. The diff is `RuleResponse` vs `RuleResponse`, not revision, so it can disagree with alerting (e.g. generated action UUIDs). Must still treat those rules as success for enable/disable.

5. **Flipped tradeoff 10 to B (skip in the caller).** [`f741fee251f`](https://github.com/elastic/kibana/commit/f741fee251f2a3329ab14ef94be573f3d35502ae). `skipIfUnchanged` is gone from alerting types / `prepareUpdate`. Import `updateRules` runs `detectChanges(existing, after, ['enabled'])`; unchanged ids skip `bulkUpdateRules` but stay in `successfulIds` for enable/disable. Tests: unchanged → no write; enable-only → no write, still `bulkEnableRules`. Struck OQ #10. Residual: `applyRuleDefaults` can false-write; TODO in `updateRules` about an import flag. Upgrade still always writes (no skip). The old `systemActions` hole is closed on this path — Cases / actions are in the `RuleResponse` diff.

6. **Same-payload reimport always looked dirty.** [`0af6c07208e`](https://github.com/elastic/kibana/commit/0af6c07208e0070edeff221f30e57af6adb34582). Whole-object `isEqual(omit(...))` treated a missing key and `undefined` as different; `applyRuleDefaults` writes optional fields as `undefined`, so every reimport looked changed. Switched to per-key compare (missing === `undefined`) and renamed `detectChanges` → `getChanges` (returns the differing field names). Struck the OQ #10 `applyRuleDefaults` residual.

7. **Focused review: APM / `withSpan`.** [`cf16e0a0555`](https://github.com/elastic/kibana/commit/cf16e0a05551914e4be98cf6c2b679e40595897f). Existing spans were phase timers; migrate / invalidate / TM / change-history were dark. Added those (`bulkUpdateRules.runBatch.*` / `putAttempt.*`); skipped labels so APM did not grow extra args. Import APM showed ~200 `IPrebuiltRuleAssetsClient.fetchAssetsByVersion` per batch: `calculateRuleSource` refetched before `getChanges`. Import now passes `matchingAsset` from `fetchPrebuiltImportContext` (`undefined` still fetches). Residual: connector `getBulk` still twice per rule in prepare — raised as Risk #10. `validateScheduleLimit` is still one cluster agg per batch.

8. **Addressed Janki’s first-round review.** She asked to authorize before migrate, emit `BULK_UPDATE` audit, and stop authz / circuit-breaker throws from swallowing `successfulIds` after earlier batches are already saved ([pre-flight](https://github.com/elastic/kibana/pull/284946#discussion_r3814367979), [catch instead](https://github.com/elastic/kibana/pull/284946#discussion_r3814414676), [migrate order](https://github.com/elastic/kibana/pull/284946#discussion_r3814601877), [audit](https://github.com/elastic/kibana/pull/284946#discussion_r3812590080)). Steven pushed back on the extra find ([r3821470048](https://github.com/elastic/kibana/pull/284946#discussion_r3821470048)); she [agreed to drop it](https://github.com/elastic/kibana/pull/284946#discussion_r3822924583), keep inner batching, return breaker errors, and move migrate after the schedule check. Implemented ([r3828848522](https://github.com/elastic/kibana/pull/284946#discussion_r3828848522)).

   - Authz before `bulkMigrateLegacyActions`; `RuleAuditAction.BULK_UPDATE` for authz-failure and per-rule events — [`8528ca65f`](https://github.com/elastic/kibana/commit/8528ca65f6893299384c2ec32f0e3c96eec4c6d1) ([migrate reply](https://github.com/elastic/kibana/pull/284946#discussion_r3821105970), [audit reply](https://github.com/elastic/kibana/pull/284946#discussion_r3821111533)).
   - Pre-flight find **dropped**. Extra fields-find is a cost with no Detection benefit (import already chunks at 200 = `batchSize`). Inner batching **kept** (symmetry with `bulkCreateRules`; 10k cap would otherwise load/decrypt/mint in one pass).
   - Circuit breaker returns errors, does not throw. Overflowing batch fails as a whole (before `prepareUpdate`, no keys minted). `circuitBreaker` on the batch result stamps leftover rules and stops the outer `while` (`remaining.splice`). Earlier batches stay in `successfulIds` — [`1895eb464`](https://github.com/elastic/kibana/commit/1895eb464e73ffe08993d0b9a322fe24b0b16a1b). Tradeoff 7 flipped to C.
   - `bulkMigrateLegacyActions` now runs after the schedule check, just before `writeWithRetry`, so a trip does not delete legacy sidecars for rules we skip.
   - Authz still throws the call (tradeoff 6 unchanged).
   - Alerting-layer unit tests were drafted then dropped; Risk #4 still open. Import already maps `result.errors`, so a breaker trip is per-rule on `_import` without hitting the throw catch.

9. **Split Alerting into its own PR.** Pulled `RulesClient.bulkUpdateRules` into [#286508](https://github.com/elastic/kibana/pull/286508) so ResponseOps can review the framework without the Detection callers; Janki will review it today ([Slack DM](https://elastic.slack.com/archives/D0A9H3US5N1/p1787311628851679)).

   - Alerting-only PR is the source of truth. Description closer/#264892, breaker semantics, and chunk-size wording were corrected; leftover description cleanup and dropping the duplicated tradeoffs file are still open.
   - POC [#284946](https://github.com/elastic/kibana/pull/284946) restacked on that branch (import/upgrade wiring, skip-unchanged, prefetched assets as separate commits). `security_solution` type-check is green; Detection paths can exercise the method while #286508 is in review.

10. **Verify claims in the PR Review via roast** ([`.roast/pr-review-284946.md`](roast/pr-review-284946.md)). Checked the review against current #284946 + #286508 code. Import enable/skip/breaker still hold. Interesting findings from the roast:

      - **PIT decrypt is not “not found” (needs further investigation — possible data corruption?).** ESO PIT returns the SO with `error` plus stripped attributes; `loadRulesByIds` never checks `so.error`; `runBatch` merges and overwrites a half-decrypted original; the old API key cannot be invalidated. Same hole in `bulkEditRulesOcc`. Struck the assumption; raised Risk #11. Follow up: what actually gets written on a decrypt-failed row, and whether we must fail that id instead of proceeding.
      - Strike Risk #4 / #7. Unit tests exist (`bulk_update_rules.test.ts`, ~892 lines, both PRs); integration tests do not. `closingIssuesReferences` is only #264894 on the POC, empty on #286508 — #264892 will not auto-close.
      - Add the upgrade-test gap: no `bulk_upgrade_prebuilt_rules` tests (#264908 asked for same-type / type-change / mixed + API integration).
      - Mixed-chunk enable throw skips creates: `importRules` updates then creates; a `bulkEnableRules` / `bulkDisableRules` throw never reaches `createRules`.
      - Type-change-then-authz-throw: `bulkUpgradePrebuiltRules` persists type-change via pMap first; same-type authz throw 500s the handler and drops those successes from `results`.
      - Mention #286508 (alerting-only slice). Files touched should include `bulk_update_rules.test.ts`, `audit_events.ts`, and the `bulkCreateRules` span rename.

11. **Checked Risk #11 — PIT decrypt is NOT data corruption, just orphaned API keys.** Re-read the decrypt path. ESO only encrypts `apiKey` / `uiamApiKey`; a failed decrypt strips those two. The incoming body still overwrites the rest. What is lost is the old key values, so invalidation cannot run. Same leftover on `bulkEditRulesOcc` (no `so.error` check, alerting-layer silent) and `updateRule` (falls back to undecrypted GET, logs, marks ciphertext not the real key). ESO still logs `Failed to decrypt attribute "apiKey"` on both paths. 
      - Updated tradeoff 5 and filed [#286812](https://github.com/elastic/kibana/issues/286812) (`Decrypt failure orphans old API keys on bulkEdit and updateRule`). **Deferred** from this PR — address across the write methods later. Struck Risk #11.
