# PR #264969 — Bounds request-validated arrays in the gap auto-fill scheduler schemas

- **Author:** @nkhristinin
- **URL:** https://github.com/elastic/kibana/pull/264969
- **Branch:** `unbound-schema-gap-auto-scheduler` → `main`
- **Labels:** `release_note:skip`, `backport:skip`

**Scale:** Small PR (5 files, ~40 net lines, two distinct concerns).

## Ownership (team: `@elastic/security-detection-rule-management`)
- **Your team's files (1):** `x-pack/solutions/security/test/security_solution_cypress/cypress/e2e/detection_response/rule_management/rules_monitoring_overview_panel.cy.ts` — *focus review effort here*
- **Other teams' files (4):** the four schema/constants files under `x-pack/platform/plugins/shared/alerting/...` (`@elastic/response-ops`, plus `@elastic/security-detection-engine` for the gap subdirs)
- **Unowned:** none

> Heads up: 4 of 5 files belong to `@elastic/response-ops` / `@elastic/security-detection-engine`. Your team is on the hook only for un-skipping the Cypress test. The schema work is context, not your accountable area — review depth weighted accordingly.

## Summary
Adds a `maxSize` cap (100) to the `scope` and `ruleTypes` arrays in the **application-layer** create/update schemas of the gap auto-fill scheduler, and caps `statuses` in the find-logs schema to the number of valid status literals (4). Caps live as `as const` constants in `common/constants/gap_auto_fill_scheduler.ts`. Also sneaks in an un-skip of the `Rules Monitoring Overview Panel` Cypress suite that isn't mentioned in the PR description.

The stated intent — "bounds **request-validated** arrays" — is only partially delivered: see Risks #1 below.

## Files touched
- **Limit constants** — `common/constants/gap_auto_fill_scheduler.ts`: adds `maxScopeSize: 100`, `maxRuleTypesSize: 100`.
- **Application-layer schemas** (`server/application/gaps/auto_fill_scheduler/methods/.../schemas/*.ts`):
  - `create_gap_auto_fill_scheduler_schema.ts` — applies the new caps to `scope` and `ruleTypes`.
  - `update_gap_auto_fill_scheduler_schema.ts` — same.
  - `find_gap_auto_fill_scheduler_logs_schema.ts` — caps `statuses` at `Object.values(GAP_AUTO_FILL_STATUS).length` (= 4).
- **Cypress test** — `rules_monitoring_overview_panel.cy.ts`: changes `describe.skip(...)` back to `describe(...)`. Originally skipped on 2026-04-16 by Brad White ("skip failing test suite", `8212ace05b6`). The same author (Nikita) already merged a fix for it in `#263758` ("Fix cypress tests for gap reason").

## Flow trace
HTTP POST/PUT to `INTERNAL_ALERTING_GAPS_AUTO_FILL_SCHEDULER_API_PATH`:

1. Hits `createAutoFillSchedulerRoute` / `updateAutoFillSchedulerRoute` in `server/routes/gaps/apis/gap_auto_fill_schedule/...`.
2. Route validates body against **`gapAutoFillSchedulerBodySchemaV1`** from `common/routes/gaps/apis/gap_auto_fill_scheduler/schemas/v1.ts` (this is the public-facing schema).
3. Body passes through `transformRequestV1(req)` (snake_case → camelCase, etc.).
4. Then `rulesClient.createGapAutoFillScheduler(...)` is called, which **re-validates** with the application-layer `createGapAutoFillSchedulerSchema` — *this* is where the new bounds kick in.
5. SO is created and a task is scheduled with `scope: params.scope ?? []`.

The new caps therefore reject oversized payloads only at step 4, after the request has already been parsed, transformed, and entered the rules client. They do not protect step 2.

## Assumptions
- `100` is a sane cap for both `scope` (kuery-style scope strings) and `ruleTypes` (type/consumer pairs). Consistent with the adjacent `get_gaps_summary_by_rule_ids` schema, which uses `maxSize: 100` for `ruleIds`.
- `statuses` is meant as a "filter by these statuses" multi-select, where allowing more than 4 values is meaningless; bounding by `statusValues.length` is intended as a sanity cap, not a uniqueness constraint.
- The application-layer schemas in `server/application/gaps/auto_fill_scheduler/methods/.../schemas/` are reachable via internal callers (the rules client) and are not solely defensive duplicates of the route schema. (Otherwise this PR would only be a paper-tightening exercise.)
- The Cypress test is now stable on `main` because of `#263758`, justifying the un-skip.

