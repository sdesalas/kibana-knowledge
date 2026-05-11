# `bulkCreateRules` flow

ASCII diagram of the current flow in
`x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts`.

The function follows a **"persist first, schedule later"** model. Phases 1–5
run in the foreground (awaited by the caller). Phases A–D run detached and
are exposed via `result.backgroundWork`.

## High-level shape

```
                         bulkCreateRules(context, params)
                                       │
                                       ▼
                            ┌──────────────────────┐
                            │ rules.length === 0 ? │──── yes ──▶ return empty result
                            └──────────────────────┘            (backgroundWork = Promise.resolve([]))
                                       │ no
                                       ▼
                            getUserName + getActionsClient
                            generate ids for inputs
                                       │
                                       ▼
              ╔════════════════════════════════════════════════╗
              ║              FOREGROUND (awaited)              ║
              ╚════════════════════════════════════════════════╝
                                       │
                                       ▼
                           ┌─────────────────────┐
                           │ Phase 1: prepareRule│  pMap, concurrency = API_KEY_GENERATE_CONCURRENCY
                           │ (per input rule)    │
                           └──────────┬──────────┘
                                      │
                                      ▼
                          ┌──────────────────────┐
                          │ preparedRules empty? │── yes ──▶ flush minted keys
                          └──────────┬───────────┘            return { rules: [], errors, ... }
                                     │ no
                                     ▼
                          emit per-rule CREATE audit
                                     │
                                     ▼
                       ┌─────────────────────────────┐
                       │ Phase 2: bulkCreateRulesSo  │
                       │ (no overwrite)              │
                       └──────────┬──────────────────┘
                                  │
                ┌─────────────────┴──────────────────┐
                │ throws (whole-call SO failure)     │ resolves
                ▼                                    ▼
   queue ALL minted keys                  ┌────────────────────────┐
   flushKeysToInvalidate                  │ Phase 3: per-row split │
   rethrow (caller sees error,            └──────────┬─────────────┘
   no backgroundWork promise)                        │
                                  ┌──────────────────┴─────────────────┐
                                  │ so.error                           │ ok
                                  ▼                                    ▼
                       push errors[]                          successfulSos.push(so)
                       queue minted key for that id           if so.attributes.enabled:
                       (drop from apiKeysMap)                   emit ENABLE audit
                                  │                                    │
                                  └──────────────────┬─────────────────┘
                                                     ▼
                              compute enabledPersistedIds = successfulSos
                                                       .filter(enabled).map(id)
                                                     │
                                                     ▼
                          ┌──────────────────────────────────────────┐
                          │ Phase 4: build detached backgroundWork   │
                          │ promise (NOT awaited here)               │
                          └──────────────────────────┬───────────────┘
                                                     │
                                                     ▼
                          ┌──────────────────────────────────────────┐
                          │ Phase 5: domain transform via            │
                          │ toSanitizedRule for each successful SO   │
                          └──────────────────────────┬───────────────┘
                                                     ▼
                          return { rules, errors, total,
                                   taskIdsFailedToBeEnabled: [],
                                   backgroundWork }     ◀── caller resumes
```

## Phase 1 — `prepareRule` (per rule, concurrent)

```
prepareRule(input)
   │
   ▼
addGeneratedActionValues(actions, systemActions)
   │
   ▼
createRuleDataSchema.validate(data) ───────── invalid ──▶ throw Boom.badRequest
   │ valid
   ▼
ruleTypeRegistry.get(alertTypeId)            ──── not registered ──▶ throws 400
   │
   ▼
authzCache(`${alertTypeId}::${consumer}`)
   │   ├── miss ─▶ ensureAuthorized(...) and cache promise
   │   └── hit  ─▶ await cached promise
   │
   ├── authz throws ─▶ emit CREATE audit (error) ─▶ rethrow
   │
   ▼
ruleTypeRegistry.ensureRuleTypeEnabled
validateRuleTypeParams
validateActions
validateAndAuthorizeSystemActions
   │
   ▼
parseDuration(schedule.interval)
   │  interval < min && enforce ─▶ throw Boom.badRequest
   │  interval < min && !enforce ─▶ logger.warn
   ▼
data.enabled ?
   ├── yes ─▶ try createNewAPIKeySet
   │           ├── ok   ─▶ apiKeysMap.set(id, keys)
   │           └── fail ─▶ effectiveEnabled = false
   │                       errors.push({ disabledReason: 'api_key_creation_failed' })
   └── no  ─▶ apiKeyAsRuleDomainProperties(null, ...)  (no key minted)
   │
   ▼
extractReferences(actions ++ systemActions, params, artifacts)
   │
   ▼
transformRuleDomainToRuleAttributes (+ stamp lastEnabledAt / scheduledTaskId
                                     when effectiveEnabled)
   │
   ▼
return { prepared: { id, name, enabled, rawRule, references,
                     schedule, consumer, ruleTypeId } }

   On any caught error inside prepareRule:
   return { error: { message, status, rule: { id, name } } }
   (caller pushes into the foreground errors[])
```

