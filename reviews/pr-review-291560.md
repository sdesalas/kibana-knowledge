# PR Review: #291560 — Optimize `rules/_import` update path via `bulkUpdateRules()`

**PR:** [elastic/kibana#291560](https://github.com/elastic/kibana/pull/291560) by @sdesalas

**Scale:** Substantive. This changes persisted rule updates, scheduling state, batching, API keys, error mapping, and cross-plugin behavior.

### Context / Motivation

[Issue #275204](https://github.com/elastic/kibana/issues/275204) asks for the import overwrite path to stop updating rules one at a time:

> Wire the `rules/_import` overwrite path to use `rulesClient.bulkUpdate()` for existing rules, replacing the per-rule fallback.

It also asks to reuse preloaded rule assets and move outer batching to the route:

> Outer batching should live on the `_import` route so later work can raise the payload limit and stream batches from the route.

Streaming itself and the prerequisite FTR audit are intentionally separate.

### Validating the issue — does this PR address it?

The performance concern is valid. The PR addresses Todo items 2–5 correctly; item 6 is covered externally rather than changed in this commit. The enable reporting gap was fixed in follow-up activity 3; one lower-impact Task Manager disable-reporting gap remains after revalidation in activity 5.

- **Where the problem manifests:** the old overwrite path ran `rulesClient.update()` and enabled/disabled each rule separately with `pMap` concurrency 50. A 1,000-rule overwrite could therefore perform 1,000 independent update flows.
- **How the PR fixes it:** the route sends chunks of 200 to the Detection Rules Client. Each chunk performs one `bulkUpdateRules()` call, maps Alerting IDs back to `rule_id`, then bulk-toggles only successfully updated rules whose enabled state changed.
- **Drive-by optimization:** import's existing `(rule_id, version)` asset lookup is passed into `calculateRuleSource`; explicit `null` records a completed miss and prevents another fetch.
- **Streaming preparation:** route-level chunking is now structurally ready to consume streamed batches later, although parsing and pre-validation still hold the current file in memory as expected.
- **Residual caveat:** bulk enable/disable use different Task Manager failure contracts from the old single-rule methods. Those differences currently leak into import success reporting.

Todo assessment:

- **2 — Complete:** overwrite now uses `bulkUpdateRules()`.
- **3 — Complete for the concrete opportunity:** the duplicate prebuilt-asset fetch is removed.
- **4 — Complete:** outer batching moved to `route.ts`; the DRC processes one supplied batch.
- **5 — Complete:** focused tests cover route batching, update mapping, write errors, enabled-state changes, connector options, change tracking, and asset reuse.
- **6 — Covered externally:** this commit changes no API integration tests. Existing tests on `main` cover basic overwrite, batch boundaries, and enabled-state changes; the additional prerequisite coverage is in [#291548](https://github.com/elastic/kibana/pull/291548), which is still open.

### Summary

The PR replaces per-rule overwrite writes with one Alerting bulk update per 200-rule route chunk. It retains bulk create for new rules, separates enabled-state transitions into bulk enable/disable calls, preserves per-rule API responses, and removes a redundant prebuilt-asset lookup. The implementation matches the main ticket design, subject to the residual disable-reporting gap, the batch-scoped failure behavior below, and the external FTR prerequisite.

### Files touched

- **Route batching and request aggregation:** `api/constants.ts`, `api/rules/import_rules/route.ts`, and `route.test.ts` define the 200-rule outer chunk and aggregate batch results while retaining full-request change-tracking counts.
- **Import orchestration and contracts:** `detection_rules_client.ts`, `import_rules.ts`, `create_rules.ts`, `types.ts`, and their tests make batching a caller responsibility and share write options between create and overwrite.
- **Bulk overwrite:** `overwrite_rules.ts` prepares updates, maps saved-object IDs to import results, invokes `bulkUpdateRules`, and performs enabled-state transitions.
- **Prebuilt asset reuse:** `apply_rule_update.ts`, `calculate_rule_source.ts`, and its tests carry a prefetched asset or an explicit lookup miss.
- **Lookup safety:** `find_installed_rules_by_signature_ids.ts` and its tests retain the Elasticsearch clause-count constraint for one route batch.
- **Alerting dependency coverage:** `bulk_update/utils.test.ts` adds direct tests for PIT loading, missing IDs, schedule grouping, validation failures, and Task Manager schedule-update handling.
- **Change tracking:** `detection_rules_client.change_tracking.test.ts` verifies import metadata reaches the new bulk update path.

### Flow trace

1. `_import` parses the NDJSON and performs connector, action, and response-action validation for the request.
2. The route chunks validated rules into groups of 200.
3. For each chunk, the DRC loads exception lists, matching prebuilt assets, and installed rules in parallel.
4. Validation classifies rules as conflicts, creates, or overwrites.
5. Overwrites are merged with existing persisted fields and the prefetched asset context.
6. One `bulkUpdateRules()` call writes all valid overwrite inputs and returns successful saved-object IDs plus per-item errors.
7. Only successful writes are considered for enabled-state changes; changed states are sent to bulk enable/disable.
8. Saved-object IDs and toggle errors are mapped back to public `rule_id` values.
9. Creates still use `bulkCreateRules()`.
10. The route aggregates all chunk results into one import response and keeps `changeTracking.metadata.bulkCount` at the full validated request count.

### Assumptions

- The route remains the only production caller of `DetectionRulesClient.importRules`; the DRC no longer protects itself by outer-chunking large input.
- Route duplicate handling guarantees one effective imported rule per `rule_id` before the DRC builds maps keyed by rule or saved-object ID.
- `bulkUpdateRules()` reports every failed persisted item through `errors` and every persisted item through `successfulIds`.
- A missing entry in `matchingAssetsByRuleId` is an authoritative lookup miss for the imported `(rule_id, version)`.
- Import success is intended to include operational scheduling success, not merely persistence of the rule saved object. The current PR description implies this by treating toggle errors as import errors.

These assumptions were revalidated and qualified in follow-up activity 5.

### Risks

1. ~~**Medium — enable can report success when Task Manager failed to enable the task.** `bulkEnableRules()` deliberately converts Task Manager failures into `taskIdsFailedToBeEnabled`, but import only reads `errors`:~~

```155:168:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/import_rules/overwrite_rules.ts
if (enableIds.length > 0) {
  const { errors: enableErrors } = await rulesClient.bulkEnableRules({ ids: enableIds });
  for (const err of enableErrors) {
    failedIds.add(err.rule.id);
    const source = pending.get(err.rule.id);
    // ...
  }
}
```

~~The saved object can therefore be `enabled: true`, `_import` can count it as successful, and its task can remain disabled or unavailable. Impact is high because this is a silent missed-detection state; likelihood is lower because it requires a Task Manager failure. The old `enableRule()` path propagated a rejected Task Manager call. This needs either failure mapping from `taskIdsFailedToBeEnabled` or an explicit decision that import success only covers persistence.~~ **(FIXED)** See follow-up activity 3.

2. **Low — disable can report success while Task Manager failed to disable or remove the task.** Alerting bulk disable waits with `Promise.allSettled`, logs Task Manager failures, and returns no failed task IDs:

```89:99:x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_disable/bulk_disable_rules.ts
const [taskIdsToDisable, taskIdsToDelete, taskIdsToClearState] = accListSpecificForBulkOperation;

await Promise.allSettled([
  tryToDisableTasks({
    taskIdsToDisable,
    taskIdsToClearState,
    logger: context.logger,
    taskManager: context.taskManager,
  }),
  tryToRemoveTasks({ taskIdsToDelete, logger: context.logger, taskManager: context.taskManager }),
]);
```

Import has no signal to turn this into a per-rule error. The rule saved object is disabled, but the task may remain scheduled; whether it can execute again depends on task-runner safeguards. The old `disableRule()` path propagated a rejected Task Manager call. Preserving parity likely requires extending the bulk-disable result contract, not only changing Security Solution code.

Follow-up activity 5 confirmed the execution impact is lower than first stated: Alerting's rule loader rejects a task whose saved object has `enabled: false` before calling the rule executor, and the task runner returns `shouldDisableTask`. The residual risk is stale-task cleanup and inaccurate import reporting, not another detection execution.

3. **Low — the DRC now relies on a route-only maximum-size invariant.** `importRules()` no longer chunks before constructing the installed-rule KQL lookup. The current production route enforces 200, but another current or future caller can pass a larger array despite `ImportRulesArgs.batchSize`, first risking the Elasticsearch clause floor and, at much larger sizes, Alerting's 10,000-rule hard limit. Either document/enforce the maximum in the DRC or keep the route-only assumption explicit in its interface. Revalidated in follow-up activity 5.

4. **Process/coverage — the prerequisite overwrite FTR PR is not merged.** [#291548](https://github.com/elastic/kibana/pull/291548) is open, while the ticket requires that coverage on `main` before this optimization merges. Existing `main` coverage is useful, but the additional interval, partial-success, change-history, and batch-sized enabled-state cases are not part of this branch.

5. **Low — a schedule-limit overflow rejects unrelated overwrites in the same 200-rule chunk.** `bulkUpdateRules()` intentionally validates changed intervals as one batch. On overflow it returns errors for every prepared item, not only the enabled rules whose intervals contributed to the limit. Because import passes each 200-rule route chunk as one Alerting batch, disabled rules and rules with unchanged schedules in that chunk also fail. The old per-rule path isolated the circuit-breaker failure to the individual update. This is a documented `bulkUpdateRules()` tradeoff from [#286508](https://github.com/elastic/kibana/pull/286508), but it is still an import behavior change worth accepting explicitly. Identified in follow-up activity 5.

6. **Medium — a top-level bulk enable/disable rejection couples unrelated rules after persistence.** Returned item errors and Task Manager failures are handled, but a rejection from `bulkEnableRules()` or `bulkDisableRules()` bubbles out of `overwriteRules()`. The outer catch then reports every unresponded rule in the route chunk as failed and skips the create bucket, even when some overwrites were already persisted or needed no enabled-state change. The old `pMap` path caught a thrown toggle per overwrite and continued. This requires a less common top-level Alerting failure (for example PIT, authorization, or saved-object access), but the impact spans partial persistence and up to the full 200-rule chunk, and there is no focused test for it. Identified in follow-up activity 5.

7. **Low — a disabled rule with a valid legacy task ID can be left enabled but unscheduled.** `bulkEnableRules()` decides whether to schedule a replacement by checking the original `scheduledTaskId`, but always persists `scheduledTaskId: rule.id` and later enables that rewritten ID. If the original task exists under a different ID, no replacement is scheduled, the saved object points at a task that does not exist, and the old task is no longer referenced. The Risk 1 fix should report the failed `rule.id` enable, but the saved object remains enabled and a repeat import skips the toggle. The old single-rule `enableRule()` instead re-enabled the original task ID. This is limited to legacy or otherwise noncanonical persisted state, but the explicit nonmatching-ID handling in both disable paths confirms that state is supported. Identified in follow-up activity 5.

### Open questions

- Should `_import` success mean “rule saved object persisted” or “rule persisted and requested scheduling state applied”? The implementation and PR description currently imply the latter.
- Can Alerting expose disable/remove Task Manager failures by task or rule ID, matching `taskIdsFailedToBeEnabled`?
- Should `DetectionRulesClient.importRules` reject inputs above `RULE_IMPORT_BATCH_SIZE`, or is it intentionally route-only?
- Is rejecting every overwrite in a 200-rule chunk acceptable when only some enabled interval changes trip the schedule circuit breaker?
- Should a top-level bulk toggle failure prevent independent creates in the same route chunk?
- Should import add coverage for a disabled rule whose existing `scheduledTaskId` differs from its rule saved-object ID, or should Alerting fix that behavior first?
- Will #291548 merge into `main` before this PR, as required by the ticket?

### Notes for your codebase map

- Alerting `bulkUpdateRules()` intentionally preserves the current `enabled` field; callers must perform enabled-state transitions separately.
- Bulk update returns saved-object IDs, so import keeps an ID-to-`rule_id` map for public results and telemetry.
- Route-level batching controls lookup/KQL size; Alerting's `batchSize` controls inner persistence batching.
- `matchingAsset: undefined` means “fetch here,” while `null` means “already looked up and missing.”
- Bulk enable exposes Task Manager failures separately from saved-object errors; bulk disable currently only logs them.

### Follow-up Review Activities

1. **Validated the initial PR commit against issue #275204.**
   - Confirmed Todo items 2–5 are implemented in commit `6c0357028e8f`.
   - Todo item 6 relies on existing and separately proposed API/FTR coverage; this commit contains no API integration test changes.
   - Confirmed the prerequisite FTR PR #291548 is still open.
   - Ran all six directly changed/relevant Jest suites: 74 tests passed.
   - Linted all 16 changed files: no errors.
   - Type-checked Security Solution and Alerting projects: both passed.
   - `git diff --check origin/main...HEAD` passed.
   - Did not independently rerun FTR; the PR description reports 113 local FTR tests passing.

2. **Independent full-diff review confirmed the scheduling risks and identified two coverage/behavior additions.**
   - Confirmed enable Task Manager failures live only in `taskIdsFailedToBeEnabled`; the current import mapping treats those rules as successes.
   - Confirmed bulk disable exposes no equivalent failed-task result, so Security Solution cannot preserve the old `disableRule()` error behavior without an Alerting contract change.
   - The overwrite unit tests cover a saved-object-level enable error but not `taskIdsFailedToBeEnabled`, a successful disable flip, or a disable Task Manager failure.
   - A thrown `bulkUpdateRules()` call now marks every unresponded rule in the current 200-rule chunk as failed. The old `pMap` path isolated thrown update failures per rule. This is a low-likelihood behavior change because normal item failures are returned through the bulk result.
   - Task Manager failure while changing an already-enabled rule's schedule is not a new regression: both old update and bulk update log/swallow that scheduling error.

3. **Assessed and implemented fix for Risk 1.** Confirmed a reporting regression for thrown `taskManager.bulkEnable` failures. The original write-up overstated parity with the old path for per-item TM errors that do not throw.
   - `bulkEnableRules()` writes the rule SO as `enabled: true` first, then calls `tryToEnableTasks()`. TM failures never go into `errors`; they go to `taskIdsFailedToBeEnabled` (per-item `bulkEnable.errors`, or every ID if `bulkEnable` throws). Import only destructured `errors`, so those rules landed in `successes`.
   - After bulk enable, `scheduledTaskId` is forced to the rule SO id, so those failed task IDs are rule IDs and can be mapped locally. No Alerting contract change is required.
   - Old `enableRule()` awaited `taskManager.bulkEnable()` and let a throw reject; `toggleRuleEnabledOnUpdate` then failed the import item. `bulkEnableRules()` catches that throw. That is the actual regression.
   - Old `enableRule()` also ignored per-item `bulkEnable` errors that did not throw, so that failure mode was already silent. Both paths also leave the same persisted split (SO enabled, task not) when TM fails after the SO write.
   - Re-import does not heal it: a second overwrite with `enabled: true` sees an already-enabled SO and skips bulk enable. The UI also shows the rule as enabled, so there is no Enable button. Recovery is disable-then-enable (or calling Alerting `enableRule` on an already-enabled rule, which still tries to enable the task).
   - Scope is only overwrite flips from disabled → enabled. Create-enabled still schedules with `enabled: true` inside `bulkCreateRules()` and treats schedule failures as item errors. Security Solution UI bulk enable already ignores `taskIdsFailedToBeEnabled` the same way.
   - `toggleImportedEnabled` now maps `taskIdsFailedToBeEnabled` to import errors (`Failed to enable task`, same text as the old throw) and keeps those ids out of `successes`. Saved-object `errors[]` still use Alerting's item message. Added a unit test. Pushed in `dd1c5d1965f7`.

4. **Investigated extra change-history `rule_enable` entry on overwrite (disabled → enabled).** Observed locally: import 100 disabled rules, then overwrite with 100 enabled rules, yields 2 history items on `main` and 3 on this branch (the extra one is `rule_enable`). Not a blocker for this PR; waits on [#262665](https://github.com/elastic/kibana/issues/262665).
   - Both paths keep `enabled` off the update write. Main then calls `toggleRuleEnabledOnUpdate()` → `enableRule()` / `disableRule()`, which never call `logRuleChanges()`. This branch calls `bulkEnableRules()` / `bulkDisableRules()`, which always log `rule_enable` / `rule_disable`.
   - `toggleRuleEnabledOnUpdate()` does not itself skip history; the single-rule Alerting methods were never instrumented. The Security UI enable switch already goes through bulk and does record history.
   - [#262665](https://github.com/elastic/kibana/issues/262665) tracks wiring unused (from Security Solution's POV) `RulesClient` write methods, including `enableRule` and `disableRule`. Until that lands, main silently drops the enable snapshot on update/patch/import; this PR surfaces it because it uses the already-instrumented bulk APIs.
   - Decision: leave the extra history item. Folding enable into the import event is not possible without Alerting allowing `enabled` on update, and matching main would mean suppressing a real write. Parity belongs to #262665.

5. **Revalidated the assumptions and current PR head after the enable-failure fix.**
   - The implementation commit was rebased from the historical `6c0357028e8f` referenced above to `029bfcf6d52c`; current head is `dd1c5d1965f7`.
   - A repository-wide caller search found the HTTP route as the only production caller of `DetectionRulesClient.importRules`. Direct calls remain possible through the public interface, which is why Risk 3 still stands.
   - Route duplicate handling is global and keyed by `rule_id` before chunking; overwrite keeps one last value. This satisfies the maps in import and Alerting, which otherwise collapse duplicate IDs.
   - With unique IDs and `exitEarlyOnError: false`, `bulkUpdateRules()` accounts for each returned item through `successfulIds` or `errors`; thrown whole-call failures are converted to per-rule import errors by the DRC catch. No silent unaccounted row was found.
   - The prefetched asset lookup uses the imported `(rule_id, version)`. Its errors are collapsed into a missing entry, but overwrite does not gain a new semantic dependency on that miss: validation already calculates the final `ruleSource` from the same prebuilt context and overwrites `applyRuleUpdate`'s intermediate value.
   - Scheduling-inclusive success is implementation behavior, not an explicit response-schema contract: create and enable failures are excluded from successes, while disable Task Manager failures cannot currently be surfaced.
   - Downgraded Risk 2 after confirming `rule_loader.ts` stops disabled rules before the executor and `task_runner.ts` requests task disable. Added Risks 5 and 6 for the verified schedule-circuit and top-level toggle batch scope.
   - Added Risk 7 after tracing noncanonical task IDs: bulk enable checks the old ID for existence, then rewrites and enables `rule.id`; single-rule enable preserves and enables the old ID.
   - Found no additional correctness issue in route aggregation, connector/action validation, exception-list sanitization, API-key handling, telemetry forwarding, or the normal successful ordering.
   - Current status check: #291560 is still a draft and has only lightweight checks; full Buildkite CI has not been triggered. Prerequisite #291548 remains open, with `kibana-ci` green but review still required.
   - Re-ran the focused import-client and route Jest suites on current head: 34 tests passed (27 + 7).

