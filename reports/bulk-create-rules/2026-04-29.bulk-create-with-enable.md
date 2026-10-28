# Bulk-create + enable for the alerting `RulesClient`

Findings from reading the existing single-rule and bulk paths, and a recommended approach for a bulk method that creates **and** enables (including task scheduling) in one call.

Files reviewed:

- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/create/create_rule.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/lib/create_rule_saved_object.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/lib/schedule_task.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_enable/bulk_enable_rules.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/common/bulk_edit/bulk_edit_rules_occ.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/common/bulk_edit/retry_if_bulk_edit_conflicts.ts`
- `x-pack/platform/plugins/shared/task_manager/server/task_scheduling.ts` and `task_store.ts` (for `bulkSchedule` semantics)

---

## 1. How the platform composes "create + enable" today

### 1a. Single-rule `createRule` (legacy / authoritative path)

The single-rule path runs as one logical transaction with **best-effort compensation** on enable failure:

1. Validate, authorize, mint API key (only if `enabled: true`), validate actions, extract references, build `ruleAttributes`.
2. `createRuleSavedObject` does:
   - `createRuleSo(...)` to persist the rule SO. On throw → invalidate the freshly-minted API key, rethrow.
   - **If `enabled`**, `scheduleTask({ throwOnConflict: true })` to create a Task Manager task with the **same id as the rule**.
     - On throw → attempt `deleteRuleSo` to roll the SO back. If the delete also throws, log and swallow that error and rethrow the original schedule error. **The newly-minted API key is *not* invalidated in this code path** (a known leak).
   - Update the SO with `scheduledTaskId` (this update is **not** wrapped in try/catch).

Net semantics:

- Happy path: SO created, task scheduled, `scheduledTaskId` written.
- SO-create failure: clean — no SO, API key invalidated.
- Schedule failure with successful rollback: clean — no SO. (API key may leak.)
- Schedule failure with rollback failure: orphan SO, no task, error returned to caller. (API key leaks.)
- `scheduledTaskId` update failure: orphan task running, SO without `scheduledTaskId` recorded. (API key leaks.)

### 1b. `bulkEnableRules` (re-enable for already-existing SOs)

The shape is very different and worth absorbing in detail because it is the closest production-grade "bulk + tasks" precedent:

1. **Validate + authz filter**: `getAndValidateCommonBulkOptions`, build `kueryNodeFilterWithAuth`, then `checkAuthorizationAndGetTotal`.
2. **Run an OCC retry loop**: `retryIfBulkOperationConflicts` runs `bulkEnableRulesWithOCC` and, on per-row 409s, retries with a narrower filter built from the conflicted ids (chunked at `MaxIdsNumberInRetryFilter = 1000`, exponential-ish backoff via `waitBeforeNextRetry`).
3. **Inside the OCC body** (`bulkEnableRulesWithOCC`):
   - Use `encryptedSavedObjectsClient.createPointInTimeFinderDecryptedAsInternalUser` to stream all rules matching the filter — needed because action and API key fields are encrypted.
   - `bulkMigrateLegacyActions` (one-shot SO writeback for legacy connector shape).
   - `pMap` with `concurrency = MAX_RULES_TO_UPDATE_IN_PARALLEL = 50` builds three lists per rule, all under one isolated try/catch:
     - `rulesToEnable` — SO `bulkCreate`-style update objects with `enabled: true`, `lastEnabledAt`, fresh `executionStatus: pending`, fresh API key, `scheduledTaskId: rule.id`.
     - `tasksToSchedule` — Task Manager task instances with `enabled: false` (deliberately — they get enabled via `taskManager.bulkEnable` after persistence so the schedule datetime can be randomised across the batch to avoid stampede).
     - `rulesToClearFlapping` — for lifecycle alert types.
   - **Per-rule failures push into `errors[]` and the rule is dropped from all three lists.** No throw bubbles up.
4. **`taskManager.bulkSchedule(tasksToSchedule)`** — **not wrapped in try/catch in the OCC body**. If this throws, the whole OCC pass throws and `retryIfBulkOperationConflicts` re-runs the body. This means a transient task-store failure causes the rule attribute work to be redone, but no SO has been written yet — the order is `bulkSchedule` first, `bulkCreateRulesSo` second.
5. **`bulkCreateRulesSo({ overwrite: true })`** — persists all rules in one round-trip. Per-row errors are collected from the SO response and pushed into `errors[]`; successes contribute their `scheduledTaskId` to `taskIdsToEnable[]`. **No compensating delete of orphan tasks** — if SO write fails for a rule that we just scheduled a task for, the task lives on disabled (it was created with `enabled: false` and never reaches `bulkEnable`, so it never runs).
6. After the OCC retry returns, **`tryToEnableTasks(taskIdsToEnable)`** calls `taskManager.bulkEnable(...)`, which is idempotent and tolerant: per-task errors are collected into `taskIdsFailedToBeEnabled[]` and returned to the caller; no rollback is attempted.
7. Domain transform + return: `{ rules, errors, total, taskIdsFailedToBeEnabled }`.

Compensation discipline: **none**. Bulk enable's design point is "best-effort, surface partial state to the caller, never lose previously-existing rules." The caller is expected to reconcile by re-issuing or by reading rule state. The orphan-task case is mitigated because tasks are created `enabled: false` and only flipped on at the end.

### 1c. `bulkEditRulesOcc` (the OCC engine reused by edit)

Same skeleton as `bulkEnableRulesWithOCC`:

- ESO point-in-time finder for decrypted SOs, page size 100.
- `pMap` with `API_KEY_GENERATE_CONCURRENCY` to run per-rule `updateFn` that mutates shared `rules`, `errors`, `skipped`, `apiKeysMap`.
- `validateScheduleLimit` after building the change set; if it trips, all newly-minted API keys are bulk-invalidated, no SO write happens, and one error per rule is returned.
- One `bulkCreateRulesSo({ overwrite: true })` call. On throw, **all newly-minted API keys for not-user-created rules are bulk-invalidated**, then rethrown. On per-row error returned in the response, the per-row newly-minted API key is queued for invalidation; on per-row success, the **old** API key is queued for invalidation.
- Wrapped in `retryIfBulkEditConflicts` which retries on 409s only, narrowing the filter, with the same `MaxIdsNumberInRetryFilter = 1000` chunking.

Key reusable patterns from this file:

- **`apiKeysMap` keyed by rule id** carrying both old and new keys, `*CreatedByUser` flags, and UIAM variants — the canonical place to plan API key cleanup.
- **Two-phase invalidation**: pre-write (drop everything if validation trips), post-write (drop new on per-row failure, drop old on per-row success).
- **Conflict retry only on 409s** with id-based filter narrowing.

### 1d. The "disabled-only `bulkCreateRules`" building block

A disabled-only bulk-create primitive is a useful intermediate building block: it covers prebuilt rule installation (always disabled) and the create-half of a "create + enable" composition. Such a method would mirror the create logic of single `createRule` but skip the API-key, task-scheduling, and UIAM tag steps entirely, and would do its SO write via a single `bulkCreateRulesSo` call (no `overwrite`). It is a strict subset of the `bulkCreateAndEnableRules` recommended below — enabled-input handling is what the rest of this report focuses on.

## 2. Failure modes that any "create + enable" bulk method must answer

| Failure | Single `createRule` today | `bulkEnableRules` today | Must we match either? |
|---|---|---|---|
| API key creation fails for one input | Throws, no SO created | Per-rule push to `errors`, rule dropped | Per-rule, ideally |
| SO `bulkCreate` per-row error | n/a (single doc) | Per-rule push to `errors` | Per-rule |
| SO `bulkCreate` whole-call throw | Throws, API key invalidated | Throws (not caught in OCC body), retried by OCC layer | Invalidate all newly-minted keys, best-effort `bulkRemove` of Phase-3-scheduled task ids, then throw |
| `taskManager.bulkSchedule` whole-call throw | n/a (single task) | Throws, OCC retries the whole body | Per-rule errors for the enabled subset, invalidate their keys, **still create the disabled subset** (do not throw) |
| Per-task drop inside `bulkSchedule` (validation) | n/a | Silently logged + dropped in `task_store._bulkSchedule` (`task_store.ts:540-561`) | Diff returned ids vs requested ids, push per-rule errors, drop affected enabled rules **before Phase 4** |
| `taskManager.bulkEnable` per-task error | n/a | Collected into `taskIdsFailedToBeEnabled`, no rollback | Same |
| 409 conflict on SO write | n/a (new id) | OCC retry | Should not happen for create with pre-assigned uuids; treat as a hard error |
| Rule id collision (caller-supplied id) | Throws 409 | n/a | Must surface per-rule |

Three things are particularly worth calling out:

- **`taskManager.bulkSchedule` is *all or nothing* at the request level**. The implementation in `task_store._bulkSchedule` does a single `soClient.bulkCreate` with `overwrite: true` (`task_store.ts:566-580`). There is no per-task isolated try/catch around the SO call — if the call throws, the whole batch is gone.
- **`bulkSchedule` can also silently drop tasks without throwing.** The per-task `taskInstanceToAttributes` validation step (`task_store.ts:540-561`) logs and skips invalid instances, so the returned array can be shorter than the input. Any caller has to diff returned ids vs requested ids and treat the missing ones as per-rule errors — otherwise it will end up with rule SOs whose `scheduledTaskId` points at a task that was never created.
- **`scheduleTask` on the single path uses `taskManager.schedule` with the rule id as the task id.** This is the convention every consumer relies on (`bulkEnableRulesWithOCC` does the same: `id: rule.id`). Any new bulk path must preserve this 1:1 id mapping. It is also what makes per-rule orphan-task cleanup trivially possible (`removeIfExists(rule.id)`), and conversely what makes whole-batch orphan cleanup risky if not scoped to ids we actually wrote in this call (see Phase 4 below).

## 3. Recommended approach: `bulkCreateAndEnableRules`

I would design this as a **new alerting-plugin method** (not a security-wrapper composition), structured along the lines of `bulkEnableRulesWithOCC` but adapted for create. Reasons to keep it inside the alerting plugin:

- API key creation, action validation, reference extraction, and audit logging already live there.
- The 1:1 rule-id ↔ task-id convention is enforced there.
- The compensation logic (API key invalidation, orphan-task handling) is identical to existing bulk methods and benefits from being colocated and testable in isolation.
- The security wrapper stays a one-call thin facade — no follow-up `bulkEnableRules` orchestration on the caller side.

Below is the recommended pipeline. Ordering and try/catch placement matter; I have called out the rationale for each choice.

### 3.1 Method shape

```ts
async function bulkCreateAndEnableRules<Params extends RuleParams>(
  context: RulesClientContext,
  params: { rules: BulkCreateRulesItem<Params>[] }
): Promise<{
  rules: SanitizedRule<Params>[];           // fully created, possibly enabled
  errors: BulkOperationError[];             // per-rule failures (any phase)
  total: number;                            // input length
  taskIdsFailedToBeEnabled: string[];       // mirrors bulkEnableRules
}>;
```

Same envelope as `bulkEnableRulesResult` so the security wrapper can merge results uniformly with the existing flow.

### 3.2 Phases

```text
┌─────────────────────────────┐
│  PHASE 0 - reject empty,    │
│  partition by enabled flag  │
└──────────────┬──────────────┘
               │
