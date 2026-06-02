# PR #269340 — `[Security Solution][Alerting] Add rulesClient.bulkCreate(), with feedback from ResponseOps`

**Author:** @sdesalas
**Base:** `main` ← `bulk-create-enable-alert-rules-feedback`
**Linked issue:** elastic/kibana#264893
**Reviewers requested:** `@elastic/response-ops`
**Scale:** Substantive (new public RulesClient surface, +2,000 LoC, touches a shared `task_manager` primitive).

---

## Ownership

All changed files are owned by `@elastic/response-ops` (the alerting plugin and `task_manager` plugin both belong to them). `change_tracking/` would have been the only `@elastic/security-detection-rule-management` slice, but this PR doesn't touch it directly — it just *consumes* `logRuleChanges`. So:

- **For your team (security-detection-rule-management):** zero owned files. You're the consumer / requester. Worth being satisfied that the contract returned to you (`{ successfulIds, errors, total }`) is sufficient for the prebuilt-rules install/import flows you'll wire it up to in #271722.
- **For response-ops:** every file in this PR. They are the accountable reviewers, especially for the `task_scheduling.ts` change.

## Summary

Adds a new public method `RulesClient.bulkCreateRules` to the alerting framework that creates many rules in one call, handling both `enabled: true` and `enabled: false` rules in a single round-trip. The flow is split into a fast in-memory pre-validation phase (A) and a batched ES-write phase (B), with explicit "demote to disabled" semantics whenever an enabled rule cannot be scheduled (API key mint failure, schedule limit, TM throw, TM silent drop). On success, only IDs are returned (not full rules). Best-effort cleanup of partially-created tasks and pending API keys runs on per-row SO errors.

