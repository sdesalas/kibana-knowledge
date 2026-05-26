# `bulkCreateRules` — Current Flow

ASCII diagram of the flow in [`bulk_create_rules.ts`](./bulk_create_rules.ts).

## Summary

```
  input: rules[]      (early-return on length 0)
        │
        ▼
  ┌────────────────────────────────────────────────────────────────────────────────────────────┐
  │ ──  getUserName + getActionsClient + assign ids (caller-supplied or SavedObjectsUtils)     │
  │ P0  prefetchActions             1 batched connector lookup; soft-fail → per-rule fetches   │
  │ P1  prepareRule                 (pMap, conc=API_KEY_GENERATE_CONCURRENCY)                  │
  │                                 validate + generate API key + build rawRule + authz cache  │
  │     ↳ if no survivors:          flushKeysToInvalidate, return early                        │
  │ P2  validateScheduleLimit       enabled subset only; on breach → demote whole subset       │
  │ P3  taskManager.bulkSchedule    on throw → demote enabled; silent TM drops → demote them   │
  │ ──  audit CREATE                per prepared rule, pre-persistence (outcome='unknown')     │
  │ P4  bulkCreateRulesSo           no overwrite, id collisions surface as per-row 409         │
  │ ──  whole-call throw         →  invalidate keys + bulkRemove tasks + rethrow               │
  │ ──  per-row err              →  errors[] + queue key inv + (only newly-scheduled) cleanup  │
  │ ──  per-row ok               →  audit ENABLE for enabled subset                            │
  │ P5  tryToEnableTasks            taskIdsToEnable → taskIdsFailedToBeEnabled                 │
  │ ──  flushKeysToInvalidate       single end-of-function flush for all collected keys        │
  │ P6  toSanitizedRule             domain transform of successful SOs                         │
  └────────────────────────────────────────────────────────────────────────────────────────────┘
        │
        ▼
  output: { rules: SanitizedRule[], errors: BulkOperationError[], total, taskIdsFailedToBeEnabled }

  shared state, mutated across phases:
    preparedRules (Map)        P1 populated · P2/P3 demoted · P4 consumed
    apiKeysMap (Map)           P1 populated · drained on demotions and per-row SO errors
    keysToInvalidate (Set)     appended throughout · flushed once at end (and on early/throw paths)
    errors (Array)              appended in P1, P2, P3, P4 per-row
    authzCache (Map)           memoises authz checks within P1
    newlyScheduledTaskIds (Set) P3 output · gates P4 cleanup decisions on caller-supplied id collisions

  demotion paths (enabled → disabled, error recorded, still persisted in P4 as disabled):
    P2 schedule_limit_exceeded   · P3 task_schedule_failed   · P3 task_validation_failed
    (all flip enabled=false in preparedRules, queue the freshly-minted API key for invalidation,
     and push a BulkOperationError; the rule still goes through Phase 4 SO creation as disabled.)

  partial-success contract:
    never throws on per-rule failures; only Phase 4 whole-call SO error rethrows
    (after invalidating new keys and best-effort task cleanup). Phase 0 throws are swallowed.
```

## High-level pipeline

