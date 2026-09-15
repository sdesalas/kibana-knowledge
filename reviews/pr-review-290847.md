# PR Review: #290847 — [Detection Engine] Unskip query rule execution logic tests

**PR:** [elastic/kibana#290847](https://github.com/elastic/kibana/pull/290847) by @denar50
**Issue:** [elastic/kibana#266815](https://github.com/elastic/kibana/issues/266815)

**Scale:** Small PR.

---

### Context / Motivation

[#266815](https://github.com/elastic/kibana/issues/266815) is a tracked-branch flake on the Query rule execution logic ESS trial suite. The reported failure is a Mocha timeout on the canary test:

> Timeout of 360000ms exceeded […] `Query type rules should have the specific audit record for _id or none of these tests below will pass`

That test was skipped in `1e4a273d73c6` (`skip failing test suite (#266815)`). The issue body is only the timeout — it does not mention aliases. The alias-vs-concrete-index race is the PR author's diagnosis, not something the ticket itself established.

---

### Validating the issue — does this PR address it?

**The timeout is real. The alias-race story is technically plausible and matches the archive + first-test setup.** Flaky-test-runner later got 25/25 on both configs that load this suite — see activity #1.

- **Where the problem manifests** — Suite `before` loads `alerts/8.8.0` with `docsOnly: true`. Archive docs target `.alerts-security.alerts-default` (`data.json`); mappings that would have created `.internal.alerts-security.alerts-default-000001` plus the write alias are skipped. The canary `it()` then creates a real rule and `getAlerts` → `waitForRuleStatus` (default `waitFor` timeout 400s). FTR Mocha test timeout is 360s, which is exactly the number in the issue.
- **Why the old approach was a problem** — If that `docsOnly` load runs before the alerting framework has installed the write alias (ESS) or data stream (serverless), ES auto-creates a concrete index with the alias name. `createAliasStream` then cannot attach `.alerts-security.alerts-default` to `.internal.…-000001` (`invalid_alias_name_exception`). Rule execution never succeeds; `waitForRuleStatus` spins until Mocha kills the test at 360s. That fits an intermittent timeout better than a fast assertion failure.
- **How the PR fixes it** — Poll `es.indices.resolveIndex` until that name is an alias or a data stream, then load the archive so docs land in the backing index.
- **Residual caveat** — The wait does not detect the *bad* state (a concrete index already occupying the name). If another suite already lost the race, this wait hangs until the `before` hook timeout rather than deleting the collision or failing with a useful error.

---

### Summary

Unskips `@ess @serverless @serverlessQA Query type rules` and adds a `waitFor` in the suite `before` so the alerts-as-data write target exists before the 8.8.0 alerts archive is loaded `docsOnly`. Stated intent matches the diff. No production code change.

---

### Files touched

- `…/rule_execution_logic/query/trial_license_complete_tier/custom_query.ts` — the skipped suite, its `before` archive load, and the canary test that timed out. Only file in the PR.

---

### Assumptions

- Alerting installs `.alerts-security.alerts-default` asynchronously at Kibana startup, and this suite can run early enough for that to still be in flight. Confirmed by alerting: `createConcreteWriteIndex` → `createAliasStream` / `createDataStream`, and those APIs use `expand_wildcards: ['open', 'hidden']` / `'all'` because the alias/data stream is hidden.
- `resolveIndex({ name: '.alerts-security.alerts-default' })` without `expand_wildcards` still returns hidden aliases/data streams for an exact name. Alerting itself never calls this API that way; `kibana-ci` passed once, which is consistent with “exact name works” but is not a proof.
- `docsOnly` + `useCreate` is intentional: keep the framework’s current mappings, only inject 8.8.0 alert docs. Archive `mappings.json` would otherwise replace the write index.
- Default-space alias name is enough; this suite does not exercise non-default spaces.

---

### Risks

1. (Downgraded — see activity #1) **Unskip of an intermittent race.** Flaky runner got 25/25 on both ESS and serverless configs that load this suite. Original issue was the ESS config, so that target is covered. Remaining gap: `@serverlessQA` / MKI periodic (`qaPeriodicEnv`) was not what they ran; 25 still isn't a guarantee for a very rare race.

2. (Downgraded — see activity #3) **Wait does not fail-fast if a concrete index already occupies the name.** The check is still real in the code, but this FTR config is dedicated (`ess.config.ts` / `serverless.config.ts` load only this folder) and `custom_query` is the first file. Alerting writes use `require_alias: true` on ESS, so they will not auto-create the colliding index. The `docsOnly` load this wait precedes is the thing that would. Leftover collision at wait-start is unlikely here. If the alias never appears, you still get a generic 120s `hookTimeout`, not `waitFor`'s error.

3. (Downgraded — see activity #4) **Same `docsOnly` load exists elsewhere, but those suites do not share this failure mode.** `8.8.0_multiple_docs` also indexes to `.alerts-security.alerts-default` with `docsOnly`/`useCreate` in ~8 FTR files (query_alerts, DLS, unified_alerts, attacks). They query preloaded docs; they do not execute rules. A colliding concrete index would still be searchable, so they would not 360s-timeout the way this canary did. None of them are skipped. Out of scope for this PR.

---

### Open questions

- ~~Why `resolveIndex` instead of `createAlertsIndex` (the helper sibling detection-engine tests use) or `indices.getAlias` / `existsAlias` with `expand_wildcards: ['open', 'hidden']` (what alerting uses to find this alias)?~~ **Answered — see activity #3.** `createAlertsIndex` is the wrong API (legacy `.siem-signals` no-op). `resolveIndex` is the one ES call that covers ESS alias *or* serverless data stream.
- ~~If a concrete index already occupies the name, should the wait fail immediately (or delete it) instead of polling until the hook times out?~~ **(LOW PRIORITY) — see activity #3.** Fail-fast would be nicer diagnostics; it is not the race this PR is fixing.
- Was the 360s timeout ever captured with an `invalid_alias_name_exception` in Kibana/ES logs, or is the race inferred from the archive setup?

---

### Notes for your codebase map

- Alerts-as-data write target is `.alerts-security.alerts-default`: write alias on ESS (`AliasImplementation`), hidden data stream on serverless (`DataStreamImplementation`). Install is async via `createConcreteWriteIndex`.
- es-archives that target that name must not `docsOnly`-load before the alias/data stream exists, or ES auto-creates a colliding concrete index.
- `createAlertsIndex` POSTs `DETECTION_ENGINE_INDEX_URL` → `createDetectionIndex`, which only touches legacy `.siem-signals-<space>`. If those bootstrap indices are absent (normal now), it returns 200 and does nothing. It does **not** create or wait for `.alerts-security.alerts-default`.
- `resolveIndex` is the one ES API that returns either an alias or a data stream, so one poll covers ESS and serverless. `getAlias` / `existsAlias` miss data streams.
- `waitFor` default timeout is 400s; FTR Mocha test timeout is 360s; hook timeout is 120s. A wait in `before()` that never succeeds will surface as a hook timeout, not `waitFor`’s error.
- The canary test name (“or none of these tests below will pass”) is the first real-rule execution; everything after it uses preview.

---

### Follow-up Review Activities

1. **Flaky-test-runner configs (kibanamachine comments).** Checked whether the passing flaky-runner jobs are the configs that actually load the unskipped suite. They are. kibanamachine posted 25/25 on `…/query/trial_license_complete_tier/configs/ess.config.ts` ([runner#14344](https://buildkite.com/elastic/kibana-flaky-test-suite-runner/builds/14344)) and the matching `serverless.config.ts` ([runner#14350](https://buildkite.com/elastic/kibana-flaky-test-suite-runner/builds/14350)). Those two files are the only FTR configs for this folder (`index.ts` loads `custom_query.ts` plus three siblings); they are the entries in `ftr_security_stateful_configs.yml` / `ftr_security_serverless_configs.yml`; ESS junit name matches issue #266815 exactly. Downgraded Risk #1. Not run: MKI/QA periodic (`rule_execution_logic:query:qa:serverless`). The later kibana-pr “succeeded but flaky” comment (build 501481) is Cases + Discover, unrelated to this suite.

2. **Anything else left.** No human reviews yet (`REVIEW_REQUIRED`). Later `esArchiver.load`s in this file are `suppression` / `ecs_compliant`, not the alerts archive, so they don't share the alias race. Remaining items are author questions (why `resolveIndex` vs `createAlertsIndex` / `getAlias`, fail-fast on a concrete index, whether logs ever showed `invalid_alias_name_exception`) plus Risk #3 which is out of scope for this PR.

3. **Risk 2 + why not `createAlertsIndex`.** `createAlertsIndex` is the wrong tool: it POSTs `DETECTION_ENGINE_INDEX_URL` → `createDetectionIndex`, which operates on `getSignalsIndex()` (`.siem-signals-default`). If those legacy bootstrap indices are missing — the common case — the handler returns immediately with 200. It never waits for or creates `.alerts-security.alerts-default` (that's alerting's `createConcreteWriteIndex` at startup). `getAlias`/`existsAlias` would miss serverless data streams; `getDataStream` would miss ESS aliases. `resolveIndex` is the one call that covers both, which is why that poll is the right shape. Risk 2's leftover-collision hang is unlikely in this dedicated FTR config (`custom_query` is first; alerting writes use `require_alias: true` so they will not auto-create the bad index; the `docsOnly` load is what would, and the wait runs before it). Fail-fast on `resolved.indices.length > 0` would still be nicer if the wait ever saw a concrete index, but it is not the flake. Downgraded Risk #2; answered the `createAlertsIndex` / fail-fast questions. Still open: whether logs ever showed `invalid_alias_name_exception`.

4. **Risk 3 — other `docsOnly` alerts-archive loads.** Same target name: `alerts/8.8.0_multiple_docs` docs also go to `.alerts-security.alerts-default`. Callers: `query_alerts.ts` (runtime-fields `beforeEach`), `document_level_security.ts`, and the unified_alerts / attacks wrappers (`search_alerts`, `set_alert_*`, `search_attacks`, `set_tags`, `set_assignees`, `set_workflow_status`). They all `deleteAllAlerts` then `docsOnly`+`useCreate`; `createAlertsIndex` after the load is a no-op (activity #3). `deleteAllAlerts` only `deleteByQuery`s AAD docs — it does not drop the alias. Those suites **query** preloaded docs; they do not create rules and wait for writes. A colliding concrete index would still answer search, so they would not reproduce the 360s canary timeout. Load order also burns time first (earlier files in the alerts config; `createUsersAndRoles` in unified_alerts/attacks). None are skipped. Cypress `docsOnly` loads (ransomware, etc.) are different archives. CSP `loadAlertArchive` is a different race (full archive load vs Kibana recreate → `illegal_state_exception`). `custom_query` uniquely does **not** `unload` the 8.8.0 archive (siblings do, which would delete `.internal.alerts-security.alerts-default-000001` from mappings). Downgraded Risk #3 as out of scope / not the same bug.
