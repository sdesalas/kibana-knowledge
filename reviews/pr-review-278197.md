# PR Review: #278197 — [Security Solution] Remove rule changes history feature flags

**PR:** [elastic/kibana#278197](https://github.com/elastic/kibana/pull/278197) by @maximpn

**Scale:** Substantive

---

### Ownership (cross-team — no single focus team)

You asked for a cross-team look, not Detection Rule Management only. CODEOWNERS (last matching rule wins) groups the changed files like this:

- **`@elastic/response-ops` (12):** Alerting config/plugin/`log_rule_changes`/`get_rule_history`, alerting FTR config + fixture plugin, change-tracking group6 tests — *already APPROVED by @pmuellr*
  - `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/common_utils/log_rule_changes.ts`
  - `x-pack/platform/plugins/shared/alerting/server/config.test.ts`
  - `x-pack/platform/plugins/shared/alerting/server/config.ts`
  - `x-pack/platform/plugins/shared/alerting/server/plugin.ts`
  - `x-pack/platform/plugins/shared/alerting/server/routes/rule/apis/create/create_rule_route.test.ts`
  - `x-pack/platform/plugins/shared/alerting/server/rules_client/methods/get_rule_history.ts`
  - `x-pack/platform/plugins/shared/alerting/server/test_utils/index.ts`
  - `x-pack/platform/test/alerting_api_integration/common/config.ts`
  - `x-pack/platform/test/alerting_api_integration/common/plugins/alerts/server/plugin.ts`
  - `x-pack/platform/test/alerting_api_integration/common/plugins/alerts/tsconfig.json`
  - `x-pack/platform/test/alerting_api_integration/spaces_only/tests/alerting/group6/change_tracking/enabled.ts`
  - `x-pack/platform/test/alerting_api_integration/spaces_only/tests/alerting/group6/config_with_change_tracking_enabled.ts`
- **`@elastic/security-detection-engineering` (10):** `@kbn/change-history` FLAGS removal, Security rule details UI / routes / rule-management API registration, change-tracking API integration test
  - `x-pack/platform/packages/shared/kbn-change-history/index.ts`
  - `x-pack/platform/packages/shared/kbn-change-history/integration_tests/client.test.ts`
  - `x-pack/platform/packages/shared/kbn-change-history/src/client.test.ts`
  - `x-pack/platform/packages/shared/kbn-change-history/src/client.ts`
  - `x-pack/platform/packages/shared/kbn-change-history/src/constants.ts`
  - `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/pages/rule_details/index.tsx`
  - `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/pages/rule_details/rule_actions_overflow/index.tsx`
  - `x-pack/solutions/security/plugins/security_solution/public/rules/routes.tsx`
  - `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/register_routes.ts`
  - `x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/rule_management/trial_license_complete_tier/change_tracking.ts`
- **`@elastic/security-solution` (6):** experimental features, uiSettings, serverless project settings, ESS/Serverless test base configs
  - `x-pack/solutions/security/plugins/security_solution/common/experimental_features.ts`
  - `x-pack/solutions/security/plugins/security_solution/server/ui_settings.test.ts`
  - `x-pack/solutions/security/plugins/security_solution/server/ui_settings.ts`
  - `x-pack/solutions/security/plugins/security_solution_serverless/server/plugin.ts`
  - `x-pack/solutions/security/test/security_solution_api_integration/config/ess/config.base.ts`
  - `x-pack/solutions/security/test/security_solution_api_integration/config/serverless/config.base.ts`
- **`@elastic/security-data-analytics` (1):** `x-pack/solutions/security/plugins/security_solution/server/usage/queries/get_changes_history_usage.ts`
- **`@elastic/kibana-operations` (1):** `x-pack/platform/test/alerting_api_integration/common/plugins/alerts/moon.yml`
- **Unowned:** none

---

### Context / Motivation

This PR cleans up temporary flags before GA of rule changes history ([security-team#12367](https://github.com/elastic/security-team/issues/12367)). The feature used to sit behind those flags; this PR takes them out. The advanced setting and alerting `scope` stay.

From the PR description:

> Removes the feature flags gating the Detection Rule Changes History feature, now that it's shipping unconditionally. Both flags defaulted to `true`, so there's no behavior change for the majority of deployments — this only removes the opt-out.

The PR itself calls out the main upgrade risk:

> Removes the `xpack.alerting.ruleChangeTracking.enabled` config key entirely. Any deployment with this key explicitly set to `false` in `kibana.yml` will hit a config validation error on upgrade, and any deployment relying on it to opt out will lose that opt-out on the backported branches (9.5, 9.6).

Bugbot ([inline on `config.ts`](https://github.com/elastic/kibana/pull/278197)) said removing the key without an `unused()` deprecation will break startup:

> `schema.object` rejects unknown keys by default, and there's no matching entry in `config_deprecations.ts`, so any deployment that still has `xpack.alerting.ruleChangeTracking.enabled: false` … in `kibana.yml` will hit a fatal config validation error on startup after upgrade — including on the 9.5/9.6 backport branches.

Author @maximpn said the key never shipped in a released version:

> `ruleChangeTracking.enabled` was only ever introduced in #261981 (2026-04-28), after the 9.5 branch was cut (2026-04-10) — it's not present on the 9.4 branch at all, and 9.5.0 hasn't GA'd yet … So there's no released Kibana version where a real deployment could have set `xpack.alerting.ruleChangeTracking.enabled: false` in their `kibana.yml` … I don't think we need an `unused()` deprecation for it.

Bugbot also caught a bad rebase that swapped the removed experimental flag for an unrelated `securityClassicNavExternalLinks`; Maxim said it was [removed in a later commit](https://github.com/elastic/kibana/pull/278197/changes/0fb66e31f75003d6d9b5c0ed515de3ee9e5a8918). Current diff only deletes `ruleChangesHistoryEnabled`.

Response Ops (@pmuellr) already approved: “ResponseOps changes LGTM.”

---

### Validating the issue — does this PR address it?

**Yes for the epic (take out the temporary flags). Bugbot’s “startup breaks if the old key is still in kibana.yml” point is real in general, but Maxim is right that no released Kibana ever had that key for customers. What’s left is people on unreleased 9.5/main snapshots who still have it set.**

- **Where it shows up** — Alerting `config.ts` uses `schema.object({…})` and rejects unknown keys. Drop `enabled` without `unused('ruleChangeTracking.enabled')` in `config_deprecations.ts`, and any leftover key fails startup.
- **Why the old flags were a problem** — `ruleChangeTracking.enabled`, `ruleChangesHistoryEnabled`, and package `FLAGS` stacked on top of the advanced setting and `scope`. Extra on/off switches that blocked shipping the feature for real.
- **How the PR fixes it** — Deletes those temporary flags and FLAGS. Always builds `ChangeTrackingService`. UI/API/serverless use `securitySolution:enableRuleChangesHistory`. Which solutions get tracking still comes from `ruleChangeTracking.scope`.
- **What’s still open** — No `unused()` deprecation. Fine for real upgrades if 9.5.0 never shipped with the key (Maxim’s dates check out; `upstream/9.5` still has `enabled` waiting for this backport). Anyone on unreleased 9.5/main with `enabled` still in `kibana.yml` won’t boot. Easy to add `unused()` if Response Ops wants that safety net for RCs.

---

### Summary

PR does what it says: removes the temporary feature-flag off-switches for rule changes history now that they default to on. Default product behavior should stay the same. What’s left is alerting `ruleChangeTracking.scope` (which solutions get `trackChanges`) and the Security advanced setting (per-space off switch for writes/reads/UI). Other changes in the same PR: history/restore routes always register (still 403 when the setting is off); Serverless always shows the project setting; Serverless change-history API tests run again; `@kbn/change-history` can no longer refuse `initialize()` via FLAGS.

---

### Files touched

- **`@kbn/change-history` (Detection Engineering):** Remove `FLAGS.FEATURE_ENABLED` and the throw in `initialize`, so the package always starts when Alerting asks.
- **Alerting plugin (Response Ops):** Drop `ruleChangeTracking.enabled` from config; always build `ChangeTrackingService` in `plugin.ts`; update comments about scope / advanced-setting checks in `log_rule_changes.ts` and `RuleChangeTrackingDisabledError`.
- **Alerting FTR / fixture (Response Ops + ops moon.yml):** Rename test helper to `ruleChangeTrackingScope`; stop flipping package FLAGS in the alerts fixture; drop the fixture’s `@kbn/change-history` dependency.
- **Security Solution UI (Detection Engineering):** History tab, overflow menu, and rules routes check only the advanced setting.
- **Security Solution server (Detection Engineering + Security Solution):** Always register history/restore routes and the uiSetting; handlers still 403 when the setting is off.
- **Serverless (Security Solution):** Always add `securitySolution:enableRuleChangesHistory` to project settings.
- **Tests / telemetry:** Drop old flag overrides from ESS/Serverless base configs; turn on Serverless coverage in `change_tracking.ts` (username + ES product-origin header fixes); telemetry comment cleanup.

---

### Flow trace

1. Kibana starts → Alerting constructor always runs `new ChangeTrackingService(logger, kibanaVersion)` (`plugin.ts`).
2. Rule types register → if `config.ruleChangeTracking.scope` includes the solution (default `['security']`), set `ruleType.trackChanges = true` and `changeTrackingService.register(solution)`.
3. Alerting `start()` → `changeTrackingService.initialize({ elasticsearchClient, authService })` → `initializeAll` calls `ChangeHistoryClient.initialize` for each registered module (no FLAGS bail-out).
4. Security rule create/update → `logRuleChanges` skips unless `trackChanges` and `securitySolution:enableRuleChangesHistory` is true.
5. UI → History tab / actions use only `useUiSetting$(ENABLE_RULE_CHANGES_HISTORY_SETTING)`.
6. API → `ruleHistoryRoute` / `restoreRuleFromHistoryRoute` always registered; handler returns 403 if advanced setting is false.
7. Serverless → `setupProjectSettings` always includes the advanced setting id so admins can still turn it off.

---

### Assumptions

- Default `ruleChangeTracking.scope: ['security']` stays — Obs/Stack rules don’t write history unless someone widens scope.
- The advanced setting is still the supported Security off switch for writes (`log_rule_changes`) and reads (route handlers + UI).
- No released Kibana ever needed customers to set `ruleChangeTracking.enabled` (Maxim’s claim; key only exists on unreleased 9.5/main).
- Leftover `enableExperimental: ['ruleChangesHistoryEnabled']` only logs a warning via `parseExperimentalConfigValue` — does not fail startup (`security_solution/server/config.ts`).
- Always building `ChangeTrackingService` is cheap when nothing is registered (`initializeAll` over empty `clients`); with default scope, Security still registers and the data stream still gets created.

---

### Risks

1. **Hard config failure on stale `enabled` key.** No `unused()` deprecation; unknown keys under `xpack.alerting.*` fail startup. Real for snapshot/RC/`kibana.yml` leftovers; Maxim says not for GA customers. Response Ops approved without asking for the deprecation.
2. **(Bigger after gating pass)** **Alerting `scope` is ignored by Security UI/API.** The only Alerting-side switch left is `ruleChangeTracking.scope`. Security UI/API only check the advanced setting — they never read `scope`. If someone sets `scope` to `[]` or leaves out `security`, the UI still shows History and the API calls `getHistory`, which throws “Change history client not initialized for [security]” (`ChangeTrackingService.getHistory`). That mismatch was already there; it matters more now that `enabled` is gone. **See activity #1.**
3. `(Small)` **API routes always registered.** Setting off → 403, not “route missing.” Fine for an advanced-setting feature; client also drops the React route (`routes.tsx`), and server handlers + `change_tracking_disabled` tests line up. **See activity #1.**
4. **Serverless tests now run.** Suite moves `@skipInServerless` → `@serverless` and needs `x-elastic-product-origin: kibana` on ES calls — watch for flakes.

---

### Open questions

1. For Response Ops: skip `unused('ruleChangeTracking.enabled')` because 9.5 isn’t GA yet, or add it anyway for snapshot/RC configs?
2. Is `ruleChangeTracking.scope: []` the intended cluster-wide off switch? If yes, say so somewhere. **Also: if scope leaves out security, should Security UI/API hide the feature or return a clearer 403 — or do we treat weird `scope` values as “you’re on your own”?** (gating pass — activity #1)
3. Should `RuleChangeTrackingDisabledError` get renamed later? Production Alerting always builds the service now; the error mostly means “RulesClient was built without it.”
4. Do any Cloud/ECE/helm templates outside this repo still set `ruleChangeTracking.enabled`?

---

### Notes for your codebase map

- Rule changes history used to have four switches: alerting `enabled`, alerting `scope`, Security experimental flag, Security advanced setting. This PR leaves **scope + advanced setting**.
- Write checks for Security live in Alerting (`log_rule_changes.ts`); read/UI checks live in Security Solution.
- `@kbn/change-history` is Detection Engineering’s; Alerting wraps it in `ChangeTrackingService` (Response Ops). Package FLAGS was a temporary on/off for GA — now gone.
- Unknown experimental flags only warn; unknown alerting config keys crash startup unless you add `unused()` / `deprecate()`.
- Serverless project settings control which advanced settings show up; listing a setting doesn’t turn it on.

---

### Review activities

1. **Focused review: gating.** Checked UI (`routes.tsx`, overflow, rule details), write path (`log_rule_changes.ts`), and both APIs (history + restore) — they all use the advanced setting the same way. `change_tracking_disabled.ts` covers API 403 + no writes. Serverless always listing the project setting is right so the toggle still exists. Raised Risk #2 — Security never checks alerting `scope`, so the only Alerting-side switch left can leave the UI on while the API errors (matters more now that `enabled` is gone); expanded Open question #2. Marked Risk #3 (always-registered routes) as small — handler checks + client route removal + disabled suite match. Also checked: no license check (epic says Essentials+); route privileges (`RULES_API_READ` / `RULES_API_ALL`) unchanged and still combined with the setting check; `DetectionRulesClient` doesn’t re-check the setting (only the routes call it, which is fine).