```
                       ┌──────────────────────────────────────┐
                       │   bulkCreateRules(context, params)   │
                       └──────────────────┬───────────────────┘
                                          │
                                          ▼
                              ┌───────────────────────┐
                              │ rules.length === 0 ?  │──── yes ──▶ return empty result
                              └───────────┬───────────┘
                                          │ no
                                          ▼
                       ┌──────────────────────────────────────┐
                       │ getUserName() + getActionsClient()   │
                       │ assign id (caller-supplied or new)   │
                       └──────────────────┬───────────────────┘
                                          │
                                          ▼
            ┌─────────────────────────────────────────────────────────────┐
            │ Phase 0 — prefetchActions()                                 │
            │  • single connector lookup for the whole batch              │
            │  • soft-fail: on throw, fall back to per-rule fetches       │
            │  • output: actionsById?: Map<id, ActionResult|InMemory>     │
            └─────────────────────────────┬───────────────────────────────┘
                                          │
                                          ▼
            ┌─────────────────────────────────────────────────────────────┐
            │ Phase 1 — pMap(prepareRule, concurrency=API_KEY_GENERATE)   │
            │  per rule:                                                  │
            │   • validate                                                │
            │   • generate API key                                        │
            │   • build rawRule + references                              │
            │   • cache authz checks (authzCache)                         │
            │  outputs (mutated across phases):                           │
            │   ├─ preparedRules : Map<id, PreparedRule>                  │
            │   ├─ apiKeysMap    : Map<id, ApiKeyEntry>                   │
            │   ├─ keysToInvalidate : Set<string>                         │
            │   └─ errors[]       (per-rule prepare failures)             │
            └─────────────────────────────┬───────────────────────────────┘
                                          │
                                          ▼
                              ┌───────────────────────┐
                              │ preparedRules empty ? │──── yes ──┐
                              └───────────┬───────────┘            │
                                          │ no                    ▼
                                          │            flushKeysToInvalidate
                                          │            return { rules:[], errors,
                                          │                     total, taskIdsFailedToBeEnabled:[] }
                                          ▼
            ┌─────────────────────────────────────────────────────────────┐
            │ Phase 2 — schedule-limit validation (enabled subset only)   │
            │  validateScheduleLimit({ updatedInterval })                 │
            │  if circuit breaker hit:                                    │
            │   → demotePreparedRules(reason='schedule_limit_exceeded')   │
            │     (flips enabled→false, queues key invalidation, errors+) │
            └─────────────────────────────┬───────────────────────────────┘
                                          │
                                          ▼
            ┌─────────────────────────────────────────────────────────────┐
            │ Phase 3 — taskManager.bulkSchedule (surviving enabled)      │
            │                                                             │
            │  ┌─ try bulkSchedule(tasksToSchedule) ─────────────────┐    │
            │  │   success → scheduledIds = task.ids                 │    │
            │  │   throw   → demote ALL enabled                      │    │
            │  │            (reason='task_schedule_failed')          │    │
            │  └─────────────────────────────────────────────────────┘    │
            │                                                             │
            │  diff requested vs returned (silent drops by TM validator): │
            │   dropped = surviving \ scheduledIds                        │
            │   if dropped → demotePreparedRules(                         │
            │       reason='task_validation_failed')                      │
            │                                                             │
            │  newlyScheduledTaskIds : Set<string>                        │
            └─────────────────────────────┬───────────────────────────────┘
                                          │
                                          ▼
            ┌─────────────────────────────────────────────────────────────┐
            │ Audit log: RuleAuditAction.CREATE (outcome='unknown')       │
            │  for every prepared rule (pre-persistence, mirrors          │
            │  createRuleSavedObject)                                     │
            └─────────────────────────────┬───────────────────────────────┘
                                          │
                                          ▼
            ┌─────────────────────────────────────────────────────────────┐
            │ Phase 4 — bulkCreateRulesSo (no overwrite)                  │
            │                                                             │
            │  ┌─ try ────────────────────────────────────────────────┐   │
            │  │ bulkResponse = bulkCreateRulesSo({ ... })            │   │
            │  └──────────────────────────────────────────────────────┘   │
            │                                                             │
            │  ┌─ catch (whole-call failure) ─────────────────────────┐   │
            │  │  • invalidate every newly-minted key                 │   │
            │  │  • flushKeysToInvalidate                             │   │
            │  │  • bulkRemove(newlyScheduledTaskIds) (best-effort)   │   │
            │  │  • rethrow                                           │   │
            │  └──────────────────────────────────────────────────────┘   │
            └─────────────────────────────┬───────────────────────────────┘
                                          │
                                          ▼
            ┌─────────────────────────────────────────────────────────────┐
            │ Phase 4 per-row outcomes (loop bulkResponse.saved_objects)  │
            │                                                             │
            │  so.error (e.g. 409)                so OK                   │
            │  ───────────────────                ─────                   │
            │  errors.push(...)                   successfulSos.push(so)  │
            │  queue apiKey invalidation          if newlyScheduled[id]:  │
            │  if newlyScheduled[id]:               taskIdsToEnable.push  │
            │    taskIdsToCleanUp.push              audit ENABLE          │
            │  (skip caller-supplied id                                   │
            │   collisions to avoid nuking                                │
            │   pre-existing rule's task)                                 │
            └─────────────────────────────┬───────────────────────────────┘
                                          │
                                          ▼
            ┌─────────────────────────────────────────────────────────────┐
            │ Cleanup orphan tasks for SO per-row failures                │
            │  taskManager.bulkRemove(taskIdsToCleanUp)  (best-effort)    │
            └─────────────────────────────┬───────────────────────────────┘
                                          │
                                          ▼
            ┌─────────────────────────────────────────────────────────────┐
            │ Phase 5 — tryToEnableTasks(taskIdsToEnable)                 │
            │  → taskIdsFailedToBeEnabled                                 │
            └─────────────────────────────┬───────────────────────────────┘
                                          │
                                          ▼
            ┌─────────────────────────────────────────────────────────────┐
            │ flushKeysToInvalidate(keysToInvalidate)                     │
            │  single end-of-function flush for ALL collected keys        │
            └─────────────────────────────┬───────────────────────────────┘
                                          │
                                          ▼
            ┌─────────────────────────────────────────────────────────────┐
            │ Phase 6 — domain transform                                  │
            │  successfulSos.map(toSanitizedRule)                         │
            └─────────────────────────────┬───────────────────────────────┘
                                          │
                                          ▼
                       ┌──────────────────────────────────────┐
                       │ return { rules, errors, total,       │
                       │          taskIdsFailedToBeEnabled }  │
                       └──────────────────────────────────────┘
```

