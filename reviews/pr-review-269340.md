# PR #269340 Review: `rulesClient.bulkCreateRules()`

**Scale:** Substantive PR. ~2,085 lines across 14 files, new bulk creation method in the alerting framework with batching, error isolation, cleanup, and a behavioral change to task manager jitter.

**Branch:** `bulk-create-enable-alert-rules-feedback`
**Author:** @sdesalas
**Closes:** #264893, #253742
**Relates to:** #264890 (epic), #271722 (security-solution wiring) 

## Summary

Adds `rulesClient.bulkCreateRules()` — a batched rule creation method that handles both disabled and enabled rules in a single call. The method splits work into two phases: (A) upfront in-memory validation, authorization, and schedule-limit checks, then (B) per-batch ES writes (API key minting, task scheduling, SO persistence) with best-effort cleanup on failure.

Also changes task manager jitter behavior: previously the first task in a `bulkSchedule`/`bulkEnable` call ran immediately and the rest were jittered; now a single task runs immediately, but when there are multiple tasks ALL of them are jittered.

The method is not wired to any caller yet, so there is zero production impact at this point.

## Files touched

### New bulk create module (`application/rule/methods/bulk_create/`)

| File | Role |
|---|---|
| `bulk_create_rules.ts` | Main orchestrator — `preValidate` (phases A1–A3) and `runBatch` (phases B1–B3) |
| `utils.ts` | `prepareRule` (action validation, API key minting, SO attribute construction) and `invalidateKeys` |
| `types.ts` | `BulkCreateRulesParams`, `BulkCreateRulesResult`, `PreparedRule`, `ApiKeyEntry`, etc. |
| `index.ts` | Barrel exports |

### Wiring

| File | Change |
|---|---|
| `rules_client.ts` | Adds `bulkCreateRules` method to `RulesClient` |
| `rules_client.mock.ts` | Adds mock |
| `server/index.ts` | Re-exports new types |

### Shared utilities

| File | Change |
|---|---|
| `schedule_task.ts` | Extracts `buildTaskInstance` from `scheduleTask`, adds `bulkScheduleTask`. Existing `scheduleTask` now delegates to `buildTaskInstance`. |
| `rules_client/lib/index.ts` | Exports `bulkScheduleTask`, `buildTaskInstance` |
| `rules_client/common/constants.ts` | Adds `MIN_BULK_CREATE_BATCH_SIZE` (10), `DEFAULT_BULK_CREATE_BATCH_SIZE` (100), `MAX_BULK_CREATE_BATCH_SIZE` (500) |
| `rule_circuit_breaker_error_message.ts` | Adds `'bulkCreate'` to the circuit breaker action union |

### Task manager jitter

| File | Change |
|---|---|
| `task_scheduling.ts` | Changes `bulkSchedule` and `bulkEnable`: single task = immediate, multiple tasks = ALL jittered |
| `task_scheduling.test.ts` | Updates tests to match new jitter behavior |

### Tests

| File | Coverage |
|---|---|
| `bulk_create_rules.test.ts` | 42 test cases across happy paths, input validation, batching, all 6 phases (A1–A3, B1–B3), audit events, exitEarlyOnError, change tracking |

## Flow trace

The most important path: creating a mix of enabled and disabled rules with default (best-effort) error handling.

1. **`bulkCreateRules`** validates input size and batch size, then assigns IDs (caller-supplied or generated).
2. **A1 `preValidate.checkInMemory`** — iterates all rules sequentially: generates action UUIDs, validates schema, checks rule type registry, validates params, checks interval constraints. Failures are per-rule errors; survivors continue.
3. **A2 `preValidate.bulkEnsureAuthorized`** — collects deduped `(ruleTypeId, consumer)` pairs from survivors, calls `authorization.bulkEnsureAuthorized` once. Throws 403 on any unauthorized pair (whole-request failure).
4. **A3 `preValidate.validateScheduleLimit`** — circuit breaker check across all enabled survivors' intervals. Throws 400 if the global runs-per-minute ceiling would be exceeded.
5. **B1 `runBatch.pMap.prepareRule`** — for each batch member concurrently (capped at `API_KEY_GENERATE_CONCURRENCY = 50`): validates actions, validates system actions, mints API key (if enabled), extracts references, builds SO attributes. Failures are per-rule errors.
6. **B2 `runBatch.bulkScheduleTask`** — calls `taskManager.bulkSchedule` for the enabled subset. Tasks are created with `enabled: true` and no `runAt`/`scheduledAt` (jitter is added inside `TaskScheduling.bulkSchedule`). Silent per-task drops are detected by diffing requested vs returned. On whole-call throw, all enabled rules are excluded from the batch.
7. **B3 `runBatch.bulkCreateRulesSo`** — `unsecuredSavedObjectsClient.bulkCreate` for survivors. Per-row 409s are handled individually (API key invalidation + task cleanup). Whole-call throw triggers best-effort `bulkRemove` and key invalidation.
8. **Change tracking** — `logRuleChanges` is called for successfully persisted SOs.

