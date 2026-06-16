---
name: PR 269340 review feedback
overview: "Address the 9 remaining review comments from @cnasikas on PR #269340, plus 7 minor code suggestions. Changes are scoped to bulk_create_rules.ts, utils.ts, schedule_task.ts, and the test file."
todos:
  - id: batch-size-validation
    content: "Items 4+5: Throw on invalid batchSize (> MAX or < 1) instead of clamping. Update tests."
    status: pending
  - id: throw-on-validation-errors
    content: "Item 7: Throw on all preValidate errors, ignore exitEarlyOnError for validation phase. Update tests."
    status: pending
  - id: validate-schedule-limit-a3
    content: "Item 6: Move validateScheduleLimit to preValidate as phase A3 (single upfront check). Throw 400 on overflow. Remove B2 from runBatch. Update tests."
    status: pending
  - id: remove-enable-audit
    content: "Item 3: Remove RuleAuditAction.ENABLE audit event after B4 SO persistence. Update test."
    status: pending
  - id: api-keys-map-delete
    content: "Item 1: Add apiKeysMap.delete(id) in prepareRule catch. Add unit test for key cleanup on prepare failure."
    status: pending
  - id: extract-cleanup-util
    content: "Item 8: Extract repeated cleanup pattern into a utility function."
    status: pending
  - id: bulk-schedule-task
    content: "Item 2: Move buildTaskInstance to schedule_task.ts, create bulkScheduleTask, share util with scheduleTask."
    status: pending
  - id: dedup-add-generated-actions
    content: "Hidden nit: Remove duplicate addGeneratedActionValues call in prepareRule, pass enriched data from A1."
    status: pending
  - id: logger-formatting
    content: "Hidden nits: Apply 5 logger message formatting suggestions + utils.ts comma fix."
    status: pending
  - id: add-test-scenarios
    content: "Item 9: Add 4 test scenarios (validateActions failure, uiamApiKey smoke, TM cleanup failure, bulkMarkApiKeysForInvalidation failure)."
    status: pending
isProject: false
---

# Address PR #269340 Review Feedback

## Files involved

- [bulk_create_rules.ts](x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts) -- main logic
- [utils.ts](x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/utils.ts) -- helpers
- [schedule_task.ts](x-pack/platform/plugins/shared/alerting/server/rules_client/lib/schedule_task.ts) -- task scheduling
- [bulk_create_rules.test.ts](x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.test.ts) -- tests

## 9 remaining review items

### 1. `apiKeysMap.delete(id)` in catch of `prepareRule` (utils.ts)

> Let's do `apiKeysMap.delete(id)` in the `catch` in case the API key was created, but any of the other functions fail. Let's be sure that these keys are invalidated/flushed correctly and add a unit test for this.

If an API key is created but a later step in `prepareRule` throws, the key stays in `apiKeysMap` and won't get cleaned up. Add `apiKeysMap.delete(id)` in the catch block at line 184 of `utils.ts`. Add a unit test proving the key is invalidated when prepare fails after key creation.

### 2. Move `buildTaskInstance` to `schedule_task.ts`, create `bulkScheduleTask`

> nit: Could you plz create a `bulkScheduleTask` in `x-pack/platform/plugins/shared/alerting/server/rules_client/lib/schedule_task.ts` and follow the same pattern as `scheduleTask`? Also, the two can call a small util (in the same file) called `buildTaskInstance`. This way we can also remove our own `buildTaskInstance` in `utils.ts`.

Move `buildTaskInstance` from `utils.ts` to [schedule_task.ts](x-pack/platform/plugins/shared/alerting/server/rules_client/lib/schedule_task.ts). Make both `scheduleTask` and the new `bulkScheduleTask` share it. Update `bulk_create_rules.ts` to call `bulkScheduleTask` instead of building tasks inline. Remove `buildTaskInstance` from utils.ts.

### 3. Remove ENABLE audit log

> I think we should remove the audit log here. We audited before the `CREATE` action.

