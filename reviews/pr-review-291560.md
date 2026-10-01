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

The performance concern is valid. The PR addresses Todo items 2–5. Item 1 is the prerequisite FTR on `main` via [#291548](https://github.com/elastic/kibana/pull/291548) (merged 2026-09-23). Item 6 is unchanged in this commit: no API integration tests were added alongside the write-path change; existing `main` coverage plus the item 1 FTR are treated as sufficient. The enable reporting gap was fixed in follow-up activity 3; one lower-impact Task Manager disable-reporting gap remains after revalidation in activity 5.

- **Where the problem manifests:** the old overwrite path ran `rulesClient.update()` and enabled/disabled each rule separately with `pMap` concurrency 50. A 1,000-rule overwrite could therefore perform 1,000 independent update flows.
- **How the PR fixes it:** the route sends chunks of 200 to the Detection Rules Client. Each chunk performs one `bulkUpdateRules()` call, maps Alerting IDs back to `rule_id`, then bulk-toggles only successfully updated rules whose enabled state changed.
- **Drive-by optimization:** import's existing `(rule_id, version)` asset lookup is passed into `calculateRuleSource`; explicit `null` records a completed miss and prevents another fetch.
- **Streaming preparation:** route-level chunking is now structurally ready to consume streamed batches later, although parsing and pre-validation still hold the current file in memory as expected.
- **Residual caveat:** bulk enable/disable use different Task Manager failure contracts from the old single-rule methods. Those differences currently leak into import success reporting.

Todo assessment:

- **1 — Complete externally:** overwrite FTR landed on `main` in [#291548](https://github.com/elastic/kibana/pull/291548) (merged 2026-09-23), before this optimization.
- **2 — Complete:** overwrite now uses `bulkUpdateRules()`.
- **3 — Complete for the concrete opportunity:** the duplicate prebuilt-asset fetch is removed.
- **4 — Complete:** outer batching moved to `route.ts`; the DRC processes one supplied batch.
- **5 — Complete:** focused tests cover route batching, update mapping, write errors, enabled-state changes, connector options, change tracking, and asset reuse.
- **6 — Not changed in this commit:** no API integration tests were added alongside the write-path change. Existing `main` tests already cover basic overwrite, batch boundaries, and enabled-state changes; item 1 added the extra interval, partial-success, change-history, and batch-sized enabled-state cases.

### Summary

The PR replaces per-rule overwrite writes with one Alerting bulk update per 200-rule route chunk. It retains bulk create for new rules, separates enabled-state transitions into bulk enable/disable calls, preserves per-rule API responses, and removes a redundant prebuilt-asset lookup. The implementation matches the main ticket design, subject to the residual disable-reporting gap and the batch-scoped failure behavior below. Prerequisite overwrite FTR is on `main` via [#291548](https://github.com/elastic/kibana/pull/291548) (merged 2026-09-23).

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
- Import success is mixed, not a single contract. Enable Task Manager failures are mapped to import errors (`taskIdsFailedToBeEnabled`). Disable Task Manager failures cannot be surfaced — the rule SO is disabled and the import can still count as success. The published PR description now states that split explicitly.

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

2. ~~**Low — disable can report success while Task Manager failed to disable or remove the task.** Alerting bulk disable waits with `Promise.allSettled`, logs Task Manager failures, and returns no failed task IDs:~~

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

~~Import has no signal to turn this into a per-rule error. The rule saved object is disabled, but the task may remain scheduled; whether it can execute again depends on task-runner safeguards. The old `disableRule()` path propagated a rejected Task Manager call. Preserving parity likely requires extending the bulk-disable result contract, not only changing Security Solution code.~~

Follow-up activity 5 confirmed the execution impact is lower than first stated: Alerting's rule loader rejects a task whose saved object has `enabled: false` before calling the rule executor, and the task runner returns `shouldDisableTask`. The residual risk is stale-task cleanup and inaccurate import reporting, not another detection execution.~~ **(SKIPPED)** See follow-up activity 6. Activity 16: the same success definition also emits `detection_rule_import` for that rule, which `main` did not.

3. ~~**Low — the DRC now relies on a route-only maximum-size invariant.** `importRules()` no longer chunks before constructing the installed-rule KQL lookup. The current production route enforces 200, but another current or future caller can pass a larger array despite `ImportRulesArgs.batchSize`, first risking the Elasticsearch clause floor and, at much larger sizes, Alerting's 10,000-rule hard limit. Either document/enforce the maximum in the DRC or keep the route-only assumption explicit in its interface. Revalidated in follow-up activity 5.~~ **(Dropped — nit; Alerting already 400s `batchSize > 500`, and a non-route caller with a huge array not only doesnt make a lot of sense but would need to pass a code review, not a problem)** See activity 18.

4. ~~**Process/coverage — the prerequisite overwrite FTR PR is not merged.** [#291548](https://github.com/elastic/kibana/pull/291548) is open, while the ticket requires that coverage on `main` before this optimization merges. Existing `main` coverage is useful, but the additional interval, partial-success, change-history, and batch-sized enabled-state cases are not part of this branch.~~ **(MERGED)** #291548 merged 2026-09-23.

5. ~~**Low — a schedule-limit overflow rejects unrelated overwrites in the same 200-rule chunk.** `bulkUpdateRules()` intentionally validates changed intervals as one batch. On overflow it returns errors for every prepared item, not only the enabled rules whose intervals contributed to the limit. Because import passes each 200-rule route chunk as one Alerting batch, disabled rules and rules with unchanged schedules in that chunk also fail. The old per-rule path isolated the circuit-breaker failure to the individual update. This is a documented `bulkUpdateRules()` tradeoff from [#286508](https://github.com/elastic/kibana/pull/286508), but it is still an import behavior change worth accepting explicitly. Identified in follow-up activity 5.~~ **(ACCEPTED)** Same tradeoff as [tradeoff 7](https://github.com/elastic/kibana/pull/284946#discussion_r3797844388); called out in the PR description Risks. The enable-step variant is Risk 10.

6. ~~**Medium — a top-level bulk enable/disable rejection couples unrelated rules after persistence.** Returned item errors and Task Manager failures are handled, but a rejection from `bulkEnableRules()` or `bulkDisableRules()` bubbles out of `overwriteRules()`. The outer catch then reports every unresponded rule in the route chunk as failed and skips the create bucket, even when some overwrites were already persisted or needed no enabled-state change. The old `pMap` path caught a thrown toggle per overwrite and continued. This requires a less common top-level Alerting failure (for example PIT, authorization, or saved-object access), but the impact spans partial persistence and up to the full 200-rule chunk, and there is no focused test for it. Identified in follow-up activity 5.~~ **(FIXED)** See follow-up activity 9.

7. ~~**Low — a disabled rule with a valid legacy task ID can be left enabled but unscheduled.** `bulkEnableRules()` decides whether to schedule a replacement by checking the original `scheduledTaskId`, but always persists `scheduledTaskId: rule.id` and later enables that rewritten ID. If the original task exists under a different ID, no replacement is scheduled, the saved object points at a task that does not exist, and the old task is no longer referenced. The Risk 1 fix should report the failed `rule.id` enable, but the saved object remains enabled and a repeat import skips the toggle. The old single-rule `enableRule()` instead re-enabled the original task ID. This is limited to legacy or otherwise noncanonical persisted state, but the explicit nonmatching-ID handling in both disable paths confirms that state is supported. Identified in follow-up activity 5.~~ **(DISCARDED)** Import only bulk-enables rules that are currently disabled, and disabling clears a nonmatching legacy task ID in every version, so the state does not arise on this path ([PR reply](https://github.com/elastic/kibana/pull/291560#discussion_r4144086661)). The underlying `bulkEnableRules` bug (already-enabled legacy rules) is on `main` and tracked for ResponseOps in [#294458](https://github.com/elastic/kibana/issues/294458).

8. ~~**Low — a top-level bulk update rejection still skips independent creates in the same route chunk.** `overwriteRules()` lets a rejected `bulkUpdateRules()` escape. The outer `importRules()` catch then reports every unresponded rule as failed and exits before `createRules()`, even though the create bucket is independent. Alerting already converts normal preparation and saved-object write failures into per-item errors, so the remaining rejection paths are uncommon batch-level failures such as PIT loading, authorization, or client acquisition. Main's old per-rule flow isolated those failures and still processed creates. Catching at the overwrite bucket boundary could map the rejection only to `toOverwrite` and continue with `toCreate`.~~ **(FIXED)** See follow-up activity 10.

Additional risks from the final full review (activity 20):

9. ~~**Low/Medium — overwrite now accepts actions whose connector is missing secrets, and this isn't called out anywhere.** `importRules()` now passes `allowMissingConnectorSecrets` to `overwriteRules()` → `bulkUpdateRules()` (`import_rules.ts:109-116`, `overwrite_rules.ts:112`). On `main`, overwrite never passed it (`rulesClient.update()` in both the pre-[#275695](https://github.com/elastic/kibana/pull/275695) `import_rule.ts` and the current `overwrite_rules.ts`), so Alerting's `validateActions()` returned a per-rule `Invalid connectors` error. Now the overwrite succeeds and the rule points at a connector that can't send until someone adds its secrets. The flag is `!!actionConnectors.length`, so it applies whenever the file contains *any* connector, including when the rule references an unrelated pre-existing connector that is missing secrets. This matches the create path and the original [#148703](https://github.com/elastic/kibana/pull/148703#discussion_r1091925005) intent, so it's likely the right call. But it's a user-visible behavior change that isn't in the PR description's "What else to look out for", isn't in the release note, and has no FTR coverage (one unit test only checks the flag gets forwarded; manual scenario 4 exercises it).~~ **(INTENDED)** Restores original behavior: [#148703](https://github.com/elastic/kibana/pull/148703) (8.7) wired `allowMissingConnectorSecrets` into both create and update for import ([thread](https://github.com/elastic/kibana/pull/148703#discussion_r1091925005)). It was dropped on overwrite in the DRC refactor [#184954](https://github.com/elastic/kibana/pull/184954). Documented in the code comment at `import_rules.ts:109-111`.

10. ~~**Low — the bulk-enable schedule-limit check fails every enable in the chunk, after the updates are already written.** `bulkEnableRules()` calls `validateScheduleLimit()` once for all rules it found (`bulk_enable_rules.ts:197-226`). On overflow, every rule in the call gets the circuit-breaker error. On `main`, `enableRule()` checked one rule at a time, so rules kept getting enabled until capacity ran out. With this PR, a chunk of up to 200 disabled→enabled flips is all-or-nothing: the field updates persist, every rule stays disabled, and all are reported as errors. A re-import does recover, because the rules are still disabled and the flip is detected again. Same family as accepted Risk 5, but the PR description only names `bulkUpdateRules` and `bulkCreateRules`, not the enable step.~~ **(ACCEPTED)** Same customer outcome as Risk 5: per-rule circuit-breaker errors, and re-uploading recovers.

11. ~~**Low — a legacy-actions migration failure no longer fails the overwrite.** `update()` awaits `bulkMigrateLegacyActions()` directly (`update_rule.ts:298`); it throws `Boom.badRequest` on failure, so on `main` that import item failed. `bulkUpdateRules()` catches it, logs `legacy actions migration failed, continuing`, and writes the rule anyway (`bulk_update_rules.ts:219-232`). The legacy sidecar SO and `siem.notifications` rule can survive, so a pre-7.16 rule could send notifications from both its legacy notification and the imported actions. This needs legacy actions still on the rule *and* a migration failure, so it's very unlikely. It's an Alerting design choice from [#286508](https://github.com/elastic/kibana/pull/286508), not something introduced by Security Solution code.~~ **(IGNORED)** Long shot: needs pre-7.16 legacy actions (7.16.0 shipped Dec 2021) that were never migrated, *plus* a migration failure.

12. ~~**Low — the audit log action for overwrite changes from `rule_update` to `rule_bulk_update`.** `bulkUpdateRules()` logs `RuleAuditAction.BULK_UPDATE`. An authorization failure is now one event per batch with no saved-object ID, instead of one `rule_update` event per rule. `rule_bulk_update` (and `rule_bulk_create`) are missing from `docs/reference/kibana-audit-events.md`, which only lists `rule_update` / `rule_create`. Customers who alert on `event.action: rule_update` will stop seeing import overwrites. There's precedent: the create path already switched to `rule_bulk_create` in [#275695](https://github.com/elastic/kibana/pull/275695). Enable and disable audit actions are unchanged (`rule_enable` / `rule_disable` per rule).~~ **(TRACKED)** Docs gap filed as [#294669](https://github.com/elastic/kibana/issues/294669), to fix after merge.

13. ~~**Process — the latest CI run passed only on retries, but the PR checklist says "CI green".** Build [#513589](https://buildkite.com/elastic/kibana-pull-request/builds/513589) on `1db027e` passed after retrying three failed steps. One of them is in Rule Management: *Serverless Rule Management - Prebuilt Rules Upgrade* (Cypress). Statically, the PR can't affect that path: only import passes `matchingAsset`, and upgrade, patch, and revert still go through the `undefined` branch that fetches the asset as before. But I couldn't open the job logs because `bk` isn't installed locally.~~ **(IGNORE)**

### Open questions

- Overwrite "success" meaning was already mixed/unclear on `main` (item succeeds if `update` + optional `enableRule`/`disableRule` did not throw; a rejected TM enable/disable/remove was an import error; non-throwing per-item enable errors and post-write schedule-update failures were already silent). This PR is also mixed (enable TM failures map to import errors; but disable TM failures cannot be surfaced, so a disabled SO can still count as success). Plus no rollback after a failed toggle on either path. That means a slight difference in the definion of "success".. Are we okay that partial disable failures (Task Manager SO write fail) are now silent versus `main`?
- Can Alerting expose disable/remove Task Manager failures by task or rule ID, matching `taskIdsFailedToBeEnabled`?
- ~~Should `DetectionRulesClient.importRules` reject inputs above `RULE_IMPORT_BATCH_SIZE`, or is it intentionally route-only?~~ **Answered — route-only; not worth enforcing. See activity 18.**
- ~~Is rejecting every overwrite in a 200-rule chunk acceptable when only some enabled interval changes trip the schedule circuit breaker?~~ **Answered — yes for this PR; same as [tradeoff 7](https://github.com/elastic/kibana/pull/284946#discussion_r3797844388).**
- ~~Should a top-level bulk toggle failure prevent independent creates in the same route chunk?~~ **Answered — no; fixed in activity 9.**
- ~~Should a top-level bulk update rejection prevent independent creates in the same route chunk?~~ **Answered — no; fixed in activity 10.**
- ~~Should import add coverage for a disabled rule whose existing `scheduledTaskId` differs from its rule saved-object ID, or should Alerting fix that behavior first?~~ **Answered — neither for this PR; Risk 7 discarded, Alerting fix tracked in [#294458](https://github.com/elastic/kibana/issues/294458).**
- ~~Will #291548 merge into `main` before this PR, as required by the ticket?~~ **Answered — yes; merged 2026-09-23.**

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
   - The implementation commit was rebased from the historical `6c0357028e8f` referenced above to `029bfcf6d52c`; current head at that revalidation was `dd1c5d1965f7`. Later verified head is `2272f0d19cf8` (see activities 14–15).
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

6. **Checked whether bulk disable returns a Task Manager failure list like Risk 1.** It does not. `BulkDisableRulesResult` is `{ rules, errors, total }`. `errors` is only saved-object write failures. There is no `taskIdsFailedToBeDisabled` (or any other failed-task field) on the method result or the HTTP schema.
   - `tryToDisableTasks` reads `bulkDisable` errors and a thrown `bulkDisable`, then logs them and returns nothing.
   - `tryToRemoveTasks` does build `taskIdsFailedToBeDeleted` and returns it, but `bulkDisableRules` wraps both calls in `Promise.allSettled` and discards that return value.
   - Import only destructures `errors` from `bulkDisableRules`. Unlike Risk 1, there is nothing local to map. Surfacing these failures still needs an Alerting contract change.

7. **Confirmed Risk 6 on current head `a60d0847eb3e` and narrowed its scope and fix.**
   - `overwriteRules()` records no successes until both top-level toggle calls finish. A rejection from either call therefore escapes to `importRules()` after `bulkUpdateRules()` has already persisted every successful overwrite.
   - The outer catch marks every unresponded rule in that route batch as failed and exits before `createRules()`. This includes successfully persisted overwrites that needed no toggle, plus new rules in the same batch. The route continues with later batches, so the maximum blast radius is the current 200-rule chunk rather than the full import.
   - These calls can reject before or around the toggle saved-object write: authorization and Saved Objects lookup failures, an empty post-update match, PIT iteration failures, Task Manager bulk scheduling failures during enable, and top-level Saved Objects write failures. Normal per-item write errors and Task Manager enable/disable failures do not use this path.
   - Main's old `pMap` flow caught a thrown single-rule toggle inside that rule's iteration and still processed unrelated overwrites and creates. The new behavior is therefore a verified loss of failure isolation.
   - A local fix is sufficient: catch enable and disable rejections independently, map each rejection only to the IDs submitted to that operation, and continue the other toggle and the create bucket. Marking every submitted toggle ID failed is conservative because a top-level rejection can occur after partial persistence. Focused mixed-batch tests should cover both enable and disable rejection and assert that unchanged overwrites, the other toggle group, and creates still complete.

8. **Implemented the Risk 6 fix in the working tree.**
   - `toggleState()` now catches top-level enable and disable rejections independently and maps each rejection only to the IDs submitted to that operation.
   - A shared failure recorder deduplicates returned item errors, Task Manager enable failures, and rejected-call errors while preserving their public `rule_id` mapping.
   - Added mixed-batch tests for both rejection paths. They verify that unchanged overwrites, the opposite toggle group, and new-rule creation continue successfully.
   - Focused Jest passed: 29 tests. ESLint, IDE diagnostics, and `git diff --check` also passed.

9. **Focused error-handling review of the full PR diff.**
   - **Finding**
     - [should-fix] import_rules.ts:109-138 — a rejected bulkUpdateRules() still skips independent creates in that batch. Raised as Risk 8. 
   - **Non-findings**
     - `toggleState()` now isolates enable and disable rejections correctly.
     - Per-item update/create errors retain rule IDs.
     - Completed overwrites survive later create failures.
     - Route batches continue after returned errors.
     - Telemetry failures are safely swallowed.
     - `bulkCreateRules()` can reject for batch-level preconditions and dependencies: invalid limits, username/actions client acquisition, bulk authorization, schedule-limit validation, or an unexpected uncaught framework failure.
     - Normal per-rule validation/preparation failures, Task Manager scheduling failures, whole-call saved-object write failures, and per-row saved-object failures are returned through `errors`.
     - Import's outer catch maps a remaining `bulkCreateRules()` rejection only to the unresponded create rules because overwrites have already been recorded, and create is the final bucket. With route and Alerting batch sizes both 200, the create subset also uses at most one internal batch. No create-side analogue of Risk 8 was found.

10. **Implemented the Risk 8 fix in `overwriteRules()`.**
    - A rejected `bulkUpdateRules()` is now mapped only to overwrite inputs that reached the bulk call, preserving earlier per-rule preparation errors.
    - `overwriteRules()` returns the partial result instead of rejecting, so `importRules()` continues with the independent create bucket.
    - Extended the rejection test with a mixed overwrite/create batch and verified that the overwrite reports `kaboom` while the new rule succeeds.
    - Focused Jest passed: 29 tests. ESLint, IDE diagnostics, and `git diff --check` also passed.

11. **Focused architecture review of the full PR diff.**
    - **Finding**
      - [nit] `detection_rules_client.ts:51,250` imports `RULE_IMPORT_BATCH_SIZE` from the API layer, while `route.ts:192,201` uses the same constant for both route chunking and Alerting's inner write batch. This keeps logic dependent on transport code and conflates two independently tunable policies. It is the layering aspect of Risk 3 rather than a new correctness risk.
    - **Non-findings**
      - Moving outer chunking to the route matches the ticket's ownership goal and leaves the Detection Rules Client responsible for one supplied batch.
      - Sharing `ImportRulesOptions` between create and overwrite removes duplicate write configuration without widening the public interface.
      - Passing a prefetched asset through `applyRuleUpdate()` keeps rule-source calculation in its existing merger layer and avoids an import-specific duplicate fetch without introducing a dependency cycle.
      - Alerting production code is unchanged; the added Alerting tests document the dependency contract this Security Solution path relies on, so they are in scope rather than a cross-plugin drive-by.
      - The create, overwrite, validation, and route aggregation responsibilities remain separated along the existing boundaries.

12. **Focused performance review of the full PR diff.**
    - **Finding**
      - [nit] `find_installed_rules_by_signature_ids.ts:35-48` still scales its KQL clause list and `perPage` directly with the caller's input. The production route caps this at 200, but the public Detection Rules Client does not enforce that bound. This revalidates Risk 3 rather than adding a new risk.
    - **Non-findings**
      - The overwrite path replaces up to 200 independent update flows with one `bulkUpdateRules()` call plus at most one bulk enable and one bulk disable call.
      - Prebuilt context requests run concurrently, and the matching asset map prevents a second per-rule asset fetch during overwrite.
      - Route chunks run sequentially, bounding concurrent Saved Objects, API-key, and Task Manager work; there is no new unbounded fan-out.
      - The overwrite preparation loop is sequential, but its former per-rule I/O is removed by the prefetched asset or explicit miss, so dropping `pMap` does not serialize network requests.
      - New maps, sets, and arrays are linear in the 200-rule route chunk. Parsing and full-request response aggregation still retain the current bounded import in memory, but that behavior predates this PR and streaming remains intentionally deferred.

13. **Focused RBAC review of the full PR diff.**
    - **Findings**
      - None.
    - **Non-findings**
      - The import route still requires `RULES_API_ALL`, matching the existing create, update, and delete rule routes.
      - `bulkUpdateRules()` re-establishes `WriteOperations.Update` authorization for every loaded rule type and consumer before using the unsecured Saved Objects client. Rule-parameter, connector/action, and system-action authorization also remain in the per-item preparation path.
      - Bulk enable and disable combine the requested IDs with a read authorization filter, then enforce `BulkEnable` or `BulkDisable` authorization before writing. The single and bulk operations belong to the same Alerting enable privilege group, so replacing the old calls does not widen access.
      - Authorization failures cannot reach an unsecured write for the rejected Alerting batch. Import maps rejected update and toggle calls back to the submitted rules without bypassing the underlying check.

14. **Verified PR-description risks 2 and 3 against current head `2272f0d19cf8`.**
    - **Risk 2 (two-step write) is real, but not new.** `bulkUpdateRules()` pins `enabled: originalRule.enabled`. Import then calls `bulkEnableRules` / `bulkDisableRules` only for successful IDs whose `enabled` flipped. Main did the same split: `rulesClient.update` then `toggleRuleEnabledOnUpdate` → `enableRule` / `disableRule`. Both old and new write the rule SO first, then the TM task. If the toggle fails after the field write, the updated fields stay; there is no rollback/cleanup on either path. After the enable-mapping fix, a failed enable is reported (`taskIdsFailedToBeEnabled` or a thrown call). The leftover is the same as main: SO can be `enabled: true` with no running task, and a repeat overwrite skips the toggle because the SO is already enabled.
    - **Risk 3 (silent disable) is real as a reporting gap, overstated as an execution risk.** `BulkDisableRulesResult` is `{ rules, errors, total }` — no failed-task IDs. `tryToDisableTasks` logs TM errors/throws and returns nothing; `tryToRemoveTasks` builds `taskIdsFailedToBeDeleted` but `Promise.allSettled` discards it. Import only reads `errors` (SO write failures). Old `disableRule()` awaited TM and threw (`disable_rule.test.ts` “throws when failing to disable task”), so overwrite used to fail that item. New path reports success. Execution is still blocked: `rule_loader.ts` throws `Disabled` when `!enabled`, and the task runner returns `shouldDisableTask`, so the leftover scheduled task should self-disable on the next tick rather than keep detecting. Surfacing the failure still needs an Alerting contract change.

15. **Revalidated the PR-description Risks section and published the rewrite.** Checked the live description against current head `2272f0d19cf8` and the remaining open review risks.
    - Risks 2 and 3 in the description were real but overstated. Two-step enable/disable is the same leftover as main (`update` then `toggleRuleEnabledOnUpdate`); enable TM failures are already mapped. Disable TM failures are a reporting gap, not another detection run: `rule_loader` rejects `enabled: false` and the task runner returns `shouldDisableTask`.
    - From the live review, only the schedule-limit blast radius (review risk 5) belonged in the description. DRC route-only batch cap, legacy `scheduledTaskId`, and the extra `rule_enable` history item stayed out. Review risk 4 is stale: #291548 merged 2026-09-23.
    - Published the four-bullet rewrite on [elastic/kibana#291560](https://github.com/elastic/kibana/pull/291560): no feature flag, two-step leftover, silent disable as reporting-only, and schedule-limit chunk failure with a link to [tradeoff 7](https://github.com/elastic/kibana/pull/284946#discussion_r3797844388).

16. **Focused telemetry review of the full PR diff.**
    - **Finding**
      - [nit] `overwrite_rules.ts:132-136` + `detection_rules_client.ts:261-269` — a disable Task Manager failure still lands in `successes`, so `detection_rule_import` fires as a clean success. The event has no outcome field, so usage stats cannot tell this apart from a fully successful overwrite. On `main`, thrown `disableRule()` never reached that loop. Same success definition as skipped Risk 2; noted on Risk 2 and the first open question.
    - **Non-findings**
      - Event name, schema, and payload are unchanged: `{ ruleId, ruleType, isPrebuilt, isCustomized }` from `{ id, type, rule_source }`. Sender, `ruleLifecycleTelemetrySchema`, and tests agree.
      - Overwrite still uses the existing saved-object id and the import-calculated `ruleSource` that is also persisted. Create still uses the pre-generated id echoed by `bulkCreateRules`.
      - Events fire only for `successes`. Conflicts, write errors, thrown update/create, and enable Task Manager failures do not emit. The route does not send a second copy.
      - Route-level chunking emits after each 200-rule `importRules` call instead of once after the old inner loop. These are per-rule events, so no double-count.
      - `sendRuleLifecycleTelemetryEvent` still swallows `reportEvent` failures at `debug`; they cannot fail the import.
      - Payload is SO id + type + two booleans. No customer content or PII.
      - No import usage-stats collector is involved; the 24h detection-rule lists task is unchanged.
      - No request-level import event exists (unlike `detection_rule_bulk_upgrade`); that predates this PR.
      - The HTTP response uses `successes.length` only; the `telemetry` field does not leave the server.

17. **Focused observability review of the full PR diff.**
    - **Findings**
      - None.
    - **Non-findings**
      - Route-level chunking turns one `DetectionRulesClient.importRules` span into one span per 200-rule chunk. A 1,000-rule import now shows five sibling spans under the HTTP transaction, which makes a slow or failed batch easier to see.
      - Overwrite, create, and toggle have no extra Security spans. That matches the old path (all work sat inside `importRules`). Alerting already nests named children (`bulkUpdateRules.*`, `bulkEnable` / `bulkDisable`, `taskManager.*`) under that span.
      - Going from per-rule `update`/`enableRule`/`disableRule` to one bulk call coarsens per-rule APM into one write span. Per-item failures still land in Alerting error logs and the import response `rule_id`.
      - The import route still has no `withSecuritySpan`. Same as `main`; history/restore routes do, but this route was never one of them.
      - No Security import logs were removed. `overwrite_rules` / `create_rules` / `import_rules` still do not log; the route still `logger.error`s only the top-level catch.
      - Disable Task Manager failures still appear only in Alerting logs, not Security import logs. Same gap as skipped Risk 2, not a new log regression.
      - Change-history audit still writes through Alerting bulk APIs (the extra `rule_enable` item is activity 4, not a missing audit).

18. **Dropped Risk 3.** Alerting already 400s `batchSize > 500` on `bulkUpdateRules` / `bulkCreateRules`. A non-route caller passing a huge `rules` array with `batchSize` still at 200 could theoretically hit the KQL clause floor, but that is an edge case on an edge case and not worth tracking. Answered the DRC batch-cap open question: leave it route-only.

19. **Answered reviewer comments on the PR (2026-09-24 → 09-30).** This led to approvals from @adcoelho (09-25) and @dhurley14 (09-30).
    - **Libra, medium: legacy `scheduledTaskId` breaks bulk enable** ([thread](https://github.com/elastic/kibana/pull/291560#discussion_r4095981108)). First reply gave a plain-language explanation plus history ([#117397](https://github.com/elastic/kibana/pull/117397), [#139826](https://github.com/elastic/kibana/pull/139826), [#174656](https://github.com/elastic/kibana/pull/174656), [#213736](https://github.com/elastic/kibana/issues/213736)). After digging further: it doesn't affect import, because only disabled rules get bulk-enabled and disabling clears legacy task IDs. The underlying bug is worse on `main` (bulk-enabling an already-enabled legacy rule stops it running). Reproduced locally with [`repro-bulk-enable-legacy-task-id.sh`](https://github.com/sdesalas/kibana-knowledge/blob/main/scripts/repro-bulk-enable-legacy-task-id.sh) and filed for ResponseOps as [#294458](https://github.com/elastic/kibana/issues/294458).
    - **@banderror: asked for APM span screenshots and the drop in ES requests** ([comment](https://github.com/elastic/kibana/pull/291560#issuecomment-5816327838)). Posted an APM breakdown for 1,000 rules (overwrite + enable): 14s on the branch vs 73s on `main`. Also flagged duplicate spans on `main`'s overwrite path. ES calls drop from 2,891 to 277 (about 90%) once bulk API key grants land ([elasticsearch#157410](https://github.com/elastic/elasticsearch/pull/157410)); until then, key minting is still about 2,000 calls.
    - **@dhurley14, general: `for` loops vs `pMap` / `Promise.all`, and functional style.** Replied that it's the right tool per job: `Promise.all` for independent fetches, `pMap` inside the bulk APIs to throttle API key minting, and `for…of` where order matters. Pointed out the only functional code removed was the old per-rule `pMap`, and included a pattern-count table from `main`. 🚀 reaction, then approval.
    - **@dhurley14, `route.ts:113`: move file validation before client setup.** Accepted; done in `b42f9fbc`.
    - **@dhurley14, `route.ts:213`: `Promise.all(chunk(...))` for the batch loop.** Declined. Batches must run one at a time to avoid OOM and stacking the throttled API key minting (×5 for 1K rules, ×50 for 10K).
    - **@dhurley14, `overwrite_rules.ts:58`: `Promise.all` for the prep loop.** Declined. It's CPU-only work now (prefetched assets), and `Promise.all` would add plumbing, move the try/catch into callbacks, and risk ordering changes on shared arrays if I/O comes back later. Offered to switch if he felt strongly; he didn't.
    - **@adcoelho, nit: import `RulesClientContext` and `BulkOperationError` from the same module** (`utils.test.ts`). Done in `b42f9fbc`. He also thanked me for the leftover `bulkUpdateRules` coverage carried over from [#286508](https://github.com/elastic/kibana/pull/286508#discussion_r3861610519).
    - **Libra, P3: the multi-batch route test doesn't check aggregated results** (`route.test.ts:239`). Done in `1db027e`.
    - **Libra, P3: losing `update()`'s decryption fallback** (`overwrite_rules.ts:122`). Rebutted with 👎. The decrypted PIT finder returns the SO with secrets stripped and an `error` set instead of throwing, so the rule gets a fresh key and the old key is orphaned, same as the fallback. Backed up with a local unit test.
    - **Leftover feedback from [#280553](https://github.com/elastic/kibana/pull/280553#discussion_r3659153286):** missing `file` now returns 400 instead of 500 (`6ce2be7`), with the FTR assertion updated.

20. **Final full review from scratch on head `1db027e` (2026-10-01).** Re-read the live PR description, all inline review threads, and the full `upstream/main...HEAD` diff (17 files, merge base `9ecd728`). The PR is now ready for review, approved by @adcoelho and @dhurley14. That makes the "still a draft" status in activity 5 out of date.
    - **Status changes:** Risk 5 accepted and Risk 7 discarded per the author's decision. The legacy `scheduledTaskId` open question was closed with Risk 7.
    - **New:** Risks 9–13 (missing-secrets overwrite, bulk-enable schedule limit, swallowed legacy-actions migration, audit action rename, CI flake on retry).
    - **Checked and fine:**
      - A missing `enabled` field defaults the same way: both `main` (`applyRuleUpdate`) and the PR use `rule.enabled ?? existingRule.enabled`.
      - API key behavior on disabled→enabled matches single `enableRule()`. Bulk update clears and invalidates the disabled rule's key, then bulk enable mints a new one.
      - Old-key invalidation still respects `apiKeyCreatedByUser`.
      - `exitEarlyOnError` defaults to `false`.
      - Bulk update writes use OCC `version` with conflict retry, like `update()`.
      - Change-history logging is wrapped in try/catch, so it can't reject after the write.
      - The DRC `importRules` wrapper can't throw past its inner catch, so a later route chunk can't 500 the request after earlier chunks persisted.
      - `matchingAsset: null` is only passed by import.
      - The PR-description claims (500→400 for a missing file, shared 200 batch size, schedule-limit and disable-reporting risks) match the code.
    - **Libra decryption comment:** the author's rebuttal holds. The decrypted PIT finder returns the SO with secrets stripped instead of throwing, so the old key is orphaned the same way as `update()`'s `getRuleSo` fallback.

