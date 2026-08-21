# PR Review: #286248 — [Security Solution] Fix add_actions alerts-alias setup race in detection engine actions suite

**PR:** [elastic/kibana#286248](https://github.com/elastic/kibana/pull/286248) by @kibanamachine (Flaky Test Fixer automation)
**Issue:** [#286241](https://github.com/elastic/kibana/issues/286241)

**Scale:** Small (one file, 18 lines changed, pure test fix).

---

**Ownership (team: `@elastic/security-detection-rule-management`)**
- **Your team's files (0):** none — the changed file is owned by `@elastic/security-detection-engineering` per CODEOWNERS (`/x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/detection_engine`). You're likely cc'd for visibility, not as the accountable reviewer.

---

### Context / Motivation

The `add_actions` FTR suite was failing with `FTR run aborted (mocha timeout)` — the `before` hook hung for its full 6-minute budget, blocking all four tests in the suite. The root cause was a race between the ES archiver and the alerting framework's alias setup:

The old `before` hook loaded the `security_solution/alerts/8.8.0` archive with `docsOnly: true` directly into `.alerts-security.alerts-default`. That index name is the **write alias** the alerting framework expects to manage. When the archiver forced a concrete index of that name before the framework had a chance to create the alias, rule execution failed with `invalid_alias_name_exception`, causing `waitForRuleStatus` to never see `succeeded`.

The `after` hook had a separate bug: it tried to unload `signals/severity_risk_overrides` — an archive that was never loaded in `before`.

---

### Summary

Removes stale archive loading from the `before`/`after` hooks and replaces it with `createAlertsIndex(supertest, log)`, the same pattern already used by the sibling `check_privileges.ts` test in the same suite. The fix ensures the alerting framework's alias is created cleanly before rule execution, eliminating the alias-name collision. None of the four tests in this suite actually read the pre-seeded 8.8.0 alert docs, so the archive was never needed.

---

### Files touched

- `add_actions.ts` — the only changed file. Replaces `esArchiver.load(…8.8.0…)` in `before` with `createAlertsIndex(supertest, log)`, and replaces the mismatched `esArchiver.unload(…severity_risk_overrides…)` in `after` with `deleteAllAlerts(supertest, log, es)`.

---

### Flow trace

1. `before` — `esArchiver.load(auditbeatPath)` seeds the auditbeat data the tests query against.
2. `before` *(old)* — `esArchiver.load(…8.8.0, { docsOnly: true })` wrote docs directly to `.alerts-security.alerts-default`, forcing ES to auto-create a concrete index of that name.
3. `before` *(new)* — `createAlertsIndex(supertest, log)` calls the Kibana API (`POST /api/detection_engine/index`), which creates the backing ILM-managed index and points the `.alerts-security.alerts-default` alias at it — the correct ordering.
4. Each test creates a rule, waits for `waitForRuleSuccess`, then asserts on alerts/cases.
5. `after` *(new)* — `deleteAllAlerts(supertest, log, es)` cleans up alert docs written during test runs (replaces the mismatched unload of an archive that was never loaded).

---

### Assumptions

- `createAlertsIndex` is idempotent and safe to call even if the index already exists. (Given it's used across `check_privileges.ts` and `throttle.ts` without issue, this holds.)
- The four tests don't actually need any pre-seeded 8.8.0 alert data — verified in the PR description and consistent with the fact that all four tests create their own rules and wait for fresh alert generation.

---

### Risks

Low. The fix is narrowly scoped and mirrors an established pattern in the same suite. The main surface area is:

- If `createAlertsIndex` behaves differently in a fresh environment vs. one where the index already exists, the `beforeEach`'s `deleteAllAlerts` call might not fully reset state between tests. But since `deleteAllAlerts` is called in `beforeEach` (not `after`), alerts are cleared before each individual test regardless.

---

### Nits

1. **`createAlertsIndex` swallows HTTP failures silently** — `countDownTest` is called with `passed: true` returned unconditionally inside the callback (`config/services/detections_response/alerts/create_alerts_index.ts:30`), so a non-2xx from `POST /api/detection_engine/index` still counts as success. A setup failure would manifest as confusing downstream test errors rather than a clear `before` hook failure. Pre-existing in siblings; not introduced by this diff but now a new dependency for this suite.

### Open questions

None — the fix is mechanically straightforward and the PR description is unusually thorough for an automated fix. The `flaky-fix-check:passed` label confirms the targeted test held across CI runs post-patch.

---

### Notes for your codebase map

- `createAlertsIndex(supertest, log)` from `@kbn/detections-response-ftr-services` is the canonical way to initialise the alerts backing index in FTR tests — it calls the Kibana API and ensures the alias is installed before test execution.
- The `.alerts-security.alerts-default` name is a **write alias** managed by the alerting framework, not a plain index. Loading docs directly into it via `esArchiver` with `docsOnly: true` bypasses alias creation and causes concrete-index/alias collisions.
- The Flaky Test Fixer automation (`kibanamachine`) generated this PR from issue #286241 — the pattern is: issue auto-opened by CI failure → automated fix → `flaky-fix-check:passed` label after CI verification.
- FTR suite files in this area follow a `before`/`beforeEach`/`after` pattern where `before` sets up shared infra (index/alias), `beforeEach` resets per-test state (delete rules + alerts), and `after` tears down shared infra.
- `backport:all-open` is applied — the same stale archive block exists on `9.5`, `9.4`, and `8.19` branches, so expect backport PRs shortly.

---

### Review activities

1. **Focused pass: test-coverage.** The setup/teardown swap is structurally sound and mirrors the sibling pattern. One pre-existing issue surfaced in the helper being introduced: `createAlertsIndex` calls `countDownTest` with `passed: true` returned unconditionally, so a failed `POST /api/detection_engine/index` (wrong API version, Kibana not ready) would silently appear to succeed and manifest as a confusing downstream test failure rather than a clear setup error. This is not introduced by this diff — the same helper is already used in `check_privileges.ts` — but it's the new failure mode this suite now depends on. Noted as a nit below. `deleteAllAlerts` in `after` is redundant with `beforeEach` but harmless. No regression test for the alias race is expected — the fix is structural, not behavioral. Checked that `deleteAllAlerts` is already imported (line 16, pre-existing) — the import addition is only `createAlertsIndex`. (Raised Nit #1.)
