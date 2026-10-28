---
name: PR 269340 review feedback
overview: "Address the 9 remaining review comments from @cnasikas on PR #269340, plus 7 minor code suggestions. Changes are scoped to bulk_create_rules.ts, utils.ts, schedule_task.ts, and the test file."
todos:
  - id: batch-size-validation
    content: "Items 4+5: Throw on invalid batchSize (> MAX or < MIN_BULK_CREATE_BATCH_SIZE) instead of clamping. Update tests."
    status: completed
  - id: throw-on-validation-errors
    content: "Item 7: SKIPPED -- keeping best-effort for per-rule validation. Will discuss with reviewer."
    status: cancelled
  - id: validate-schedule-limit-a3
    content: "Item 6: Move validateScheduleLimit to preValidate as phase A3 (single upfront check). Throw 400 on overflow. Remove B2 from runBatch. Update tests."
    status: completed
  - id: remove-enable-audit
    content: "Item 3: Remove RuleAuditAction.ENABLE audit event after B4 SO persistence. Update test."
    status: completed
  - id: api-keys-map-delete
    content: "Item 1: Add apiKeysMap.delete(id) in prepareRule catch. Add unit test for key cleanup on prepare failure."
    status: completed
  - id: extract-cleanup-util
    content: "Item 8: Extract repeated cleanup pattern into a utility function."
    status: completed
  - id: bulk-schedule-task
    content: "Item 2: Move buildTaskInstance to schedule_task.ts, create bulkScheduleTask, share util with scheduleTask."
    status: completed
  - id: dedup-add-generated-actions
    content: "Hidden nit: Remove duplicate addGeneratedActionValues call in prepareRule, pass enriched data from A1."
    status: cancelled
  - id: logger-formatting
    content: "Hidden nits: Apply 5 logger message formatting suggestions + utils.ts comma fix."
    status: completed
  - id: add-test-scenarios
    content: "Item 9: Add 4 test scenarios (validateActions failure, uiamApiKey smoke, TM cleanup failure, bulkMarkApiKeysForInvalidation failure)."
    status: completed
isProject: false
---

# Address PR #269340 Review Feedback

## Files involved

- [bulk_create_rules.ts](x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts) -- main logic
- [utils.ts](x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/utils.ts) -- helpers
- [schedule_task.ts](x-pack/platform/plugins/shared/alerting/server/rules_client/lib/schedule_task.ts) -- task scheduling
- [bulk_create_rules.test.ts](x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.test.ts) -- tests

## 9 remaining review items

### ~~1. `apiKeysMap.delete(id)` in catch of `prepareRule` (utils.ts)~~ DONE

> Let's do `apiKeysMap.delete(id)` in the `catch` in case the API key was created, but any of the other functions fail. Let's be sure that these keys are invalidated/flushed correctly and add a unit test for this.

If an API key is created but a later step in `prepareRule` throws, the key stays in `apiKeysMap` and won't get cleaned up. Add `apiKeysMap.delete(id)` in the catch block at line 184 of `utils.ts`. Add a unit test proving the key is invalidated when prepare fails after key creation.

### ~~2. Move `buildTaskInstance` to `schedule_task.ts`, create `bulkScheduleTask`~~ DONE

> nit: Could you plz create a `bulkScheduleTask` in `x-pack/platform/plugins/shared/alerting/server/rules_client/lib/schedule_task.ts` and follow the same pattern as `scheduleTask`? Also, the two can call a small util (in the same file) called `buildTaskInstance`. This way we can also remove our own `buildTaskInstance` in `utils.ts`.

Move `buildTaskInstance` from `utils.ts` to [schedule_task.ts](x-pack/platform/plugins/shared/alerting/server/rules_client/lib/schedule_task.ts). Make both `scheduleTask` and the new `bulkScheduleTask` share it. Update `bulk_create_rules.ts` to call `bulkScheduleTask` instead of building tasks inline. Remove `buildTaskInstance` from utils.ts.

### ~~3. Remove ENABLE audit log~~ DONE

> I think we should remove the audit log here. We audited before the `CREATE` action.

Remove the `RuleAuditAction.ENABLE` audit event emitted after B4 SO persistence (lines 460-473 of `bulk_create_rules.ts`). The `CREATE` audit event is sufficient. Update the existing test that checks for ENABLE audit events.