The PR also (separately advertised as #269991) changes a shared `TaskScheduling` primitive: when `bulkSchedule` or `bulkEnable.runSoon` receive **more than one** task, **every** task is now jittered. Previously, the first task ran immediately and the rest were jittered. This is co-merged here.

The stated intent in #264893 ("disabled-only scope") has been deliberately broadened during review to cover enabled rules too, and the API surface evolved 6 rounds with response-ops. The diff matches the PR description's six-feedback summary; I didn't find divergence between intent and implementation.

## Files touched

- **`bulk_create/{bulk_create_rules.ts, utils.ts, types.ts, index.ts}`** — the new method, split into orchestrator (`bulk_create_rules.ts`), per-rule prepare/demote helpers (`utils.ts`), and types.
- **`bulk_create/bulk_create_rules.test.ts`** — 1k LoC of unit tests covering happy paths, every demotion reason, batching, `exitEarlyOnError`, and change tracking.
- **`rule_circuit_breaker_error_message.ts`** — adds the `'bulkCreate'` action variant to the existing circuit-breaker message helper.
- **`rules_client/rules_client.ts` + `rules_client.mock.ts` + `server/index.ts`** — wiring: register on the `RulesClient` class, mock it for downstream tests, export the public types.
- **`rules_client/common/constants.ts`** — adds `DEFAULT_BULK_CREATE_BATCH_SIZE = 100` and `MAX_BULK_CREATE_BATCH_SIZE = 500` (`MAX_RULES_NUMBER_FOR_BULK_OPERATION = 10000` already existed).
- **`task_manager/server/task_scheduling.ts` + `task_scheduling.test.ts`** — the **wider-impact** change: jitter every task whenever there are >1, instead of "first runs now, rest are jittered." Affects all callers of `bulkSchedule` and `bulkEnable.runSoon`.

## Flow trace

Walking the most-important path: caller invokes `rulesClient.bulkCreateRules({ rules: [...mix of enabled+disabled], batchSize, exitEarlyOnError })`.

1. `bulk_create_rules.ts:bulkCreateRules` short-circuits empty inputs, throws on `> MAX_RULES_NUMBER_FOR_BULK_OPERATION`, clamps `batchSize` to `[1, 500]`, and assigns each input an id (`options.id ?? generateId()`).
2. **Phase A1 (`preValidate.checkInMemory`)** — sequential per-rule loop. For each rule: `addGeneratedActionValues` → `createRuleDataSchema.validate` → `ruleTypeRegistry.get` → `ensureRuleTypeEnabled` → `validateRuleTypeParams` → `parseDuration(interval)` → minimum-interval enforce check. Failures are pushed into `errors` and the rule is **dropped from the validated set** (or the whole call short-circuits if `exitEarlyOnError`). Each surviving rule is also added to an `authPairs` map keyed by `${alertTypeId}::${consumer}`.
3. **Phase A2 (`preValidate.ensureAuthorized`)** — sequentially calls `authorization.ensureAuthorized` once per `(ruleTypeId, consumer)` pair. On a single pair-level rejection, every rule in that pair gets a per-rule audit log entry (CREATE / failure), a per-rule error pushed, and is removed from the validated map.
4. The orchestrator splits the survivors into batches of `batchSize`. Each batch is processed by `runBatch` end-to-end before the next batch starts.
5. **Phase B1 (`runBatch.pMap.prepareRule`)** — `pMap` over the batch with `concurrency: API_KEY_GENERATE_CONCURRENCY` (50). Per rule, `prepareRule` does `addGeneratedActionValues` (again — see Risks), `validateActions` (ES — connector lookups), `validateAndAuthorizeSystemActions`, mints an API key if `data.enabled === true`, runs `extractReferences`/`transformRuleDomainToRuleAttributes`, and stamps `lastEnabledAt` + `scheduledTaskId = id` if effectively enabled. **API-key mint failure is non-fatal**: rule degrades to `enabled: false`, gets a `disabledReason: 'api_key_creation_failed'` error, and continues.
6. **Phase B2 (`runBatch.validateScheduleLimit`)** — single circuit-breaker call against the *enabled* survivors' intervals. On overflow, `demotePreparedRules` flips every enabled rule in this batch to disabled, queues their API keys for invalidation, and pushes per-rule degraded errors with `disabledReason: 'schedule_limit_exceeded'`.
7. **Phase B3 (`runBatch.bulkSchedule`)** — `taskManager.bulkSchedule` for survivors, with `enabled: true` and **no** `runAt`/`scheduledAt` (relies on the new TM jitter behavior). Whole-call throw → demote all enabled to disabled with `disabledReason: 'task_schedule_failed'`. Silent per-task drops (TM's `taskInstanceToAttributes` quietly skipping) are detected by diffing requested vs returned ids and demoted with `disabledReason: 'task_validation_failed'`.
8. Per-rule `RuleAuditAction.CREATE` (outcome `unknown`) is logged for every survivor.
9. **Phase B4 (`runBatch.bulkCreateRulesSo`)** — single SO bulk write with no overwrite. Whole-call throw → invalidate all collected keys, best-effort `taskManager.bulkRemove(newlyScheduledTaskIds)`, push a single batch-wide SO failure error with `rule: { id: 'n/a', name: 'n/a' }`, return with `soFailureOccurred: true`.
10. Per-row outcomes: per-row SO error → push error, queue this rule's key for invalidation **only if** it was a Phase-B3-newly-scheduled id (skips caller-supplied id 409s to avoid nuking pre-existing rules' tasks). Per-row success → log `RuleAuditAction.ENABLE` (outcome `unknown`) if the rule was in `newlyScheduledTaskIds`.
11. Single batched `taskManager.bulkRemove` for accumulated cleanup ids; single `bulkMarkApiKeysForInvalidation` for accumulated keys; `logRuleChanges` for the persisted SOs only.
12. Back in the orchestrator: if `exitEarlyOnError && result.soFailureOccurred`, log a warn and break out of the batch loop. Otherwise continue to the next batch. Return `{ successfulIds, errors, total }`.

## Assumptions

- **TM PR #269991 lands together (or is already in main).** The new `bulkSchedule` payload omits `runAt`/`scheduledAt`. Without the new jitter behavior, every batch's first scheduled task would fire immediately, which is exactly the regression the per-batch jitter is meant to avoid. The two changes are coupled but presented as separable PRs in the description.
- **`taskManager.bulkSchedule` returns scheduled-task objects with the *same id* the caller supplied.** Phase B3's silent-drop detection diffs `survivingEnabledIds` against `scheduledTasks.map(t => t.id)`. If TM ever rewrites ids on schedule (it doesn't today, but it's not part of TM's contract documentation I could find), the diff would produce false positives.
- **`apiKeyAsAlertAttributes(null, username, false)` together with `delete prepared.rawRule.scheduledTaskId; delete prepared.rawRule.lastEnabledAt;` produces a *valid* disabled `RawRule`.** The single `create()` flow only sets these fields when `data.enabled` is true and never has to *un*-set them on a previously-prepared object. Worth confirming there's no other "enabled-only" attribute that survives the demotion (`monitoring`, `executionStatus`, `revision: 0` etc. are common to both).
- **`SavedObjectsBulkCreateOptions.overwrite` defaults to false** in `bulkCreateRulesSo` (it never passes the option). This is the implicit reason caller-supplied id collisions surface as per-row 409s. If a future change to `savedObjectsBulkCreateOptions` flipped it, we'd silently overwrite existing rules and the "skip TM cleanup for caller-supplied ids" guard would no longer be enough.
- **`logRuleChanges` is a no-op when `changeTrackingService` is not configured** (returns early on the falsy check). The PR relies on this for environments where the change-tracking feature flag is off.
- **`rule.data.actions` and `rule.data.systemActions` mutation is safe.** Phase A1 calls `addGeneratedActionValues` and discards the result; Phase B1 calls it again. The function does not mutate inputs, so this is safe — see Risks for the secondary smell.
- **Best-effort cleanup is acceptable to response-ops.** PR description explicitly acknowledges TM `bulkRemove` and API-key invalidation can fail silently and leave dangling tasks/keys.