┌──────────────▼──────────────┐
│  PHASE 1 - prepare per rule │  isolated try/catch per rule
│  (current bulk_create logic │  → push to errors[], drop from set
│   + API key generation if   │
│   enabled === true)         │
└──────────────┬──────────────┘
               │
┌──────────────▼──────────────┐
│  PHASE 2 - schedule limit   │  single circuit-breaker check across all
│  validateScheduleLimit      │  enabled inputs, before any persistence
└──────────────┬──────────────┘
               │
┌──────────────▼──────────────┐
│  PHASE 3 - bulkSchedule     │  task instances pre-built with enabled:false
│  taskManager.bulkSchedule   │  on whole-call throw → invalidate enabled
│  (only enabled rules)       │  subset's API keys, push per-rule errors,
│                             │  STILL proceed to Phase 4 with disabled
│                             │  subset; diff returned ids → silent-drop
│                             │  errors; track scheduledTaskIdsThisCall
└──────────────┬──────────────┘
               │
┌──────────────▼──────────────┐
│  PHASE 4 - bulkCreateRulesSo│  rule SOs carry scheduledTaskId already
│  (no overwrite for create)  │  per-row error → push to errors[],
│                             │  invalidate that rule's API key,
│                             │  remove orphan task IFF id is in
│                             │  scheduledTaskIdsThisCall (avoid nuking
│                             │  pre-existing rule's task on 409);
│                             │  whole-call throw → invalidate all keys,
│                             │  best-effort bulkRemove of Phase-3 ids,
│                             │  then rethrow
└──────────────┬──────────────┘
               │
┌──────────────▼──────────────┐
│  PHASE 5 - bulkEnable tasks │  taskManager.bulkEnable for the                       
│  (only successful enabled   │  successfully-persisted enabled rules
│   creations)                │  failures → taskIdsFailedToBeEnabled[]
└──────────────┬──────────────┘
               │
┌──────────────▼──────────────┐
│  PHASE 6 - shape return     │  domain transform, audit, return
└─────────────────────────────┘
```

### 3.3 Per-phase notes

**Phase 0 — partition.**
Two sub-arrays from the start: `disabledInputs` and `enabledInputs`. Disabled rules don't need API keys, schedule-limit validation, or task scheduling. Skipping those steps for them avoids unnecessary cluster load and matches the single-rule semantics. The `enabled: false` half is equivalent to a disabled-only `bulkCreateRules` primitive (Section 1d).

**Phase 1 — prepare.**
Per-rule preparation mirrors `createRule`'s pre-persistence logic: schema validation, authz, rule-type-enabled, params validation, `validateActions`, `validateAndAuthorizeSystemActions`, min-interval check, `extractReferences`, `transformRuleDomainToRuleAttributes`. For enabled inputs additionally:

- Mint an API key via `createNewAPIKeySet({ shouldUpdateApiKey: true })` (the same helper `bulkEnableRulesWithOCC` uses).
- Set `lastEnabledAt`.
- Set `scheduledTaskId: id` upfront on the SO attributes (matches `bulkEnableRulesWithOCC` line 280).
- Track the api key in an `apiKeysMap` keyed by rule id so Phase 3 and Phase 4 can clean it up if needed.

Per-rule failure → push to `errors[]`, drop from `preparedRules`. Do **not** throw.

**Phase 2 — single schedule-limit gate.**
`validateScheduleLimit({ context, updatedInterval })` over the enabled set. If it trips, **invalidate all newly-minted API keys** and produce one error per enabled input (not per all inputs — disabled ones should still be created). Mirrors `bulkEditRulesOcc`'s drop-and-error pattern.

Open decision: do we want to *skip* the failed-circuit-breaker rules and still create the disabled ones, or fail the whole batch? My recommendation is to still create the disabled ones — the circuit breaker is specifically a scheduling concern, and disabled rules carry no schedule cost.

**Phase 3 — `taskManager.bulkSchedule` first, with `enabled: false`.**
Two key choices, both copied from `bulkEnableRulesWithOCC`:

- **Tasks first, SOs second.** If task scheduling fails wholesale, no SOs were created, so the only cleanup needed is API keys. If SOs were created first and tasks failed wholesale, we'd need to bulk-delete potentially thousands of SOs.
- **Tasks scheduled with `enabled: false`** so they don't run until Phase 5 explicitly turns them on. This is the single biggest insight from `bulkEnableRules`: it splits "create the task SO" (atomic, all-or-nothing, can be retried) from "let it actually start running" (per-task idempotent, partial failures tolerated).

Failure policy — **partition-aware best effort, do not abort the disabled subset**:

- **Whole-call throw from `bulkSchedule`.** `bulkMarkApiKeysForInvalidation` over every newly-minted key in `apiKeysMap` (filter by `!apiKeyCreatedByUser`, like `create_rule_saved_object.ts:80-98`). Then push one error into `errors[]` per enabled input, carrying the underlying TM error message, and **drop the entire enabled subset** from `preparedRules`. Do **not** rethrow — proceed to Phase 4 with the disabled subset only. Rationale: disabled inputs have no dependency on Task Manager (single-rule `createRule` short-circuits TM via `if (rawRule.enabled)` at `create_rule_saved_object.ts:102`); aborting them for an unrelated subsystem failure violates Phase 0's whole reason for existing and is inconsistent with the design philosophy in Section 1b ("never lose work, surface partial state"). If the caller really needs all-or-nothing semantics they can submit a homogeneous batch.
- **Silent per-task drops.** After the call returns, diff `tasksToSchedule.map(t => t.id)` against the returned ids. For any missing id, push a per-rule error into `errors[]` and drop the rule from `preparedRules` before Phase 4. Without this, an enabled rule SO will land with a `scheduledTaskId` pointing at a task that does not exist, which Phase 5 will then fail to enable — surfacing the failure one phase too late and one error message too vague.
- **Track Phase-3-actually-scheduled task ids** (`scheduledTaskIdsThisCall`) for use by Phase 4's compensation. Anything not in this set is **not ours** to clean up.

**Phase 4 — `bulkCreateRulesSo`.**
Single SO `bulkCreate`. **Do not pass `overwrite: true`** here — unlike `bulkEnable`, which is updating existing SOs, `bulkCreate` should fail loudly on id collisions so callers learn about caller-supplied-id conflicts as per-row 409 errors.

Per-row error handling:

- Push to `errors[]`.
- Invalidate that rule's API key (`!apiKeyCreatedByUser`).
- **Delete the orphan task** via `taskManager.removeIfExists(rule.id)` (best-effort, log-only on failure), **only if** `rule.id ∈ scheduledTaskIdsThisCall`. This guard matters: a per-row 409 means a rule SO with that id already exists in the cluster — and almost certainly its own task too. Calling `removeIfExists` unconditionally would nuke that pre-existing rule's task. The guard ensures we only delete tasks we actually wrote in Phase 3 of this call.
- This is the bit that `bulkEnableRulesWithOCC` doesn't do today. It's worth doing here because we're the ones who created the task in this very call, and unlike `bulkEnable` (where rule SOs already exist before the call so the next retry self-heals via `overwrite: true`), a failed create leaves a task SO with no rule SO ever pointing at it.

Whole-call throw handling — **strict, symmetric cleanup**:

- `bulkMarkApiKeysForInvalidation` over every newly-minted key in `apiKeysMap` (same as Phase 3).
- Best-effort `taskManager.bulkRemove(scheduledTaskIdsThisCall)` wrapped in `try { ... } catch (e) { logger.error(...) }`. **Do not gate the rethrow on cleanup success** — if the cleanup itself throws, log the orphan ids and rethrow the original SO error. Rationale: tasks were scheduled `enabled: false` so the orphans are inert *today*, but this is a fragile invariant — if anyone later changes Phase 3 to schedule `enabled: true` (e.g., to elide the Phase 5 round-trip), every whole-batch SO failure becomes a fleet of running tasks against ghost rules. Symmetric cleanup makes that future change safe and matches the compensation discipline in single-rule `createRule` (`create_rule_saved_object.ts:113-127`).
- Then rethrow the original SO error. Unlike Phase 3's TM throw, an SO-write whole-call throw indicates the alerting plugin's primary persistence path is broken — there is no useful partial-success outcome to deliver to the caller.

Note on Section 1b's "accept orphans" stance: it is load-bearing in `bulkEnable` only because rule SOs already exist before the call, so the orphan task is bound to a real rule and the next successful enable retry overwrites it cleanly. For a fresh create, the orphan task points to a rule that never existed, breaking that invariant. The precedent does not transfer.

**Phase 5 — `taskManager.bulkEnable`.**
Reuse `tryToEnableTasks` verbatim from `bulk_enable_rules.ts:444-488`. Pass only the task ids in `scheduledTaskIdsThisCall ∩ successfullyPersistedEnabled` — i.e., tasks we actually scheduled in Phase 3 (excluding silent-drop victims and excluding Phase 4 per-row failures whose orphan task we just removed) and whose corresponding SO landed successfully. Per-task errors → `taskIdsFailedToBeEnabled[]`. **No SO rollback** if enable fails — the rule exists, it's just that its task hasn't been kicked off yet, which is the same partial-state outcome `bulkEnableRules` already exposes. The caller can re-enable to retry.

**Phase 6 — shape.**
Same domain transform + audit log as `bulk_enable_rules.ts:128-156`. Audit events should be emitted **per rule** with `RuleAuditAction.CREATE` — and a separate `RuleAuditAction.ENABLE` for the enabled subset, mirroring the single-rule path.

### 3.4 OCC: deliberately omit

`bulkEnable` and `bulkEdit` use `retryIfBulkOperationConflicts` because they target SOs that other writers (UI, other rules-client calls, the framework itself updating `executionStatus`) may be touching. **`bulkCreate` doesn't have this problem**: ids are caller-controlled and either net-new (no conflict possible) or pre-allocated uuids (no collision possible). Skip OCC entirely; surface 409s as per-row errors.

### 3.5 UIAM tag handling

For the new method, call `addMissingUiamKeyTagIfNeeded` per rule in Phase 1 just like the single-rule path. We're already iterating per rule in Phase 1 and have the API key in hand, so it's effectively free. Note that `bulkEnableRules` currently skips this — see Section 5 below.

### 3.6 Concurrency knobs

- Per-rule prepare in Phase 1: `pMap` with `API_KEY_GENERATE_CONCURRENCY` (the same as `bulkEditRulesOcc`) — this is bounded by the security plugin's API-key-creation throughput.
- Bulk SO call in Phase 4: single round-trip per chunk. Callers are expected to chunk inputs (existing security paths use a `BATCH_SIZE` of 50 for analogous bulk operations).
- Bulk `taskManager.bulkSchedule` in Phase 3: single round-trip; same chunking expectation.
- `tryToEnableTasks` in Phase 5: single `bulkEnable` round-trip; same.

## 4. What the security-side wrapper should look like

With `bulkCreateAndEnableRules` in place, the security wrappers (`bulkImportRules`, `bulkCreatePrebuiltRules`) collapse to:

- Prebuilt: call a disabled-only `bulkCreateRules` (or `bulkCreateAndEnableRules` with all `enabled: false` inputs). No enable phase needed.
- Import:
  1. Pre-checks per chunk: version check, exception lists, ML auth, ruleSourceImporter.
  2. `findRules` bulk-lookup for `rule_id` conflicts.
  3. **One** call to `bulkCreateAndEnableRules` for "new" rules — no separate `bulkEnableRules` step, no follow-up reconciliation.
  4. Existing-and-overwrite path stays per-rule via `importRule` (out of scope for the bulk path).
  5. Merge results.

Net effect: one round-trip per chunk regardless of how many rules are enabled, no partial-state surface area between create and enable on the security side, alerting plugin remains the single owner of the rule-task lifecycle.

## 5. Alternative: composition in the security wrapper

A lighter-touch alternative is to **not** add `bulkCreateAndEnableRules` to the alerting plugin and instead have the security wrapper compose a disabled-only `bulkCreateRules` with the existing `bulkEnableRules`. Trade-offs:

- **`bulkEnableRules` mints fresh API keys** (line 253-260 of `bulk_enable_rules.ts`). For just-created rules these are guaranteed to be the only keys, so no extra invalidation is needed. Good.
- **No way to surface "rule was created but enable failed" cleanly** beyond the existing `errors[]` + the rule appearing in the result with `enabled: false`. The caller (route handler) needs to translate `bulkEnableRules.errors` into `RuleImportErrorObject`s that point at the right `rule_id`.
- **Two round-trips per chunk** (one create, one enable) instead of one. For big imports this is the dominant cost.
- **Two audit events per enabled rule** in two phases (CREATE in `bulkCreate`, ENABLE in `bulkEnable`) — fine and arguably desirable.
- **Schedule limit is checked only in the enable phase** (not in `bulkCreate` since rules are disabled there). Acceptable; the enable check is the meaningful one.
- **No coupling to the alerting public API.** Can land entirely in the security solution plugin.

The composition path is faster to deliver and lower risk for the alerting plugin. The "promote to alerting plugin" path is the cleaner long-term landing spot once the failure semantics described in Section 3 are agreed on.

## 6. Concrete recommendations

1. **Preferred:** add `bulkCreateAndEnableRules` in the alerting plugin with the pipeline in Section 3.2. Wire the security wrappers (`bulkImportRules`, prebuilt installation) to call it directly. Cover:
   - Per-rule API key invalidation on per-row SO failure.
   - Orphan-task cleanup on per-row SO failure, **scoped to `scheduledTaskIdsThisCall`** so a 409 on a caller-supplied id collision doesn't nuke a pre-existing rule's task.
   - Whole-batch API key invalidation + best-effort `taskManager.bulkRemove(scheduledTaskIdsThisCall)` on whole-call SO `bulkCreate` throw, then rethrow.
   - Whole-batch `taskManager.bulkSchedule` throw: invalidate the enabled subset's keys, push per-rule errors for the enabled subset, **continue with the disabled subset** (do not throw).
   - Silent per-task drops from `bulkSchedule`: diff returned ids vs requested ids and treat each missing id as a per-rule error before Phase 4.
2. **Acceptable fallback:** wrapper-side composition of disabled-only `bulkCreateRules` + `bulkEnableRules` per Section 5. Ensure the wrapper:
   - Calls `bulkEnableRules({ ids: [...successfullyCreatedEnabledIds] })` and threads `errors` and `taskIdsFailedToBeEnabled` back into the import response.
   - Treats `bulkEnableRules`-side failures as "rule created but disabled," not as create failures.
3. **Independent cleanup, valuable in either case:** in `create_rule_saved_object.ts`, the schedule-failure rollback branch (lines 113-127) leaks the API key. Adding the same `bulkMarkApiKeysForInvalidation` block from the SO-create-failure branch would make the legacy single path correct.
4. **Known gap worth fixing alongside this work:** `bulkEnableRules` (and any disabled-only `bulkCreateRules`) skips `addMissingUiamKeyTagIfNeeded`. In serverless with `PROVISION_UIAM_API_KEYS_FEATURE_FLAG` enabled, rules created or enabled via these paths will lack the `MISSING_UIAM_API_KEY_TAG`. Fix once, in every bulk method that mints an API key.

## 7. NOTE: API key invalidation bug in bulk edit partial failure (issue #264892)

Github issue #264892 aims to fix the catch block around `bulkCreateRulesSo` in `saveBulkUpdatedRules` (`bulk_edit_rules_occ.ts`, lines ~183-246): on a whole-call throw it invalidates *every* newly-minted API key in `apiKeysMap`, including ones whose rules may already be persisted. Per-row errors in the SO response are handled correctly; only the whole-throw branch is wrong.

Once `bulkCreate` handles enabled rules (Phase 1 + Phase 4 of Section 3.2) it inherits the exact same shape: an `apiKeysMap`, a single `bulkCreateRulesSo`, and the same partial-vs-throw split. 

- If bulkCreate handles enabled rules, it must mint API keys per rule (single-rule createRule does this).
- Once you have an apiKeysMap and a single bulkCreateRulesSo write, you inherit the exact same failure shape as saveBulkUpdatedRules: full-throw vs partial-error API key invalidation.
- You don't want to copy the buggy pattern. 
#264892 establishes the corrected per-item invalidation pattern that 
our changes should reuse / mirror.

