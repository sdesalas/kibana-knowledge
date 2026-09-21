# PR Review: #291433 — [Security Solution] Trigger telemetry task via runSoon in launchTask

**PR:** [elastic/kibana#291433](https://github.com/elastic/kibana/pull/291433) by @kibanamachine
**Created Date: 2026-09-18**

**Scale:** Small. One FTR helper, ~10 lines of real change. The interesting part is the timing of the `taskHasRun` threshold, not the size of the diff.

Related: [issue #273859](https://github.com/elastic/kibana/issues/273859), [investigator comment](https://github.com/elastic/kibana/issues/273859#issuecomment-5697967081), [flake runner #14406](https://buildkite.com/elastic/kibana-flaky-test-suite-runner/builds/14406) (30/30 ESS + 30/30 Serverless).

---

### Context / Motivation

The telemetry FTR case `indices metadata should publish data stream events` burned the full 360s Mocha budget. The task ran and published once; the poll never saw a second run.

The [Failed Test Investigator](https://github.com/elastic/kibana/issues/273859#issuecomment-5697967081) pinned it on `launchTask` hand-writing the task saved object while Task Manager was finishing the same run:

> The helper's direct rewrite of the task saved object collided with Task Manager's own reschedule (a logged version conflict), so the `should publish data stream events` case burns the full 360 s Mocha budget.

Proposed fix: stop writing the task doc and call `POST /internal/ftr/task_manager/{taskId}/run_soon` instead. The investigator also said to capture the `taskHasRun` threshold *before* `runSoon`. This PR takes the route change and flips that last part — threshold is captured *after* `runSoon` returns.

### Validating the issue — does this PR address it?

The concern is technically valid. The PR addresses the collision correctly.

- **Where the problem manifests:** old `launchTask` did `savedObjects.get` + `savedObjects.update` and overwrote `runAt` / `scheduledAt` / `status: Idle`. That write raced Task Manager's post-run reschedule. TM logged `Skipping resolving task document version conflict after task run` and abandoned the +24h reschedule. `taskHasRun` needs `runAt > after` where `after` *was* that written `runAt`, so it could never become true.
- **Why the old approach was a problem:** two writers on the same task SO. The test itself was the other writer.
- **How the PR fixes it:** `taskManager.runSoon` refuses to overwrite `Claiming` / `Running`, and treats 409 as a non-throwing `{ conflict: true }`. The helper no longer stomps the doc mid-run.
- **Residual caveat:** the FTR `run_soon` route always returns HTTP 200 and puts failures in `body.error`. This helper ignores the body. A "already running" / other failure looks like a successful launch.

### Summary

`launchTask` now triggers the shared telemetry tasks through Task Manager's supported `runSoon` path instead of rewriting the task saved object. Call sites in `indices_metadata.ts` and `ingest_pipeline_stats.ts` stay the same. Unused `delayMillis` is dropped. Stated intent matches the diff. The after-vs-before threshold change is a real refinement, not scope creep.

### Files touched

- `x-pack/solutions/security/test/security_solution_api_integration/config/services/detections_response/tasks/task_manager.ts` — shared FTR helper used by both telemetry task suites. `taskHasRun` is unchanged.

### Flow trace

1. A telemetry test calls `launchTask('security:indices-metadata-telemetry:1.0.0', kibanaServer, logger)` (or the ingest-pipeline equivalent).
2. Helper POSTs `/internal/ftr/task_manager/{taskId}/run_soon` via the same `KbnClient` that already talks to `ftr_apis` for saved-object helpers.
3. `taskScheduling.runSoon` loads the task, bails if `Claiming`/`Running` (unless `force`), otherwise sets `status: Idle` and `runAt`/`scheduledAt` to now. A 409 is swallowed and returned as `{ conflict: true }`.
4. Helper captures `after = new Date()` *after* that returns, then hands it back.
5. The test's `waitFor` loops on `taskHasRun(taskId, kbn, after) && events.length > 0` (ingest-pipeline first case is `hasRun && eventCount >= 0`).
6. `taskHasRun` is `runAt > after && status === Idle`. Immediately after `runSoon`, `runAt` is "now" and is not greater than `after`, so the poll stays false until TM finishes the run and reschedules to `now + 24h`.

### Assumptions

- `ftr_apis` is enabled in these FTR configs and `kibanaServer` already has `ftrApis`. Reasonable — the old helper already used `kbn.savedObjects.*`, which is the same plugin.
- `runSoon` returns before the task is claimed. TM poll interval in this suite is 1s (`--xpack.task_manager.poll_interval=1000`), so the post-call `after` timestamp should land before the real run.
- Callers set `fromTimestamp` *after* `launchTask` returns. Events published during the HTTP round-trip would be missed. Unlikely with a 1s poll; 30/30 flake runs didn't hit it.
- Neither caller passed `delayMillis`, so dropping it is safe.

### Risks

1. **Silent no-op if `runSoon` fails.** The FTR route never 4xxs on `TaskAlreadyRunningError` or a thrown `runSoon` failure — it returns 200 with `{ id, error }`. The in-repo Scout helper (`alerting_v2` `task_manager_service.ts`) already promotes `body.error` to a throw. This helper does not. If the task is still `Running` from Kibana startup (5m timeout on a 24h job), `launchTask` returns a threshold, the in-flight run then reschedules +24h, `taskHasRun` becomes true, and the test's filtered events may never show up. Why this is risky: the original flake was "poll forever"; this can recreate that in a narrower window, just via a different path.

2. **409 `{ conflict: true }` is also treated as success.** `runSoon` does not throw on 409. Same outcome as (1): helper thinks it launched, TM may not have taken the write.

### Open questions

- Should `launchTask` inspect the response the way the Scout `runSoon` wrapper does, and throw (or retry after Idle) when `error` / `conflict` is set?
- If the first test in the file can overlap the startup run, do we want a "wait until not Running, then `runSoon`" instead of a fire-and-forget POST?

### Notes for your codebase map

- Security telemetry daily tasks (`security:indices-metadata-telemetry`, `security:ingest-pipelines-stats-telemetry`) are 24h TM tasks. Tests force a run instead of waiting a day.
- `taskHasRun` does not mean "the task executed." It means "Idle again, and `runAt` moved past our threshold" — i.e. the post-run reschedule landed.
- `POST /internal/ftr/task_manager/{taskId}/run_soon` is the supported FTR/Scout trigger. It always HTTP 200; failures live in `body.error`.
- Direct task-SO writes from tests race TM. Don't do that.

### Follow-up Review Activities

1. Checked PR comments and whether the 30/30 flake runs covered the relevant FTRs.

- No human review comments. Only bots: flake-verifier `/flaky` trigger, 30× ESS + 30× Serverless, backport-label note, and an unrelated PR-CI flake (`serverless search Console Notebooks`).
- `launchTask` has exactly two call sites: `indices_metadata.ts` (10 tests) and `ingest_pipeline_stats.ts` (2 tests). Both are loaded by `telemetry/index.ts`. Those are the only two telemetry FTR configs in CI (`ess.config.ts`, `serverless.config.ts`).
- The flake runner ran those full configs (`ftrConfig:…:30`, no `FTR_EXTRA_ARGS` / mocha grep). Each job is one full suite pass. So ingest-pipeline and the ESS-only ILM/settings/templates cases ran too — not just `should publish data stream events`. The verifier comment undersells that.
- Serverless correctly skips the `skipServerless` block (7 indices-metadata tests + endpoint). Endpoint does not use `launchTask`.
- Nothing missing for `main`. The original first failure was `kibana-elasticsearch-snapshot-verify` on `8.19`; that lane was not re-run, and `8.19` is excluded from backport because `run_soon` does not exist there. The later `kibana-on-merge` failure was on regular ES, which is what the flake runner used.