## Risks

Ordered by severity. Most of these are explicitly acknowledged in the PR description; I'm calling out the ones that aren't.

1. **(Medium / cross-team)** **`task_scheduling.ts` change is a global behavior shift, not a bulk-create-local one.** `i === 0 → arr.length === 1` flips the contract for `bulkSchedule` and `bulkEnable.runSoon`: today, every existing caller scheduling >1 task gets the first one running immediately and the rest jittered. After this PR, every existing caller scheduling >1 task gets *all* of them jittered (1ms–5min). The PR description frames this as a 10% perf win for bulk create, but the same change applies to every other caller in the codebase. Because that PR (#269991) is co-merged here, response-ops needs to specifically ratify the global semantic change, not just review it as part of this PR. Worth a separate `git grep "bulkSchedule(" -- 'x-pack/platform/plugins/shared/'` sweep to enumerate impacted call sites before merge.
2. **(Medium / silent)** **Duplicate caller-supplied ids inside the same call silently dedupe.** `inputs.map(rule => ({ id: rule.options?.id ?? generateId(), rule }))` produces N entries; `validated.set(id, ...)` in Phase A1 is a `Map` keyed by id, so two rules both passing `options: { id: 'foo' }` collapse to one entry. `total` is reported as the input length so the caller sees `total: 2, successfulIds: ['foo'], errors: []` — they cannot tell a rule was dropped. Either reject duplicate caller-supplied ids upfront with a 400, or stamp a `duplicate_id` error per loss. Test coverage gap as well — there's a `caller-supplied id` test, but only with a single rule.
3. **(Medium / observability)** **Whole-call SO failure produces a single error with `rule: { id: 'n/a', name: 'n/a' }`.** When `bulkCreateRulesSo` throws, the caller cannot tell which rules' API keys were just invalidated and which tasks were dangling at the moment of the throw. For a flow that's billed as "best-effort cleanup," the operator-facing trail is thinner than it should be. Consider including the affected ids in the message or in a structured field on the error.
4. **(Low / wasted work)** **`addGeneratedActionValues` is called twice per rule** — once in Phase A1 (`preValidate.checkInMemory`) and again in Phase B1 (`prepareRule`). Both calls hit `uiSettings.asScopedToClient(...)` and `getEsQueryConfig(...)`. `getEsQueryConfig` is an ES-backed call (UI settings) — meaning Phase A is *not* purely in-memory, contrary to the comment "no ES." Same applies to `ruleTypeRegistry.get` and `validateRuleTypeParams` being called twice. Functionally correct (uuids are only generated when missing, schema validation is idempotent), but the "Phase A is fast / Phase B is slow" framing in the description is slightly off. Worth reading PR description point 5 again ("schema validation. Then ES calls") — `getEsQueryConfig` is technically an ES call.
5. **(Low / observability)** **Phase A1 in-memory failures don't emit audit log entries.** Phase A2 (authz) does, but a rule failing schema/registry/interval validation gets only a returned error, no audit entry. Single-rule `create()` matches this — schema failures don't audit, only authz does — so it's consistent, but worth documenting since "audit completeness" is the kind of thing security review will ask about.
6. **(Low / coupled to TM internals)** **B3 silent-drop detection assumes TM `bulkSchedule` returns tasks in arbitrary order, but with stable ids matching what was requested.** The current `taskInstanceToAttributes` indeed logs+skips invalid instances and returns the rest, but this is an implementation detail that's not part of TM's contract. If TM ever changes to throw on the first invalid instance instead of skipping, the silent-drop detection becomes dead code (harmless) but the demotion path goes via B3's whole-call catch instead. Both are handled, just worth noting.
7. **(Low / contract gap with the linked issue)** **`WriteOperations.Create` is used for authorization, not `WriteOperations.BulkCreate`.** The linked issue #264893 explicitly listed "Add `WriteOperations.BulkCreate` to alerting authorization enum" as a TODO. Using `Create` is probably fine (the operation is still semantically a create), but it's a deliberate deviation from the approved plan and should be confirmed with the original requesters.
8. **(Low / partial-progress visibility)** **`logRuleChanges` runs per-batch.** If a multi-batch call partially succeeds and then `exitEarlyOnError` triggers in batch 5, batches 1–4's change history is already persisted. This is the right behavior for "the SOs in those batches really exist," but the *call site* that triggered the bulk operation may want a single change-tracking entry. Worth confirming with detection-rule-management whether per-batch granularity is OK.
9. **(Low / sequential)** **Phase A2 (`ensureAuthorized` per pair) is sequential.** Trivial for prebuilt-rules workloads (one consumer, one type), but if anyone bulk-creates across many `(type, consumer)` pairs, this serialization is a perf cliff. Not worth fixing now, but worth a TODO comment.

## Open questions

These are real questions I'd want answered, not formalities.

1. **Why is the `task_scheduling.ts` change rolled into this PR rather than landing #269991 first?** The PR description points at #269991 as a separate PR but the diff includes the same change. If that's intentional (because this PR can't ship without it), the global behavior change becomes part of the bulk-create review surface and should be called out more prominently than as a footnote. If #269991 is meant to land first, this PR's diff should drop those files.
2. **For duplicate caller-supplied ids in the same call, what should the contract be?** Reject upfront (400)? Process the first, error the rest? Currently it silently dedupes, which is the most surprising option.
3. **Is `WriteOperations.Create` (vs. a new `WriteOperations.BulkCreate`) the right authorization op for bulk?** Asking because the linked issue listed adding `BulkCreate` as a TODO. Was that consciously dropped during the response-ops review rounds, and if so, what's the rationale to record alongside the merge?
4. **What does response-ops' definition of "best-effort cleanup" actually mean operationally?** If `bulkRemove` fails, we leave dangling tasks that will run forever (TM scheduler will pick them up). If API-key invalidation fails, those keys are never marked for invalidation. Is there a downstream sweeper that catches orphans, or is this just accepted ops debt that the SIEM team should monitor for in dashboards?
5. **Phase B3 silent-drop demotion gives the user a `disabledReason: 'task_validation_failed'` error message of `"Task scheduling silently dropped this rule (validation failure in task store)"`.** This is end-user-visible. Is response-ops happy for that text to be exposed? It hints at TM internals.
6. **Why does the integration test pyramid stop at unit tests?** The PR description says "Deliberately 'light' on testing to make sure further feedback can be incorporated easily." Fair, but the linked issue #264893 listed integration tests against real SOs as a checkbox item. Is the plan to add those when the security-solution wiring (PR #271722) lands, or is this something to track separately?
7. **What's the upgrade story for `MAX_BULK_CREATE_BATCH_SIZE = 500` and `DEFAULT = 100`?** They're hard-coded constants in `rules_client/common/constants.ts`. If we discover during prod rollout that 100 is too high (memory) or too low (latency), is the plan a code change + deploy, or should these be configurable via `xpack.alerting.*` settings?

## Notes for your codebase map

A few patterns this PR makes clearer about the alerting framework that aren't obvious from a casual read:

- **`RulesClient` methods follow the pattern: bind in `rules_client.ts` to a free function in `application/rule/methods/<verb>/<verb>_rule.ts`.** The free function takes `(context: RulesClientContext, params)` so it's testable without the class. Bulk methods conventionally export their public types from an `index.ts` that's re-exported from `server/index.ts`.
- **Demotion-on-failure (rather than reject-on-failure) is a new contract pattern.** Existing flows (`createRule`, `bulkEnableRules`) reject the rule entirely if API key mint or scheduling fails. This PR introduces "create as disabled" semantics with a machine-readable `disabledReason` enum. If this pattern proves successful, it likely deserves reuse in the existing single-create path too.
- **`addGeneratedActionValues` is implicitly an ES-touching call** (because of `getEsQueryConfig` which reads UI settings via the SO client). The "no ES in Phase A" claim in this PR's design relies on the fact that UI settings are heavily cached by the platform.
- **`taskManager.bulkSchedule` silently drops invalid task instances** rather than throwing. The check happens in TM's `taskInstanceToAttributes`. Any bulk consumer of TM that wants to know about silently-dropped tasks has to do the requested-vs-returned diff manually, like this PR does.
- **`MAX_RULES_NUMBER_FOR_BULK_OPERATION = 10000` is shared** across bulk-edit/bulk-enable/bulk-delete and now bulk-create. It's enforced in the rules client, not at the route level — callers must enforce request-level caps before invoking, as this PR's docstring explicitly notes.
- **Change tracking is gated by `xpack.alerting.ruleChangeTracking.enabled` + a per-rule-type `trackChanges` flag.** `logRuleChanges` is a no-op when either is missing, which is what makes it safe to call unconditionally from new code paths like this one.
- **`bulkCreateRulesSo` is a single-line passthrough** to `savedObjectsClient.bulkCreate` with no batching of its own. All batching has to happen in the calling code, which is why this PR's `runBatch` exists.