## Assumptions

- **`buildTaskInstance` uses `id: opts.id`** — same ID for rule and task. This means `scheduledTaskId` can be set on the rule attributes during `prepareRule` without needing a round-trip, unlike `createRuleSavedObject` which does an extra `updateRuleSo` call after scheduling. This is a deliberate simplification that works because the alerting framework convention is task-id === rule-id.

- **Tasks are created before rule SOs** (B2 before B3). If SO persistence fails in B3, dangling tasks are cleaned up via `bulkRemove`. This ordering is intentional per ResponseOps feedback: "Create the tasks as enabled, and then the rules as enabled." The single-rule path does the opposite (SO first, then task), so this is a design divergence.

- **`addGeneratedActionValues` is called twice per rule** — once in A1 (preValidate) and again in B1 (prepareRule). The A1 result is discarded after schema validation. The B1 call produces the final values that are persisted. This is wasteful but not a correctness issue because the generated UUIDs are ephemeral action identifiers.

- **`bulkMarkApiKeysForInvalidation` swallows its own SO errors** (try/catch around the inner `bulkCreate`). However, it could still throw if the key-parsing logic before the try/catch fails. The comment in `utils.ts:172` ("logs errors internally, never throws") is slightly misleading, though in practice the parsing is safe for well-formed base64 keys.