## Risks
1. **Bounds applied at the wrong layer.** The route-level schemas in `common/routes/gaps/apis/gap_auto_fill_scheduler/schemas/v1.ts` (`gapAutoFillSchedulerBodySchema` lines 74–80, `gapAutoFillSchedulerUpdateBodySchema` lines 104–110, `gapAutoFillSchedulerLogsRequestQuerySchema` lines 158–167) still accept unbounded `scope` / `rule_types` / `statuses`. A malicious or buggy client can still POST a multi-megabyte array; it will be parsed, JSON-validated, and run through `validateGapAutoFillSchedulerPayload` (which itself iterates `rule_types` to check duplicates) before the new caps reject it. If the *intent* is to harden against oversized request payloads, the bounds belong on the v1 route schemas (or on both layers).
2. **`statuses` cap is structurally weak.** `{ maxSize: statusValues.length }` only blocks arrays with more than 4 entries; `['success', 'success', 'success', 'success']` still passes. If "no duplicates" is the intent, `uniqueItems` (or a manual `Set` check via `validate(...)`) would express it more honestly. As-is, the bound provides minimal additional protection beyond the per-element `oneOf`.
3. **Un-skip bundled silently.** Re-enabling a previously failing Cypress suite in a PR titled "Bounds request-validated arrays..." is easy to miss in review. If the test flakes, the revert PR will likely revert the schema bounds too. The two changes have no causal connection — they could/should be separate PRs (or at minimum called out in the description).
4. **Bound choice (100) is unjustified in the diff.** No JSDoc on `maxScopeSize` / `maxRuleTypesSize` (compare to the documented `maxBackfills` / `numRetries` in the same file). Future maintainers won't know whether `100` was researched or guessed.

## Open questions
- Why bound at the application layer instead of (or in addition to) the v1 route schema? Is there a known caller of `rulesClient.createGapAutoFillScheduler` that bypasses the route and could pass a huge array?
- Was a duplicate-check / `uniqueItems` constraint considered for `statuses`? If yes, why was a length-cap chosen instead?
- The un-skipped Cypress suite — has it run green locally on this branch? Any reason it shouldn't be in its own PR or referenced in the description?
- Why `100` for both `scope` and `ruleTypes`? The current upper bound on registered rule types in Kibana is well under 100, so `maxRuleTypesSize` is effectively a no-op upper bound today; was that intentional, or is a tighter cap (e.g., the number of registered rule types) preferable?

## Notes for your codebase map
- The gap auto-fill scheduler has **two layers of schema validation**: a public route schema in `common/routes/gaps/apis/gap_auto_fill_scheduler/schemas/v1.ts` (snake_case, with custom `validate` for date math + duplicate `rule_types`), and an internal application-layer schema in `server/application/gaps/auto_fill_scheduler/methods/.../schemas/` (camelCase) used by the rules client. Changes meant to harden the public surface need to land on the v1 route schema, not (only) the application-layer one.
- Limit constants for the gap scheduler live centrally in `common/constants/gap_auto_fill_scheduler.ts` and are imported by both schema layers — that's the one place to evolve numeric caps consistently.
- Co-ownership pattern: gap-related code under `x-pack/platform/plugins/shared/alerting/server/application/gaps` is jointly owned by `@elastic/response-ops` and `@elastic/security-detection-engine`. `@elastic/security-detection-rule-management` is **not** a codeowner here — they own the security-side Cypress suites under `cypress/e2e/detection_response/rule_management`.
- Existing precedent for array bounds in alerting: bulk rule ops use `maxSize: 1000`; gap summary endpoints use `maxSize: 100`. New caps in this PR follow the gap-area convention.
- Convention quirk: the `find_logs` schema bound is computed as `Object.values(GAP_AUTO_FILL_STATUS).length` rather than hard-coded — small but neat pattern for keeping the bound in sync with the enum.