### ~~4. Throw on `batchSize > MAX_BULK_CREATE_BATCH_SIZE`~~ DONE

> Let's throw an error if `batchSize > MAX_BULK_CREATE_BATCH_SIZE` instead of clamping.

Instead of clamping to the max, throw a Boom.badRequest when `batchSize > MAX_BULK_CREATE_BATCH_SIZE`. Update the test "clamps batchSize above hard cap" to expect a throw.

### ~~5. Throw on `batchSize < MIN_BULK_CREATE_BATCH_SIZE`~~ DONE

> Let's throw if `params.batchSize < 1` (or a min that we like, like 10). Otherwise, if I set the `params.batchSize` to zero, this code will set the `batchSize` to one, which will run N batches of 1 which is the same as calling `createRule` N times.

Throw a Boom.badRequest when `batchSize < 10`. A minimum of 10 prevents accidentally running N batches of 1 (same as calling createRule N times). Add a test for this.

### ~~6. Move `validateScheduleLimit` to preValidate as phase A3~~ DONE

> Could we move this phase outside `runBatch` and into `preValidate` as phase A3? The main reason is that the `validateScheduleLimit` does an ES aggregation, so it only sees rules already persisted and visible to search. It is possible that the N-1 batch is written to ES but is not visible to the N batch, making the validation pass instead of failing if the N batch exceeds the limit.
>
> Something like:
> ```
> // Phase A3 (new), after preValidate auth:
> const allEnabledIntervals = validated
>   .filter(v => v.rule.data.enabled)
>   .map(v => v.rule.data.schedule.interval);
>
> if (allEnabledIntervals.length > 0) {
>   const overflow = await validateScheduleLimit({
>     context,
>     updatedInterval: allEnabledIntervals,
>   });
>   if (overflow) {
>     // Here we need to probably throw a 400 error because we do not know which rule was the one that made the limit be exceeded.
>   }
> }
> ```

