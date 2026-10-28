# `bulkCreateRules` flow

Source: `bulk_create_rules.ts` (orchestration) + `utils.ts` (`prepareRule`, `demotePersistedRules`, `flushKeysToInvalidate`, `buildTaskInstance`, `toSanitizedRule`, …).

## Summary

```
   ┌─────────────────────── FOREGROUND (awaited) ───────────────────────┐
   │  prepare ─▶ mint API keys ─▶ SO bulkCreate ─▶ split rows ─▶ return │
   │  (validate, (for enabled rules;  (no overwrite)  (per-row 409s)    │
   │   authz)     soft-fail ⇒ disabled)                                 │
   │                                                                    │
   │   returns { rules, errors, total, backgroundWork }                 │
   └────────────────────────────────────┬───────────────────────────────┘
                                        │ (kicked off, not awaited)
                                        ▼
   ┌──────────────────── BACKGROUND (result.backgroundWork) ────────────┐
   │  schedule-limit ─▶ bulkSchedule ─▶ demote failed ─▶ flush API keys │
   │  check             tasks           rules (SO →     to invalidate   │
   │                                    disabled,                       │
   │                                    DISABLE audit)                  │
   │                                                                    │
   │  resolves to bgErrors[] (one per demoted rule); never rejects.     │
   └────────────────────────────────────────────────────────────────────┘

   Persist first, schedule later: rules[] reflects input intent;
   the background promise may later flip some to disabled.
```

## Detail

```
                       bulkCreateRules(context, params)
                                   │
                                   ▼
                          rules.length === 0 ? ── yes ──▶ return empty result
                                   │ no                   (backgroundWork = Promise.resolve([]))
                                   ▼
                       getUserName + getActionsClient
                       generate id per input (options.id ?? uuid)
                                   │
        ╔══════════════════════ FOREGROUND (awaited) ══════════════════════╗

         Phase 0: prefetchActions  (single actionsClient.getBulk for the
                                    union of action + system-action ids
                                    across the entire batch)
           ▸ unionIds = ⋃ rule.data.{actions,systemActions}.id
           ▸ unionIds empty? ─▶ skip; pass actionsById = undefined
           ▸ throws         ─▶ log debug, fall back to per-rule getBulk
                               (validateActions + extractReferences) so
                               that one missing connector id does not
                               sink the whole batch
           ▸ actionsById = Map<id, ActionResult|InMemoryConnector>

         Phase 1: prepareRule per input  (pMap, API_KEY_GENERATE_CONCURRENCY)
           ▸ addGeneratedActionValues + createRuleDataSchema.validate
           ▸ ruleTypeRegistry.get / ensureRuleTypeEnabled
           ▸ ensureAuthorized via authzCache (key = `${ruleTypeId}::${consumer}`)
                 └─ on throw: emit CREATE audit (error), reject this input
           ▸ validateRuleTypeParams + validateActions + system-action authz
                 (slice from actionsById to skip per-rule getBulk fetches)
           ▸ schedule.interval vs minimumScheduleInterval (enforce → 400, else warn)
           ▸ if data.enabled: createNewAPIKeySet
                 ├─ ok   → apiKeysMap.set(id, …)
                 └─ fail → effectiveEnabled = false
                           push errors[] { disabledReason: 'api_key_creation_failed' }
           ▸ extractReferences → transformRuleDomainToRuleAttributes
           returns { prepared } | { error }   (any caught throw becomes per-rule error)
                                   │
                                   ▼
                       preparedRules empty? ── yes ──▶ flushKeys, return early
                                   │ no
                                   ▼
                   emit per-rule CREATE audit (outcome: unknown)
                                   │
                                   ▼
         Phase 2: bulkCreateRulesSo (no overwrite)
                  │                                  │
              throws                              resolves
                  │                                  │
        queue ALL minted keys                       ▼
        flushKeysToInvalidate         Phase 3: per-row outcome split
        rethrow synchronously         ├─ so.error  ─▶ errors[], queue this id's key
        (no backgroundWork)           │              (apiKeysMap.delete(id))
                                      └─ ok        ─▶ successfulSos.push(so)
                                                       if so.attributes.enabled:
                                                         emit ENABLE audit (outcome: unknown)
                                                  │
                                                  ▼
                         enabledPersistedIds = successfulSos.filter(enabled).map(id)
                                                  │
        ╠══════════════ kick off backgroundWork (NOT awaited) ══════════════╣

         Phase 4A. validateScheduleLimit(intervals of enabledPersistedIds)
                   exceeded ─▶ demotedIds.set(id, 'schedule_limit_exceeded') ∀ enabled

         Phase 4B. taskManager.bulkSchedule(idsToSchedule = enabled \ demotedIds)
                   ├─ resolves: silent drops = idsToSchedule \ scheduledTasks.map(id)
                   │              ─▶ demotedIds.set(dropped, 'task_schedule_entry_failed')
                   └─ throws  : ─▶ demotedIds.set(idsToSchedule, 'task_schedule_failed')
                                   (bulkScheduleThrew flag prevents reclassification)

         Phase 4C. demotePersistedRules(demotedIds)
                   ▸ queue minted keys for those ids → keysToInvalidate
                   ▸ bulkUpdateRuleSo: enabled=false, scheduledTaskId=null,
                                       lastEnabledAt=null, apiKey cleared
                   ▸ emit DISABLE audit per id, push bgErrors[] with disabledReason
                   ▸ bulkUpdate throw is logged only (no extra errors)

         Phase 4D. flushKeysToInvalidate(keysToInvalidate)
                   ▸ bulkMarkApiKeysForInvalidation, clears the Set

         (entire IIFE wrapped in try/catch — promise NEVER rejects;
          unexpected throws from A–D are logged and bgErrors[] is returned as-is)

        ╠═════════════════════════ back in foreground ═════════════════════╣

         Phase 5: toSanitizedRule per successfulSo  (domain transform + schema check)
                                   │
                                   ▼
              return { rules,           // reflects INPUT intent (pre-demotion)
                       errors,          // foreground errors only
                       total,
                       backgroundWork } // resolves to bgErrors[] (demotions)
        ╚══════════════════════════════════════════════════════════════════╝
```

**Notes**

- *Persist first, schedule later.* SOs are written before tasks are scheduled, so a failed schedule demotes (disables) an existing SO rather than orphaning a task.
- The synchronous `rules[]` reflects caller intent. If `backgroundWork` later demotes a rule, callers needing the post-background state should `await result.backgroundWork` and then `rulesClient.get(id)`.
- The Phase 2 throw is the only path that rejects the outer promise. Everything else surfaces in foreground `errors[]` (prepare / per-row SO errors) or in the resolved `backgroundWork` array (demotions).
- `bgErrors[]` only carries one structured entry per demoted rule (with `disabledReason`); the bulkUpdate failure inside Phase 4C and any catch-all from the IIFE wrapper are log-only.