## Mutable accumulators (threaded through phases)

```
preparedRules     Map<id, PreparedRule>     populated in P1, demoted in P2/P3,
                                            consumed in P4
apiKeysMap        Map<id, ApiKeyEntry>      populated in P1, drained on demotions
                                            and per-row SO errors
keysToInvalidate  Set<string>               appended throughout, flushed once at end
                                            (also flushed early on no-survivors and
                                            on Phase 4 whole-call throw)
errors            BulkOperationError[]      appended in P1, P2, P3, P4 per-row
authzCache        Map<key, Promise<void>>   memoises authz checks within P1
newlyScheduledTaskIds  Set<string>          Phase 3 output; gates P4 cleanup decisions
```

## Demotion paths (enabled → disabled, error recorded)

```
Phase 2  schedule_limit_exceeded     entire enabled subset (circuit breaker)
Phase 3  task_schedule_failed        whole bulkSchedule call threw
Phase 3  task_validation_failed      silently dropped by task store validator
```

In all three cases `demotePreparedRules` flips the rule to disabled in
`preparedRules`, queues the freshly-minted API key for invalidation, and pushes
a `BulkOperationError` — the rule still goes through Phase 4 SO creation as a
disabled rule.

## Failure-handling summary

```
where               kind                     side-effects
─────────────────   ──────────────────────   ──────────────────────────────────────
Phase 0             prefetch throws          swallowed; per-rule fallback in P1
Phase 1             per-rule prepare error   errors[]; rule excluded from rest
Phase 2             schedule limit hit       enabled subset demoted to disabled
Phase 3             bulkSchedule throws      enabled subset demoted to disabled
Phase 3             silent TM drops          dropped subset demoted to disabled
Phase 4             bulkCreate throws        flush keys + bulkRemove tasks; rethrow
Phase 4             per-row SO error         errors[]; queue key invalidation;
                                             bulkRemove only ids we scheduled
Phase 5             enable failures          surfaced via taskIdsFailedToBeEnabled
```
```