- **Jitter behavior change applies globally** — the `bulkSchedule` and `bulkEnable` modifications affect ALL callers, not just `bulkCreateRules`. Any existing code that calls `bulkSchedule` with 2+ tasks will now see all tasks jittered instead of the first one running immediately. The PR description mentions a separate PR (#269991) for this, but the change is included in this branch too.

- **`validateScheduleLimit` queries all namespaces** — the circuit breaker is global, not per-space. A space with low rule density could be blocked by another space's rules consuming the global quota.

## Risks (reassessed)

### 1. Task manager jitter — LOW, arguably desirable

**Initial concern:** Changing jitter behavior in `bulkSchedule`/`bulkEnable` (from "first runs now, rest jittered" to "all jittered when >1") affects all callers, not just `bulkCreateRules`.

**After digging in:** The blast radius is narrow. Tracing all callers:

- **`enable_rule.ts`** — calls `bulkEnable([singleId])`. Single task = immediate. **Unaffected.**
- **`bulk_enable_rules.ts`** — calls `bulkEnable(taskIds)` with potentially multiple IDs. These tasks are rules being re-enabled; all of them now get jittered instead of the first firing immediately. This is actually the *intended* behavior per issue #195136's DoD: "When bulkSchedule API is called with more than one task, we schedule the tasks with a randomized runAt."
- **`backfill_client.ts`** — calls `bulkSchedule` with ad-hoc tasks (no `schedule.interval`). `addJitter` returns `new Date()` for tasks without an interval. **Unaffected.**
- **`bulk_enable_rules.ts`** — also calls `bulkSchedule` for tasks that need creation (new tasks for previously-missing scheduled tasks). These are recurring tasks and would now be jittered. Same reasoning as `bulkEnable` — desirable for load distribution.

The PR author acknowledged in the comments: "Is this change necessary for this PR? No its not. Just a related improvement that could be added in. Happy to remove if deemed too risky." So it's a conscious inclusion, not an accident.

**Verdict:** Not risky. The change correctly implements #195136's DoD. The only question is whether it belongs in this PR or the separate #269991.

### 2. exitEarlyOnError + B2 cleanup — NOT A BUG, by design

**Initial concern:** When `exitEarlyOnError = true` and one task is silently dropped in B2, the successfully-scheduled tasks are cleaned up via `bulkRemove`.

**After digging in:** This is exactly what strict mode should do. The `exitEarlyOnError` flag exists to give callers (like rule import) an all-or-nothing guarantee. If any rule in the batch can't be fully created (including its task), the entire batch is rolled back. The test `Phase B2 silent per-task drop: aborts batch and removes the partially scheduled tasks` explicitly validates this contract.

Best-effort mode (the default) handles this differently — it skips the failed rule and persists the rest, which is what prebuilt rule installation needs.

**Verdict:** Not a risk. Intentional design.

### 3. `invalidateKeys` throwing — NOT A PRACTICAL RISK

**Initial concern:** The comment in `utils.ts:172` says `bulkMarkApiKeysForInvalidation` "logs errors internally, never throws," but the test `bulkMarkApiKeysForInvalidation failure: error propagates when key invalidation rejects` mocks it to throw and confirms the error propagates.

**After digging in:** Looking at the actual `bulkMarkApiKeysForInvalidation` implementation, the internal try/catch wraps `savedObjectsClient.bulkCreate`. The only code outside that try/catch is `Buffer.from(key, 'base64').toString().split(':')` and `isUiamCredential(apiKey)` — both of which are simple string operations that effectively can't throw.

The test mocks the *entire function* to reject, which tests `invalidateKeys`'s behavior when its dependency fails. That's good defensive testing, but the scenario is effectively unreachable in production.

**Verdict:** The comment is practically accurate. The test covers a theoretical edge case. No real risk.

### 4. Dangling API key on `prepareRule` failure — REAL, LOW SEVERITY

**Initial concern:** (Not in original review — surfaced by CodeRabbit bot and confirmed by deeper analysis.)

**The issue:** In `utils.ts`, when `prepareRule` creates an API key for an enabled rule (line 71–82) and then a *subsequent* step fails (e.g., `extractReferences`, `transformRuleDomainToRuleAttributes`), the catch block at line 151 does `apiKeys.delete(id)`. This removes the key from the batch tracking map, so no batch-level cleanup (`invalidateKeys`) will ever touch it. The key was created in Elasticsearch but is never invalidated.

The test "prepareRule failure after API key creation removes key from map (no dangling keys)" has a misleading title — it asserts `bulkMarkApiKeysForInvalidation` is NOT called, which means the key IS dangling.

The reviewer (@cnasikas) asked for this `delete` call but also said: "Let's be sure that these keys are invalidated/flushed correctly." The `delete` prevents the key from being used by the rule (good), but also prevents it from being cleaned up (bad). The fix would be to either:
1. Remove the `apiKeys.delete(id)` so batch cleanup handles it, or
2. Keep the delete but also call `invalidateKeys` for the single key in the catch block.

**Practical impact:** Low. The dangling key is a one-off key for a rule that failed to create. It has no associated rule or task so it can't be used maliciously. Elasticsearch API keys have a configurable TTL, and the alerting framework has a background API key cleanup process. But it's still a correctness issue.

**Verdict:** Worth fixing. Minor code change.

## Open questions (reassessed)

### 1. Task manager jitter — should it be in a separate PR?

The author's PR comment says: "Just a related improvement that could be added in. Happy to remove if deemed too risky." And references #269991 as a separate PR for the same change. Worth confirming whether #269991 is still open or already merged — if it's merged, these changes would be a no-op merge conflict.

### 2. `addGeneratedActionValues` double-call — resolved by PR discussion

The reviewer (@cnasikas) raised this as a nit, suggesting the A1 results be carried through to avoid the second call in B1. The author provided a [memory impact estimation](https://github.com/sdesalas/kibana-knowledge/blob/main/reports/bulk-create-rules/bulk-create-dedup-action-values-memory.md) showing the extra memory from carrying enriched data through the pipeline outweighs the cost of the redundant call. The reviewer accepted: "Good point, ok let's leave it as it is." **Resolved — not a concern.**

### 3. `batchSize` JSDoc — minor doc drift

`types.ts` line 51 says "clamped to [1, MAX_BULK_CREATE_BATCH_SIZE]" but actual validation rejects below `MIN_BULK_CREATE_BATCH_SIZE` (10). Trivial fix: update the comment.

### 4. Still-open reviewer comment (`r3409479581`)

The reviewer suggested removing `as unknown as RuleDomain<Params>` at `utils.ts:164`. The author replied "Applied in e68dd7e" — but the handoff doc from later the same day flags it as still TODO. Looking at the current code (utils.ts line 131), the cast is gone — the `rule` object is passed as a plain object literal without the `as unknown as RuleDomain<Params>` cast. **Resolved.**

## Notes for your codebase map

- **`rulesClient` is the main gateway** for rule CRUD. Methods like `bulkCreateRules`, `bulkDeleteRules`, `bulkEnableRules` all follow a similar pattern: delegate to standalone functions that take a `RulesClientContext`.
- **Task ID === Rule ID** is a convention in the alerting framework. `buildTaskInstance` in `schedule_task.ts` makes this explicit.
- **API key lifecycle is tightly coupled to rule lifecycle.** Keys are minted during rule creation, stored as base64 on the SO, and invalidated via `bulkMarkApiKeysForInvalidation` (writes "pending invalidation" SOs that a background cleanup process handles).
- **Phase A/B split pattern** — upfront cheap validation before any ES calls, then batched writes. This is a response to feedback from ResponseOps and is likely the pattern future bulk methods should follow.
- **`exitEarlyOnError` gives callers control over strictness.** Best-effort (default) skips bad rules and continues; strict aborts on first error with cleanup. Detection rules use best-effort for prebuilt installs, strict for import.
- **`addJitter` in task scheduling** uses `Math.min(interval, 5 min)` as the jitter window. Adhoc tasks (no `schedule.interval`) always run immediately regardless of jitter settings.