Remove the `RuleAuditAction.ENABLE` audit event emitted after B4 SO persistence (lines 460-473 of `bulk_create_rules.ts`). The `CREATE` audit event is sufficient. Update the existing test that checks for ENABLE audit events.

### 4. Throw on `batchSize > MAX_BULK_CREATE_BATCH_SIZE`

> Let's throw an error if `batchSize > MAX_BULK_CREATE_BATCH_SIZE` instead of clamping.

Instead of clamping to the max, throw a Boom.badRequest when `batchSize > MAX_BULK_CREATE_BATCH_SIZE`. Update the test "clamps batchSize above hard cap" to expect a throw.

### 5. Throw on `batchSize < 1`

> Let's throw if `params.batchSize < 1` (or a min that we like, like 10). Otherwise, if I set the `params.batchSize` to zero, this code will set the `batchSize` to one, which will run N batches of 1 which is the same as calling `createRule` N times.

Throw a Boom.badRequest when `batchSize < 1`. This prevents accidentally running N batches of 1 (same as calling createRule N times). Add a test for this.

### 6. Move `validateScheduleLimit` to preValidate as phase A3

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

### 7. Throw on ALL validation errors (ignore `exitEarlyOnError`)

> I think for all validation errors we should throw the error, ignore the `exitEarlyOnError` and do not continue with the bulk create rules operation.

For preValidate failures, always throw instead of returning errors. The `exitEarlyOnError` flag should only apply to ES-write failures in phase B, not to validation failures in phase A. If any rule fails A1, throw immediately. This simplifies the post-preValidate flow.

### 8. Extract cleanup utility

> nit: I feel like that we do these operations a lot: collect the keys to invalidate them, bulk remove tasks, and flush the invalidated keys. Could we move the common logic to a small utility function (in the same file)?

The pattern of "collect keys to invalidate + bulkRemove tasks + flush keys" repeats ~4 times in `runBatch`. Extract into a small utility like `cleanupResources({ apiKeysMap, keysToInvalidate, taskIds, context })` in the same file or in `utils.ts`.

### 9. Add 4 test scenarios

> Great coverage! Thank you so much for this. Could you plz also add the following testing scenarios:
>
> - `validateActions` failure paths. One unit test should be enough.
> - `uiamApiKey` / `addMissingUiamKeyTagIfNeeded` smoke test.
> - TM cleanup failure where `taskManager.bulkRemove` throws.
> - `bulkMarkApiKeysForInvalidation` failure.

Add unit tests for each of the above scenarios.

## 7 hidden code suggestions (minor)

### utils.ts: formatting fix on closing brace
GitHub suggestion on comma placement. Apply as-is.

### utils.ts: remove duplicate `addGeneratedActionValues` call in `prepareRule`

> nit: I remember we discussed this, that the `addGeneratedActionValues` is also called in the A1 phase. Can we enrich the `validated` rules with the generated actions and system actions so that `prepareRule` has them already (`rule` param) with their generated values, allowing us to avoid the second call?

Pass the enriched `data` (with generated actions) from A1 through to `prepareRule` so it doesn't need to call `addGeneratedActionValues` again.

### bulk_create_rules.ts: 5 logger message formatting tweaks
Six inline code suggestions changing `context.logger.debug` to `logger.debug` and shortening log messages. Apply each suggestion as-is.

## Ordering / dependencies
- Items 4, 5 (batchSize validation) are independent and can be done first.
- Item 7 (throw on validation errors) and item 6 (move validateScheduleLimit to A3) interact -- do 6 after 7 since A3 should also throw.
- Item 3 (remove ENABLE audit) is independent.
- Item 8 (extract cleanup util) should be done after item 1 (apiKeysMap.delete) since both touch cleanup code.
- Item 2 (bulkScheduleTask) is independent.
- Item 9 (tests) should be last, after all production code changes.
- The hidden code suggestions can be folded into the relevant items.