Move the schedule-limit check out of `runBatch` (B2) and into `preValidate` as a new phase A3, running once across ALL enabled rules before any ES writes. This avoids search-visibility issues between batches where batch N-1's writes aren't yet visible to batch N. On overflow, throw a 400 (since we can't identify which specific rule exceeded the limit). Remove B2 phase from `runBatch`. Update tests.

### 7. ~~Throw on ALL validation errors (ignore `exitEarlyOnError`)~~ SKIPPED

> I think for all validation errors we should throw the error, ignore the `exitEarlyOnError` and do not continue with the bulk create rules operation.

**Decision: skip for now.** Keeping best-effort per-rule validation to stay consistent with how detection rules callers work today (see `initPromisePool` in `create_prebuilt_rules.ts` and `Promise.all` + per-rule try/catch in `import_rules.ts`). Will reply to the reviewer explaining the reasoning.

### ~~8. Simplify cleanup logic in `runBatch`~~ DONE

> nit: I feel like that we do these operations a lot: collect the keys to invalidate them, bulk remove tasks, and flush the invalidated keys. Could we move the common logic to a small utility function (in the same file)?

There are three patterns repeated in `runBatch`:
- **Pattern A (exclude rules):** loop over failed rules, collect their API keys, delete from maps, push errors.
- **Pattern B (strict early exit):** collect all remaining keys, optionally bulkRemove tasks, flush, return.
- **Pattern C (whole-call SO failure):** same as B but with error reporting and its own try/catch on bulkRemove.

These share pieces but aren't identical. Four options to discuss at implementation time:

**Option 1: Extract a `cleanupAndReturn` utility (reviewer's suggestion, literal)**
Create a utility that covers the common tail: collect remaining keys, bulkRemove task IDs, flush. Call it at each early-exit point and at the end. Keeps the multi-checkpoint flow as-is, just deduplicates the cleanup tail.
- Pro: minimal structural change, directly addresses the reviewer's nit.
- Con: still 4 call sites, flow stays complex with scattered early returns.

**Option 2: Single cleanup at the end (restructure flow, no try/catch wrapper)**
Remove the `strict` early-return checkpoints from the middle of `runBatch`. Let each phase (B1, B2, B3) mutate `preparedRules` / `apiKeysMap` / `errors` as it already does. After B3, check `strict && errors.length > 0` once as a gate before B4 (SO write). All cleanup (flush keys + bulkRemove) happens once at the bottom.
- Pro: cleanup in one place, much easier to follow, no utility needed.
- Con: in strict mode, B2/B3 still run even if B1 already had errors (wasted work, but batch is small). Slightly changes the observable behavior: currently strict exits before B3 if B2 fails; with this approach B3 would still run (harmlessly, since failed rules were already removed from `preparedRules`).

**Option 3: Single cleanup at the end with try/catch wrapper**
Wrap the B1-B3 sequence in a single try/catch. Each phase throws on fatal errors (whole-call TM throw, whole-call SO throw) instead of pushing errors and continuing. The catch block does one cleanup pass. For non-fatal per-rule errors, phases still mutate maps inline. The strict gate before B4 is the same as Option 2.
- Pro: cleanest separation of "fatal = throw" vs "per-rule = mutate". Single cleanup point in the catch + one at the end.
- Con: more structural change, mixes throw-based and mutation-based error handling in the same function. Could confuse future readers about which errors throw vs which don't.

**Option 4: Hybrid -- extract `excludeRules` helper + single cleanup at the end**
Extract a small `excludeRules(ids, { apiKeysMap, keysToInvalidate, preparedRules, errors, message })` helper for Pattern A (the per-rule exclusion loop that repeats 3 times). Restructure the flow per Option 2 so cleanup happens once at the end. This addresses both the reviewer's DRY concern and the scattered-early-returns issue.
- Pro: addresses the nit directly (DRY), simplifies the flow, keeps error handling consistent (no throws).
- Con: two changes in one (new helper + restructure), slightly more review surface.

### ~~9. Add 4 test scenarios~~ DONE

> Great coverage! Thank you so much for this. Could you plz also add the following testing scenarios:
>
> - `validateActions` failure paths. One unit test should be enough.
> - `uiamApiKey` / `addMissingUiamKeyTagIfNeeded` smoke test.
> - TM cleanup failure where `taskManager.bulkRemove` throws.
> - `bulkMarkApiKeysForInvalidation` failure.

Add unit tests for each of the above scenarios.

## 7 hidden code suggestions (minor)

### ~~utils.ts line 140: remove `as unknown as RuleDomain<Params>` cast~~ DONE

> Suggestion: replace `} as unknown as RuleDomain<Params>,` with `},`

Removed the unsafe double type assertion. Object shape already satisfies `transformRuleDomainToRuleAttributes`'s expected parameter type. Removed unused `RuleDomain` import.

### utils.ts line 77: remove duplicate `addGeneratedActionValues` call in `prepareRule` -- SKIPPED (memory)

> nit: I remember we discussed this, that the `addGeneratedActionValues` is also called in the A1 phase. Can we enrich the `validated` rules with the generated actions and system actions so that `prepareRule` has them already (`rule` param) with their generated values, allowing us to avoid the second call?

Skipped: storing enriched data in the `validated` map causes a net peak RAM increase (~42MB at 10K rules with alertsFilter). Since Kibana has historically OOM'd during bulk rule creation, the duplicate call is preferable. See `.knowledge/reports/bulk-create-dedup-action-values-memory.md`.

### ~~bulk_create_rules.ts: 5 logger message formatting tweaks~~ DONE
Six inline code suggestions changing `context.logger.warn` / `context.logger.debug` to `logger.debug`. Applied:
- Line 91 (original): `context.logger.debug(` → `logger.debug(`
- Line 123 (original): `logger.warn(...)` → `logger.debug(...)`
- Line 339 (original): `logger.warn(...task validation failed...)` → `logger.debug(...)`
- Line 354 (original): `context.logger.debug(` → `logger.debug(`
- Line 480 (original): `logger.warn(...SO creation failed...)` → `logger.debug(...)`

## Ordering / dependencies
- Items 4, 5 (batchSize validation) are independent and can be done first.
- Item 7 is skipped (best-effort validation kept).
- Item 6 (move validateScheduleLimit to A3) is independent now that 7 is skipped.
- Item 3 (remove ENABLE audit) is independent.
- Item 8 (extract cleanup util) should be done after item 1 (apiKeysMap.delete) since both touch cleanup code.
- Item 2 (bulkScheduleTask) is independent.
- Item 9 (tests) should be last, after all production code changes.
- The hidden code suggestions can be folded into the relevant items.