## Phases A–D — `backgroundWork` promise (detached)

```
backgroundWork  (try/catch wraps the whole IIFE — the promise NEVER rejects)
   │
   ▼
┌──────────────────────────────────────────────────────────────┐
│ Phase A — schedule-limit check                               │
│   if enabledPersistedIds.length > 0:                         │
│     validationPayload = validateScheduleLimit(intervals)     │
│     if validationPayload:                                    │
│       reasonMessage = getRuleCircuitBreakerErrorMessage(...) │
│       demotedIds.set(id, {                                   │
│         reason: 'schedule_limit_exceeded',                   │
│         message: reasonMessage })                            │
└────────────────────────────┬─────────────────────────────────┘
                             │
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ Phase B — taskManager.bulkSchedule                           │
│   idsToSchedule = enabledPersistedIds \ demotedIds           │
│                                                              │
│   try bulkSchedule(tasks)                                    │
│     │  resolves                                              │
│     │     scheduledIds.length < idsToSchedule.length ?       │
│     │        yes ─▶ silent drops:                            │
│     │              demotedIds.set(droppedId, {               │
│     │                reason: 'task_schedule_entry_failed',   │
│     │                message: 'silently dropped...' })       │
│     │        no  ─▶ all good                                 │
│     │                                                        │
│     └  throws (whole-call):                                  │
│           for each id in idsToSchedule:                      │
│             demotedIds.set(id, {                             │
│               reason: 'task_schedule_failed',                │
│               message: `Failed to schedule tasks: ${msg}` }) │
└────────────────────────────┬─────────────────────────────────┘
                             │
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ Phase C — demotePersistedRules(demotedIds)                   │
│   for each [id, { reason, message }] in demotedIds:          │
│     queue minted apiKey for invalidation                     │
│     build cleared attrs (enabled=false, scheduledTaskId=null,│
│                         lastEnabledAt=null, null apiKey)     │
│     push bgError { message, rule, disabledReason: reason }   │
│     emit DISABLE audit                                       │
│                                                              │
│   try bulkUpdateRuleSo(rulesToUpdate)                        │
│     │  ok    ─▶ done                                         │
│     └  throws ─▶ logger.error                                │
│                  push extra plain bgError per rule           │
│                  ('Failed to persist demotion: ...')         │
└────────────────────────────┬─────────────────────────────────┘
                             │
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ Phase D — flushKeysToInvalidate(keysToInvalidate)            │
│   try bulkMarkApiKeysForInvalidation(...)                    │
│     │  ok    ─▶ keysToInvalidate.clear()                     │
│     └  throws ─▶ logger.error                                │
│                  push batch-level bgError                    │
│                  { message: 'Failed to invalidate API keys...│
│                    rule: { id: 'n/a', name: 'n/a' } }        │
└────────────────────────────┬─────────────────────────────────┘
                             │
                             ▼
                    return bgErrors[]
                             │
   (outer catch — anything not handled above, e.g. Phase A throw)
        │
        ▼
   logger.error
   bgErrors.push({ message: `Background phases failed: ...`,
                   rule: { id: 'n/a', name: 'n/a' } })
   return bgErrors[]
```

## API key lifecycle

```
prepareRule (Phase 1)
   data.enabled && createNewAPIKeySet ok
     └─▶ apiKeysMap.set(id, { apiKey, uiamApiKey, apiKeyCreatedByUser })

Phase 2 throws (whole-call SO failure)
     └─▶ collectNewKeysToInvalidate(apiKeysMap.values())
         flushKeysToInvalidate
         rethrow

Phase 3 per-row failure
     └─▶ collectNewKeysToInvalidate([apiKeysMap.get(id)])
         apiKeysMap.delete(id)
         (flushed later in Phase D)

Phase C demotion
     └─▶ collectNewKeysToInvalidate([apiKeysMap.get(id)])
         apiKeysMap.delete(id)

Phase D
     └─▶ flushKeysToInvalidate(keysToInvalidate)
```

## Error / audit summary

| Phase | Foreground `errors[]`                          | `backgroundWork` errors                         | Audit events emitted                  |
|-------|------------------------------------------------|-------------------------------------------------|---------------------------------------|
| 1     | per-rule prepare failures (incl. `api_key_creation_failed`) | —                                       | CREATE (error) on authz failure       |
| 2     | rethrows on whole-call SO failure              | —                                               | —                                     |
| 3     | per-row SO error                               | —                                               | CREATE (unknown) per prepared, ENABLE per persisted+enabled |
| A     | —                                              | (queued via Phase C as `schedule_limit_exceeded`) | —                                   |
| B     | —                                              | (queued via Phase C as `task_schedule_entry_failed` / `task_schedule_failed`) | — |
| C     | —                                              | one per demoted rule + extra per rule on bulkUpdate throw | DISABLE per demoted rule    |
| D     | —                                              | one batch-level error on flush failure          | —                                     |

> The returned `rules[]` reflects **input intent** at the moment of return.
> If the background promise later demotes a rule, a follow-up
> `rulesClient.get` is required to observe the post-background state.
