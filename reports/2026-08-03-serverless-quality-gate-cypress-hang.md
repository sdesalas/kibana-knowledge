# Serverless Quality Gate Cypress — step hangs ~5h after empty suite exit

**Date:** 2026-08-03
**Scope:** `kibana-serverless-security-solution-quality-gate-*` Cypress / MKI steps
**Repo HEAD checked:** current `main` (post-pull, ~2026-08-03)

**Failing example (detection-engine Quality Gate, empty suite):**
https://buildkite.com/elastic/kibana-serverless-security-solution-quality-gate-detection-engine/builds/5008#019fc55d-3dd1-4725-a17d-e7aca34c472b/L319

**Passing controls (specs actually ran):**
- rule-management: https://buildkite.com/elastic/kibana-serverless-security-solution-quality-gate-rule-management/builds/5054#019fc55d-1a2f-4059-ac42-e6a431d11ef8/L428
- defend-workflows: also passing (same `parallel_serverless` runner, management Cypress config)

**Pattern:** pass when the runner finds specs; hang when it hits the empty-suite
early-exit. Hanging slugs: detection-engine, investigations, entity-analytics,
explore, gen-ai.

---

## TL;DR

When Cypress MKI finds no specs to run (normal for many `@serverlessQA` suites),
the runner logs `No tests found` and should exit immediately. Instead the
Buildkite step sits idle until `timeout_in_minutes: 300` fires
(`signal: terminated`). That turns a cheap no-op into a red, agent-burning
timeout.

Empty suites are **not** the bug — `@serverlessQA` is opt-in so suites without
that tag don't block serverless promotion. The bug is that the step does not
terminate after the early-exit path.

**Pass vs fail on current `main` (QG filter = `@serverlessQA`, excluding skip tags):**

| Suite | `@serverlessQA` survivors | Outcome |
|---|---:|---|
| rule-management | 3 | passes (runs Cypress) |
| defend-workflows (`management/cypress`) | 6 | passes |
| detection-engine | 0 | hang after `No tests found` |
| investigations | 0 | hang (same pattern) |
| entity-analytics | 0 | hang |
| explore | 0 | hang |
| gen-ai (`ai_assistant`) | 0 | hang |

Defend-workflows is not a different escape hatch — it still uses
`start_cypress_parallel_serverless`; it just still has tagged specs, so it never
takes the early-exit path.

---

## Evidence

