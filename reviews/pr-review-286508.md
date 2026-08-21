# PR Review: #286508 — [Security Solution][Alerting] RulesClient.bulkUpdateRules

**PR:** [elastic/kibana#286508](https://github.com/elastic/kibana/pull/286508) by @sdesalas

**Scale:** Substantive PR.

Related: [issue #264894](https://github.com/elastic/kibana/issues/264894) (this method), [POC #284946](https://github.com/elastic/kibana/pull/284946) (Detection callers, will rebase onto this), sibling [bulkCreate #269340](https://github.com/elastic/kibana/pull/269340), related [API-key invalidation #264892](https://github.com/elastic/kibana/issues/264892) (explicitly not fixed).

---

### Context / Motivation

Detection-rule **`rules/_import` overwrite** ([#275204](https://github.com/elastic/kibana/issues/275204)) and prebuilt **`upgrade/_perform`** ([#264908](https://github.com/elastic/kibana/issues/264908)) need to overwrite hundreds of *existing* rules, each with its **own** new body. Today that is N `updateRule` calls (or a `pMap` of singles) and it times out at customer scale ([#249176](https://github.com/elastic/kibana/issues/249176), [#199101](https://github.com/elastic/kibana/issues/199101)).

Alerting already has two bulk writes. Neither fits:

- `updateRule` — one rule, full new definition. N SO writes, N key mints, N TM calls.
- `bulkEditRules` / `bulkEditRulesOcc` — the **same** patch on every matching rule. Import/upgrade hand in a **different** body per id.

[#264894](https://github.com/elastic/kibana/issues/264894) asked for `RulesClient.bulkUpdate` as a public method. The original ticket sketched per-id encrypted SO GETs at concurrency 50, reuse of `bulkEdit` OCC/save, and a `{ rules, errors, total }` return.

Reviewers then pushed on that sketch:

- Christos ([comment](https://github.com/elastic/kibana/issues/264894#issuecomment-4333902656)): use the PIT finder + `convertRuleIdsToKueryNode`, not N decrypt GETs.
- The ticket itself: share OCC/save/API-key/TM infrastructure with `bulkEdit`.
- [#264892](https://github.com/elastic/kibana/issues/264892): a full `bulkCreateRulesSo` throw can still have written some docs; wiping every new API key is the wrong fix.

This PR is the Alerting-framework method only. Detection callers stay on the POC. It was split so ResponseOps can review the primitive without the Security Solution wiring.

---

### Validating the issue — does this PR address it?

**The performance problem is real. The PR adds the missing alerting primitive. It does not match the ticket on return shape, `bulkEdit` sharing, or integration tests — those are documented tradeoffs, not accidents.**

- **Where the problem manifests** — Import overwrite and prebuilt upgrade currently fall through to `updateRule` (or a pMap of `upgradePrebuiltRule`). Each call is a decrypt GET, a key mint, an SO write, a TM call. At hundreds of rules the HTTP socket times out.
- **Why the old approach was a problem** — `bulkEdit` is “one patch, many ids.” Import/upgrade hand in a different body per id. There was no alerting API for that.
- **How the PR fixes it** — `RulesClient.bulkUpdateRules` loads a batch via PIT, authorizes once, writes via `bulkCreateRulesSo({ overwrite: true })`, remints keys for enabled rules, then `taskManager.bulkUpdateSchedules` grouped by new interval. Detection callers are **not** in this PR.
- **Residual caveat** — No HTTP endpoint, so no integration tests here (stated). Callers only get ids back, not hydrated rules. `#264892` still applies per batch. Authz still throws the whole call after earlier batches may have been written.

Stated intent vs diff: the ticket was “add `RulesClient.bulkUpdate`” with `{ rules, errors, total }` and bulkEdit sharing. This PR ships `{ successfulIds, errors, total }` (same as `bulkCreateRules`) and a tailored orchestrator copied from create-many, not `saveBulkUpdatedRules`. `closingIssuesReferences` is empty — #264894 is Addresses, not Fixes; #264892 will not auto-close.

---

### Summary

Adds `RulesClient.bulkUpdateRules`: a batched, per-id full overwrite of existing alerting rules. Shape follows `bulkCreateRules` (list + inner batches of 100, cap 10k). Semantics follow `updateRule` (full SO overwrite, mint a key if the rule is on, reschedule TM if the interval changed). It does **not** turn rules on or off — callers that need a flip use `bulkEnableRules` / `bulkDisableRules` afterwards. 409s from the executor’s `lastRun` write are retried on the failed rows only. A permission miss throws. A schedule-limit overflow returns 400s for that batch and leftover rules, and keeps earlier successful ids.

---

### Files touched

**New write path**
- `alerting/server/application/rule/methods/bulk_update/{bulk_update_rules,utils,types,index}.ts` — orchestrator, PIT load, prepare/merge, OCC retry, TM grouping. `withSpan` names `bulkUpdateRules.runBatch.*` / `putAttempt.*`.
- `alerting/server/application/rule/methods/bulk_update/bulk_update_rules.test.ts` — ~890 lines covering empty input, on/off, keys, TM, batching, missing ids, authz throw, circuit breaker, prepare isolation, OCC retry, exit-early, missing connector secrets, audit, change tracking.

**Public API / wiring**
- `alerting/server/rules_client/rules_client.ts`, `rules_client.mock.ts`, `alerting/server/index.ts` — public method + mock default `{ successfulIds: [], errors: [], total: 0 }`.
- `alerting/server/rules_client/common/constants.ts` — `MIN/DEFAULT/MAX_BULK_UPDATE_BATCH_SIZE` = 10 / 100 / 500 (mirrors create).
- `alerting/server/rules_client/common/audit_events.ts` — `RuleAuditAction.BULK_UPDATE` (`rule_bulk_update`, event type `change`).
- `alerting/common/rule_circuit_breaker_error_message.ts` — `action: 'bulkUpdate'` copy.
- `alerting/server/application/rule/methods/update/types/update_rule_data.ts` — `enabled?: never` so callers cannot type-pass an on/off flip. This is the shared `updateRule` payload type.

**Sibling drive-by**
- `alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts` — `withSpan` names prefixed with `bulkCreateRules.` so APM can tell the two methods apart. No behavior change.

---

### Flow trace

A caller (eventually import overwrite / prebuilt upgrade) invokes `rulesClient.bulkUpdateRules({ rules: [{ id, data }], batchSize?, exitEarlyOnError?, changeTracking?, allowMissingConnectorSecrets? })`.

1. Cap check (10k) and `batchSize` bounds (10–500). Empty list returns immediately. `getUserName` + `getActionsClient` once for the whole call.
2. Outer `while`: splice a batch, `runBatch`. On circuit-breaker, stamp leftover input with the same 400 and stop. On `exitEarlyOnError` after any batch error, skip leftovers (those ids are absent from both `successfulIds` and `errors`).
3. `loadRulesByIds` — ESO PIT finder, filter `convertRuleIdsToKueryNode(ids)` (`alert.id: alert:<id>`), `perPage: 100`, namespace if `context.namespace` is set. Missing ids become per-item `"Saved object [alert/${id}] not found"`. Duplicate ids in the batch collapse via `Map` (last payload wins, silently).
4. `bulkEnsureAuthorized({ operation: Update })` on unique `(alertTypeId, consumer)` pairs from the **loaded** SOs. Failure: one `BULK_UPDATE` audit with the error, then **throw**. Earlier batches are already persisted.
5. Circuit breaker: only **enabled** rules whose interval actually changed. Overflow → 400s for every rule still in `toPrepare` plus leftover batches; no prepare, no keys, no migrate. Earlier successful ids stay.
6. `bulkMigrateLegacyActions` on the loaded SOs (after the breaker, so a trip does not delete SIEM sidecar actions for rows that never write).
7. `writeWithRetry` / `putAttempt`: `pMap` of `prepareUpdate` at concurrency 50. Schema, rule-type params, actions, `incrementRevision` (revision *number* only — always writes). Mint a key iff `original.enabled`. Merge onto the original SO, force `enabled: originalRule.enabled`.
8. `bulkCreateRulesSo({ overwrite: true })` with OCC `version`. Per-row 409 → invalidate the **new** key for that row, wait 100ms, reload those ids, prepare again, retry (`RetryForConflictsAttempts` = 2, so 3 attempts). Full throw → invalidate every new key in the batch (#264892 shape, scoped to the batch) and return per-item errors (does not rethrow).
9. Success rows: invalidate **old** keys (gated on `!apiKeyCreatedByUser` inside `invalidateKeys`), `updateTaskSchedules` grouped by new interval if `scheduledTaskId` exists and interval changed (on **or** off), `logRuleChanges` defaulting to `ruleUpdate`. TM errors are logged and swallowed; the id stays in `successfulIds`.
10. Return `{ successfulIds, errors, total }`. `total` is the input length, including skipped leftovers and errors.

---

### Assumptions

- Executor `lastRun` / `executionStatus` writes are the main 409 source, and two retries at 100ms are enough. A real competing edit loses to last-writer-wins after retries. The reload is what picks up the executor’s new `version` (and `lastRun`); the user payload is applied again.
- Callers never need the persisted rule documents back — only ids. Import/upgrade can map ids to `rule_id` themselves. Matches `bulkCreateRules`.
- Mixed Update privileges across rule types in one batch are rare enough that failing the whole call is acceptable (tradeoff 6). Detection import/upgrade is usually one user, SIEM consumers.
- Disabled rules with a `scheduledTaskId` should have their paused TM task’s interval rewritten (same as `updateRule`). Later enable uses that cadence without rewriting the interval. Circuit breaker only counts **enabled** interval changes (also same as `updateRule`).
- `bulkCreateRulesSo` full throws are rare; the #264892 dead-key window is one inner batch (default 100). A later bulk operation is expected to remint.
- Inner `batchSize` 100 is the ES/key-mint unit. Callers still chunk for memory (import HTTP is 50 today / 200 on the POC; upgrade is 100). The 10k cap is a backstop, not a supported payload size.
- `updateRuleDataSchema` `{ unknowns: 'allow' }` plus the explicit `enabled: originalRule.enabled` assignment is enough to keep on/off flips out at runtime. The `enabled?: never` on the shared type is the compile-time half of that.
- Decrypt-failed PIT rows are rare enough (AAD drift) that matching `bulkEdit`’s “proceed anyway” is acceptable. See Risk 1.

---

### Risks

1. **PIT decrypt failure is not “not found” — the stripped SO is merged and overwritten.** ESO `createPointInTimeFinderDecryptedAsInternalUser` catches decrypt errors, strips encrypted fields (`apiKey`, `uiamApiKey`), and returns the same SO with `error` set — the caller is supposed to stop or proceed on public fields only (`encrypted_saved_objects/server/saved_objects/index.ts` ~162–169). `loadRulesByIds` concatenates `saved_objects` with no `so.error` check. `runBatch` only errors when the id is missing from the map, so a decrypt-failed rule goes into `prepareUpdate` as a normal original: merge onto a doc with `apiKey` stripped, mint a new key if enabled, overwrite. The old key is gone from the stripped attributes so it cannot be invalidated. `updateRule` at least falls back to an undecrypted GET and skips key invalidation. Same hole exists in `bulkEditRulesOcc`’s PIT loop. Rare, but the failure mode is silent corruption + an orphaned key, not a per-item error.

2. **Authz throw after a partial save.** `bulkEnsureAuthorized` still throws. The unit test `'authz throw on later batch: earlier batch already written, call throws (current behavior)'` documents it. With default `batchSize` 100, a 200-rule call can persist batch 1 and then throw on batch 2 — the caller gets an exception, not `{ successfulIds: [...batch1], errors: [...] }`. Circuit-breaker was changed to return errors for exactly this reason; authz was not. Detection import’s outer catch can map the throw onto remaining ids; a future caller that assumes “throw means nothing persisted” will be wrong.

3. **#264892 still applies per batch.** Full `bulkCreateRulesSo` throw invalidates every new key in that batch, including for docs ES may have written. Those rules keep a dead key until the next write. Documented as tradeoff 4; not closed. Batches bound the blast radius vs `saveBulkUpdatedRules` doing it for the whole edit.

4. **OCC retry remints keys and re-runs prepare.** The comment says “reload and apply the same payload.” `putAttempt` always goes through `prepareUpdate`, which calls `createNewAPIKeySet` again. The first attempt’s new keys are invalidated (409 is treated as a failed row). Extra ES/security traffic under executor conflict. Action UUIDs are stable (`uuid || v4()`), but `updatedAt` and the API key change. Two retries may not be enough if the executor writes `lastRun` faster than 100ms.

5. **Circuit breaker fails the whole overflowing batch, not just the interval-changers.** One enabled interval change that overflows 400s every other rule in that batch (including unchanged-interval and disabled rules that were going to write) plus leftovers. The error message’s `rules: updatedInterval.length` counts only the changers, so the copy can disagree with the number of error rows. Intentional (tradeoff 7 C) — cluster limit, not per-rule — but a 100-rule batch with one aggressive interval becomes a 100-rule failure.

6. **Leftovers on `exitEarlyOnError` vanish from the result.** They are not in `successfulIds` and not in `errors`. `total` still counts them. Callers that do `successfulIds.length + errors.length === total` will not get equality. Fine if the only consumer is the POC import catch, easy to miss for anyone else.

---

### Open questions

1. Should `loadRulesByIds` treat `so.error` as a per-item failure (and skip the write), instead of merging a stripped original? `updateRule` already special-cases decrypt failure. Copying `bulkEdit`’s hole into a third write path locks it in.

2. Ticket asked for `{ rules, errors, total }`. Callers only get ids. Is that enough for upgrade telemetry / import UI, or will someone need the persisted revision / `updated_at` next? Sibling `bulkCreateRules` made the same choice.

3. Should an authz miss on a later batch return errors for that batch (and leftovers) the way the circuit breaker now does, instead of throwing? Mixed privileges are rare, but the throw is the one remaining “partial persist + exception” path, and the test already admits it.

4. Confirm #264892 should stay open when this merges. Body says Related; `closingIssuesReferences` is empty. Good — just don’t let GitHub keywords creep in.

5. Duplicate ids in `rules[]` are silently last-wins (`new Map(batch.map(...))`). Worth a per-item error, or is that the caller’s problem?

6. `UpdateRuleData.enabled?: never` also tightens `updateRule`’s public type. Any existing `as UpdateRuleData` casts that smuggle `enabled` will start failing the type check. `convertRuleResponseToAlertingRule` does **not** pass `enabled`, so Detection is fine today. Worth a note in the PR for ResponseOps?

---

### Notes for your codebase map

- Alerting now has three bulk write shapes: **create-many** (`bulkCreateRules`, persist-first + demote), **edit-many** (`bulkEditRulesOcc`, one patch + `retryIfBulkEditConflicts`), **update-many** (`bulkUpdateRules`, per-id bodies + reload-and-PUT). They share primitives (`bulkCreateRulesSo`, `createNewAPIKeySet`, PIT decrypt, `invalidateKeys`) but not orchestrators.
- `updateRule` / `bulkUpdateRules` never flip `enabled`. Detection create/update/patch/import-single do it afterwards via `toggleRuleEnabledOnUpdate` → `enableRule` / `disableRule`. Bulk import overwrite (POC) does the same follow-up via `bulkEnableRules` / `bulkDisableRules`.
- `incrementRevision` only decides the revision *number*. Alerting always writes the list it is given (tradeoff 10, Option B). Skip-if-unchanged belongs in the caller.
- TM interval is rewritten for disabled rules that still have a `scheduledTaskId`. Circuit breaker only counts **enabled** interval changes. Same split as `updateRule`.
- ESO PIT finder does not throw on decrypt failure — it returns the SO with `error` + stripped encrypted attributes. Consumers must check `so.error`. `bulkEdit` doesn’t. This method doesn’t either.
- `invalidateKeys` never throws (logs inside `bulkMarkApiKeysForInvalidation`) and skips keys with `apiKeyCreatedByUser`. User-owned keys are left alone on purpose.

---

### Review activities

