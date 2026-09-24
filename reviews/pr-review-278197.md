# PR Review: #278197 — [Security Solution] Remove rule changes history feature flags

**PR:** [elastic/kibana#278197](https://github.com/elastic/kibana/pull/278197) by @maximpn
**Created Date: 23 Sep 2026**
**Related:** [security-team#12367](https://github.com/elastic/security-team/issues/12367) (epic)

---

**Scale:** Substantive (32 files, −138 / +74, cross-team)

---

### Ownership

CODEOWNERS last-match-wins:

- **`@elastic/response-ops` (8):** Alerting config/plugin, `log_rule_changes`, `get_rule_history`, `create_rule_route.test`, `test_utils`
- **`@elastic/kibana-core` (5):** `@kbn/change-history` index, client, client tests (unit + integration), constants
- **`@elastic/kibana-operations` (1):** `common/plugins/alerts/moon.yml`
- **`@elastic/response-ops` (6, FTR):** alerting_api_integration config, fixture plugin, tsconfig, group6 change-tracking tests
- **`@elastic/security-solution` (6):** `experimental_features.ts`, `ui_settings.ts` + test, serverless plugin, ESS/serverless base configs
- **`@elastic/security-detection-engineering` (5):** `rule_details/index.tsx`, `rule_actions_overflow`, `routes.tsx`, `register_routes.ts`, `change_tracking.ts` API integration test
- **`@elastic/security-data-analytics` (1):** `get_changes_history_usage.ts`

---

### Context / Motivation

The Detection Rule Changes History feature shipped in 9.5.0 behind two flags that both defaulted to `true`:
1. Alerting config `xpack.alerting.ruleChangeTracking.enabled`
2. Security experimental flag `ruleChangesHistoryEnabled`

Plus a package-level `FLAGS.FEATURE_ENABLED` in `@kbn/change-history`.

All three were scaffolding for GA — the real user-facing on/off is the `securitySolution:enableRuleChangesHistory` advanced setting (per-space) and the alerting `ruleChangeTracking.scope` (cluster-wide, which solutions get tracking). This PR removes the temporary flags, leaving only those two.

From the PR:

> Removes the feature flags gating the Detection Rule Changes History feature, now that it's shipping unconditionally. Both flags defaulted to `true`, so there's no behavior change for the majority of deployments — this only removes the opt-out.

The PR originally lacked a config deprecation for the removed `enabled` key, which meant any 9.5.x deployment with `xpack.alerting.ruleChangeTracking.enabled` in `kibana.yml` would crash on upgrade. **That's now fixed** — the current diff adds `unused('ruleChangeTracking.enabled', { level: 'warning' })` in `config_deprecations.ts` with a test.

---

### Validating the issue — does this PR address it?

**Yes. The temporary flags are removed, and the upgrade path is handled.**

- **Where the problem was:** Three separate on/off switches (`enabled` config, experimental flag, `FLAGS`) stacked on top of the real controls (`scope` + advanced setting), blocking GA cleanup.
- **How the PR fixes it:** Deletes all three. Always constructs `ChangeTrackingService`. UI/API/serverless rely solely on the advanced setting. Alerting `scope` still controls which solutions produce history records.
- **Upgrade path:** `unused('ruleChangeTracking.enabled')` in `config_deprecations.ts` strips the key with a warning instead of crashing on unknown config. Test confirms the key is removed and `scope` is preserved.
- **Leftover experimental flag:** `ruleChangesHistoryEnabled` in `enableExperimental` only logs a warning via `parseExperimentalConfigValue` — does not crash. Confirmed in `security_solution/server/config.ts`.

---

### Summary

Removes the three temporary feature-flag off-switches for rule changes history. Default product behavior is unchanged — the feature was already on everywhere. What remains is alerting `ruleChangeTracking.scope` (which solutions get `trackChanges`) and the Security advanced setting `securitySolution:enableRuleChangesHistory` (per-space off switch for writes/reads/UI). Other changes: history/restore routes always register (still 403 when setting off); serverless always shows the project setting; serverless change-history API tests are enabled; `@kbn/change-history` no longer has a FLAGS bail-out.

---

### Files touched

**`@kbn/change-history` (kibana-core):** Remove `FLAGS` object and its export. Remove `FLAGS.FEATURE_ENABLED` guard in `ChangeHistoryClient.initialize()`. Clean up tests that toggled FLAGS.

**Alerting plugin (response-ops):**
- `config.ts` — drop `enabled` from `ruleChangeTracking` schema
- `config_deprecations.ts` — add `unused('ruleChangeTracking.enabled')` so stale keys don't crash startup
- `config_deprecations.test.ts` — test for the above
- `plugin.ts` — always construct `ChangeTrackingService` (no conditional)
- `log_rule_changes.ts` — updated comments: `scope` is the only alerting-side gate now
- `get_rule_history.ts` — updated doc comment for `RuleChangeTrackingDisabledError`
- `create_rule_route.test.ts`, `test_utils/index.ts` — drop `enabled` from test config fixtures

**Alerting FTR (response-ops + ops):**
- `common/config.ts` — rename `ruleChangeTrackingEnabled` option to `ruleChangeTrackingScope` (now passes scope directly instead of the old enabled+hardcoded-scope combo)
- `common/plugins/alerts/server/plugin.ts` — stop setting `CHANGE_HISTORY_FLAGS`; drop `stop()` method
- `moon.yml`, `tsconfig.json` — remove `@kbn/change-history` dependency
- `group6/enabled.ts` — test description updated
- `group6/config_with_change_tracking_enabled.ts` — uses `ruleChangeTrackingScope: ['stack']`

**Security Solution UI (detection-engineering):**
- `rule_details/index.tsx`, `rule_actions_overflow/index.tsx`, `routes.tsx` — drop `useIsExperimentalFeatureEnabled('ruleChangesHistoryEnabled')`, use only `useUiSetting$` for the advanced setting

**Security Solution server (security-solution):**
- `experimental_features.ts` — remove `ruleChangesHistoryEnabled` definition
- `ui_settings.ts` — always register `ENABLE_RULE_CHANGES_HISTORY_SETTING` (no longer conditional on experimental flag)
- `ui_settings.test.ts` — drop flag from test fixture
- `register_routes.ts` — always register `ruleHistoryRoute` and `restoreRuleFromHistoryRoute`

**Serverless (security-solution):** `plugin.ts` — always push `securitySolution:enableRuleChangesHistory` to project settings.

**Tests / telemetry:**
- ESS `config.base.ts` — drop experimental flag, `enabled` config, and uiSettings override
- Serverless `config.base.ts` — drop experimental flag and `enabled` config
- `change_tracking.ts` — `@ess @skipInServerless` → `@ess @serverless`; use `utils.getUsername()` instead of hardcoded `'elastic'`
- `get_changes_history_usage.ts` — comment cleanup (remove stale reference to `enabled` config)

---

### Flow trace

1. Kibana starts → Alerting `constructor` always runs `new ChangeTrackingService(logger, kibanaVersion)` (`plugin.ts`).
2. If stale `ruleChangeTracking.enabled` exists in `kibana.yml` → `unused()` deprecation strips it with a warning; startup proceeds.
3. Rule types register → if `config.ruleChangeTracking.scope` includes the solution (default `['security']`), `ruleType.trackChanges = true` + `changeTrackingService.register(solution)`.
4. Alerting `start()` → `changeTrackingService.initialize()` → `ChangeHistoryClient.initialize()` creates the data stream (no FLAGS bail-out).
5. Security rule create/update → `logRuleChanges` skips unless `trackChanges` is true AND `securitySolution:enableRuleChangesHistory` advanced setting is true.
6. UI → History tab / actions overflow / routes check only `useUiSetting$(ENABLE_RULE_CHANGES_HISTORY_SETTING)`.
7. API → `ruleHistoryRoute` / `restoreRuleFromHistoryRoute` always registered; handler returns 403 if advanced setting is false.
8. Serverless → `setupProjectSettings` always includes the setting ID so admins see the toggle.

---

### Assumptions

- Default `ruleChangeTracking.scope: ['security']` stays — Obs/Stack rules don't write history unless someone widens scope.
- The advanced setting is the supported Security off switch for writes (`log_rule_changes`) and reads (route handlers + UI).
- Always building `ChangeTrackingService` is cheap when nothing is registered. With default scope, Security registers and the data stream gets created at startup.
- Leftover `enableExperimental: ['ruleChangesHistoryEnabled']` in `kibana.yml` or helm only logs a warning — does not fail startup.

---

### Risks

1. **(Low — pre-existing, not introduced by this PR)** **Scope ↔ UI mismatch.** Security UI/API only check the advanced setting — they never read alerting `scope`. If someone sets `scope: []`, the UI still shows History (advanced setting defaults to true), the API calls `getHistory()`, `ChangeTrackingService` finds no client for `'security'` (never registered), and throws → **500** with `Unable to get history. Change history client not initialized for [security, alerting-rules]`. User sees a generic error toast. Write path is fine (silently skips). Requires deliberate admin misconfiguration of a key that defaults to `['security']`. See **Follow-up #1** for the full trace.

2. **(Low)** **Serverless tests newly enabled.** Suite moves `@skipInServerless` → `@serverless`. The `getUsername()` change is correct for SAML auth. Worth watching for flakes from timing or data-stream initialization in serverless environments.

3. **(Low)** **Routes always registered.** Setting off → 403, not "route missing." This is fine — client also drops the React route in `routes.tsx`, and server handlers + `change_tracking_disabled` tests align. No behavioral change for users.

---

### Open questions

1. Is `ruleChangeTracking.scope: []` the intended cluster-wide off switch now that `enabled` is gone? If so, should Security UI/API check it too (or at least return a clear error instead of an uninitialized-client crash)?
2. Should `RuleChangeTrackingDisabledError` get renamed? Production alerting always builds the service now; the error fires only when `changeTrackingService` is null on the `RulesClientContext`, which shouldn't happen with this PR.
3. Do any Cloud/ECE/helm templates outside this repo still set `ruleChangeTracking.enabled`? The `unused()` deprecation handles it gracefully, but those templates should get cleaned up too.

---

### Notes for your codebase map

- Rule changes history had four switches: alerting `enabled`, alerting `scope`, Security experimental flag, Security advanced setting. **This PR leaves scope + advanced setting.**
- Write checks for Security live in Alerting (`log_rule_changes.ts`); read/UI checks live in Security Solution.
- `@kbn/change-history` is owned by `@elastic/kibana-core`; Alerting wraps it in `ChangeTrackingService` (Response Ops). The package-level FLAGS was a temporary GA gate — now gone.
- Unknown experimental flags only warn; unknown alerting config keys crash startup unless you add `unused()` / `deprecate()`.
- Serverless project settings control which advanced settings show up; listing a setting doesn't turn it on.
- The FTR config pattern changed: `ruleChangeTrackingEnabled: boolean` → `ruleChangeTrackingScope: string[]`, which is cleaner.

---

### Follow-up Review Activities

1. **Deep dive: Risk #1 — scope ↔ UI mismatch when `ruleChangeTracking.scope` excludes `'security'`.**

   Traced the full write and read paths. Two distinct failure modes:

   **Write path (silent, correct):**
   - `plugin.ts:590` — `scope.includes('security')` is false → `trackChanges` stays false, `changeTrackingService.register('security')` never called
   - `log_rule_changes.ts:111` — `!ruleType.trackChanges` → skips → no writes. Silent and correct.

   **Read path (500 error):**
   - `route.ts:56` — checks only the advanced setting (`ENABLE_RULE_CHANGES_HISTORY_SETTING`) → true (default) → proceeds
   - `get_history_for_rule.ts:44` — calls `rulesClient.getHistory({ module: 'security', ... })`
   - `get_rule_history.ts:73` — `context.changeTrackingService` exists (always constructed now) → passes null check
   - `service.ts:182` — `this.clients['security']` is **undefined** because `register('security')` was never called
   - `service.ts:184–188` — **throws** `Error: Unable to get history. Change history client not initialized for [security, alerting-rules]`
   - `route.ts:76` — `transformError(err)` → returns **500** to the client

   **UI experience:** History tab renders (advanced setting is true), fires fetch, gets 500, shows an error toast via `useInfiniteChangeHistory` → `addError(error, { title: i18n.HISTORY_FETCH_ERROR })`.

   **Verdict:** Pre-existing issue, not introduced by this PR. The mismatch existed before because `scope` and the advanced setting were always independent. With `enabled` gone the only way to trigger this is manually setting `scope: []` or removing `'security'` — a deliberate admin action on a config key that defaults to `['security']`. Unlikely in practice but the error is unhelpful (generic 500 vs a clear "scope doesn't include security" message). Filing as a low-priority follow-up suggestion, not a merge blocker. Downgraded from Medium to **Low**.