From [detection-engine build 5008](https://buildkite.com/elastic/kibana-serverless-security-solution-quality-gate-detection-engine/builds/5008#019fc55d-3dd1-4725-a17d-e7aca34c472b/L319):

```
2026-08-03 04:07:51 CEST
 info [cy.parallel(svl)] Config spec pattern: ./cypress/e2e/**/*.cy.ts
2026-08-03 04:07:51 CEST
 info [cy.parallel(svl)] Arguments spec pattern: ./cypress/e2e/detection_response/detection_engine/**/*.cy.ts
2026-08-03 04:07:51 CEST
 info [cy.parallel(svl)] Resulting spec pattern: ./cypress/e2e/detection_response/detection_engine/**/*.cy.ts
2026-08-03 04:07:51 CEST
@cypress/grep: filtering using tag(s) "@serverlessQA --@skipInServerless --@skipInServerlessMKI"
2026-08-03 04:07:51 CEST
@cypress/grep: will omit filtered tests
2026-08-03 04:07:52 CEST
grep and/or grepTags has eliminated all specs
2026-08-03 04:07:52 CEST
grepTags: @serverlessQA --@skipInServerless --@skipInServerlessMKI
2026-08-03 04:07:52 CEST
Will leave all specs to run to filter at run-time
2026-08-03 04:07:52 CEST
 info [cy.parallel(svl)] Resolved spec files or pattern after grep: ./cypress/e2e/detection_response/detection_engine/**/*.cy.ts
2026-08-03 04:07:52 CEST
 info [cy.parallel(svl)] No tests found - all tests could have been skipped via Cypress tags
2026-08-03 09:06:23 CEST
# Received cancellation signal, interrupting
2026-08-03 09:06:23 CEST
🚨 Error: The command was interrupted by a signal: signal: terminated
```

Last app log at **04:07:52**, SIGTERM at **09:06:23**. Step config is
`timeout_in_minutes: 300` (clock starts at step start, which includes bootstrap
before these lines — so ~04:06 start → ~09:06 timeout fits).

No further log output between "No tests found" and the cancel (no
`---` Upload Artifacts, no junit noise). So the Buildkite *command* never
finished — hang is before post-command.

### Control: rule-management completes when specs run

From [rule-management build 5054](https://buildkite.com/elastic/kibana-serverless-security-solution-quality-gate-rule-management/builds/5054#019fc55d-1a2f-4059-ac42-e6a431d11ef8/L428)
(tags `@serverless …` — periodic-style filter; project was created and Cypress
ran). Note: Cypress's own runtime grep may still print "eliminated all specs /
filter at run-time" — that is **not** the parallel_serverless early-exit path
(no `cy.parallel(svl) No tests found` line).

```
2026-08-03 04:12:22 CEST
 debg Creating new cloud SAML session for role 'admin'
2026-08-03 04:12:22 CEST
 debg Fetching Kibana version from https://kibana-cypress-security-solution-ephemeral-…/api/status
2026-08-03 04:12:22 CEST
@cypress/grep: filtering using tag(s) "@serverless --@skipInServerless --@skipInServerlessMKI"
…
2026-08-03 04:12:22 CEST
Will leave all specs to run to filter at run-time
2026-08-03 04:12:23 CEST
 info Reading cloud user credentials from …/.ftr/sec-sol-auto-06.json
2026-08-03 04:12:24 CEST
  (Run Starting)
… (run details) …
2026-08-03 04:20:45 CEST
Done in 811.94s.
2026-08-03 04:20:46 CEST
yarn run v1.22.22
$ … mochawesome-merge … && … marge … && yarn junit:transform && …
✓ Reports saved:
…/target/kibana-security-solution/cypress/results/output.html
…
2026-08-03 04:20:47 CEST
 succ task complete
2026-08-03 04:20:47 CEST
Done in 1.27s.
```

So when the runner proceeds into a real Cypress run: yarn returns, `junit:merge`
succeeds in ~1s, step finishes. The hang is specific to the empty-suite
early-exit path (`No tests found` → supposed `process.exit(0)`), not to the
wrapper/junit path in general.

Defend-workflows is a second non-empty control: QG/periodic Cypress via
`edr_workflows/mki_security_solution_defend_workflows.sh` →
`yarn cypress:dw:qa:serverless:run` (same `parallel_serverless`, config under
`public/management/cypress/`). Also completes; also has `@serverlessQA` specs.

---

## Expected path (empty suite)

Quality Gate sets `KIBANA_MKI_QUALITY_GATE=1`, which switches grep tags to
`@serverlessQA --@skipInServerless --@skipInServerlessMKI`
(`parallel_serverless.ts`). Suites without `@serverlessQA` specs are filtered
to empty on purpose.

When grep eliminates all specs and `grepFilterSpecs` is true:

```ts
// parallel_serverless.ts
if (grepFilterSpecs && isGrepReturnedSpecPattern) {
  log.info('No tests found - all tests could have been skipped via Cypress tags');
  return process.exit(0);
}
```

That log line is the last thing before `process.exit(0)`.

Wrapper (`mki_security_solution_cypress.sh`) after yarn returns:

1. `yarn junit:merge || :` — with no mochawesome files, `mochawesome-merge`
   fails immediately (`Pattern … matched no report files`); `|| :` swallows it
2. `exit "$status"` — should be 0 → step green

---

## Actual path

After "No tests found" the job stays "running" until the 300m timeout, then
Buildkite cancels → `signal: terminated` → step fails red.

Observed on empty-suite jobs (detection-engine, investigations, entity-analytics,
explore, gen-ai). Rule-management + defend-workflows show the non-empty path
exits cleanly — so the early-exit path is implicated, not a general MKI Cypress /
agent failure.

---

## What we know / don't know

| Layer | Finding |
|---|---|
| Early-exit code | Present; failing log proves we enter the `if` that calls `process.exit(0)` next |
| Control (non-empty) | Rule-management: project + Cypress (~812s) + `junit:merge` (~1s). Defend-workflows: also passes via same runner with management Cypress specs |
| Pattern | Suites with `@serverlessQA` survivors pass; suites with zero survivors hit early-exit and hang |
| Entry point | Fire-and-forget: `start_cypress_parallel_serverless.js` calls `cli()` which calls `run(...)` **without await**. Process lifetime relies on `process.exit` actually terminating |
| `@kbn/dev-cli-runner` | Does not stub `process.exit`. Outer `run()` wraps the fn in `withProcRunner`; ProcRunner registers `exit-hook` for teardown (sync hook firing async teardown — shouldn't block `process.exit`) |
| `junit:merge` | Works after a real run; on empty results fails fast locally (`matched no report files`) — not a multi-hour hang candidate **if yarn returns** |
| Post-command | Only runs after the command finishes; never reached on the hanging jobs (no Upload Artifacts heading) |
| Bootstrap / vault | Finish *before* the runner log lines |

Open: why the step is still alive for ~5h after a line that sits immediately
before `process.exit(0)`. Possibilities (unproven):

1. Node/`process.exit(0)` not ending the process tree (open handle, weird
   child, yarn waiting on process group) — most plausible given the control
2. Yarn never returns, so we never reach `junit:merge` / `exit`
3. Agent/job tracking oddity after the script should have finished (less likely
   given the control finishes normally on the same pipeline family)

Cheapest next check: breadcrumbs in the shell wrapper (see follow-ups).

---

## Pipeline context (for orientation)

Same Buildkite pipeline slug forks on `KIBANA_MKI_QUALITY_GATE`:

| Mode | Trigger | Pipeline upload |
|---|---|---|
| **Quality Gate** | Serverless release (`KIBANA_MKI_QUALITY_GATE=1`) | `mki_quality_gate/*.yml` |
| **Periodic** | Cron / schedules (not defined in this repo) | `mki_periodic/*.yml` |

Build messages like "Monitoring - Run tests" are likely another schedule hitting
the periodic branch (schedules live Buildkite-side; not verified from repo).

Empty Cypress under `@serverlessQA` is expected promotion-safety behavior.
Periodic filters with `@serverless` and can still run real suites. The broken
part is non-exit on the empty path.

---

## Impact

1. Empty Cypress steps fail red after ~5h instead of exiting green in seconds.
2. Burns a full agent slot (~5h) per affected step, every scheduled / gated run.
3. Noise looks like infra flake / timeout, obscures real failures.

---

## Suggested follow-ups

1. **Breadcrumbs first (localize the hang):** add echoes in
   `mki_security_solution_cypress.sh` after `yarn $1` and after `yarn junit:merge`,
   e.g. `echo "--- yarn finished status=$status"` / `echo "--- junit:merge done"`.
   Re-run one empty suite (e.g. detection-engine QG). Whichever marker never
   appears is where it's stuck. Expectation from the control: on success both
   markers appear; on hang, neither should if Node never exits.
2. **If hung in Node:** inspect agent processes/FDs while stuck; remember
   `cli()` doesn't await `run()` — any fix that removes `process.exit` must
   `await run(...)` at the top level and still force process exit, or the event
   loop can keep the process alive (cypress import, fetch, ci-stats, etc.).
3. **Lower blast radius while investigating:** temporarily lower
   `timeout_in_minutes` on these Cypress steps so hangs fail in minutes, not
   hours.
4. **Owner:** security-engineering-productivity / appex-qa + MKI Cypress runner
   (`parallel_serverless.ts`).

---

## Key files

- `x-pack/solutions/security/plugins/security_solution/scripts/start_cypress_parallel_serverless.js` — fire-and-forget `cli()`
- `x-pack/solutions/security/plugins/security_solution/scripts/run_cypress/parallel_serverless.ts` — early exit
- `.buildkite/scripts/pipelines/security_solution_quality_gate/security_solution_cypress/mki_security_solution_cypress.sh` — step command (most suites)
- `.buildkite/scripts/pipelines/security_solution_quality_gate/edr_workflows/mki_security_solution_defend_workflows.sh` — defend-workflows step (same runner, different cwd/script)
- `.buildkite/pipelines/security_solution_quality_gate/mki_quality_gate/` / `mki_periodic/` — step defs (`timeout_in_minutes: 300`)
- `.buildkite/scripts/lifecycle/post_command.sh` — post-command (not reached during hang)
- `x-pack/solutions/security/test/security_solution_cypress/cypress/cypress_ci_serverless_qa.config.ts` — `grepFilterSpecs` / default tags
- `x-pack/solutions/security/plugins/security_solution/public/management/cypress/cypress_serverless_qa.config.ts` — defend-workflows QA config
- `x-pack/solutions/security/test/security_solution_cypress/package.json` — `junit:merge`
