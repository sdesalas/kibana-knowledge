# AlertZero gating

AlertZero is **off by default** and is not a Security Solution `experimentalFeatures` flag. Several independent gates all have to pass. A request that skips the HTTP wrapper can miss some of them.

Plugin: `x-pack/solutions/security/plugins/alertzero`. Config path: `xpack.alertzero`.

## The gates (in order)

### 1. Deployment kill switch — `xpack.alertzero.enabled`

- Config, **default `false`**. Restart required.
- Off: no uiSetting registration, no routes, no Kibana feature, no workers, no managed-workflow install. Threat-intel supply also keys off this (`security_solution/server/threat_intel/wiring.ts`).
- Source: `alertzero/server/config.ts`.

Local: `xpack.alertzero.enabled: true` in `kibana.dev.yml`.

### 2. Per-space advanced setting — `securitySolution:enableAlertZero`

- **Default `false`**. `experimental: true`. Namespace-scoped (per space).
- Only registered when the kill switch is on.
- Nav nodes drop when this is off. Internal AlertZero HTTP routes 404 via `withAlertZeroEnabled`.
- Source: `alertzero/server/ui_settings.ts`, constant `ALERTZERO_ENABLED_SETTING_ID` in `@kbn/alertzero-common`.

This is the user-facing “turn AlertZero on for this space” toggle.

### 3. License / serverless tier

- **ESS:** active Enterprise license (`minimumLicense: 'enterprise'` on the feature; `getSubscriptionAvailability` in `alertzero/common/availability.ts`).
- **Serverless:** Security product line + **Complete** tier (`isAlertZeroAvailable` in `security_solution_serverless/common/alertzero_availability.ts`, pushed via `setServerlessTierAvailable`).
- HTTP: `withAlertZeroEnabled` returns 403 with a license/tier message when this fails.

### 4. Kibana feature privileges

- Feature id: `alertzero`.
- UI: `show` (read) / `write` (all).
- API: `alertzero_read` / `alertzero_write` (plus investigations/escalations privileges on the same feature).
- Source: `alertzero/server/plugin.ts` `features.registerKibanaFeature`.

### 5. Runtime dependencies

Optional plugins / capabilities. If any are missing, `start()` does not build workers; routes that need them 503 (`hasRequiredDependencies`). UI: **“AlertZero is unavailable / Contact your administrator to enable AlertZero's required plugins.”** (`access_boundary.tsx`). That copy is this gate only — space-off, license, and privileges have their own screens.

| Dependency | Config | Default |
|---|---|---|
| Agent Builder | `xpack.agentBuilder.enabled` | `true` |
| Proposals | `xpack.proposals.enabled` | **`false`** |
| Agentic investigations | `xpack.agenticInvestigations.enabled` | **`false`** |
| Service accounts | `xpack.security.serviceAccounts.enabled` | **`false`** on stateful; `true` in serverless defaults |

On a local ESS snapshot, AlertZero + the space setting is not enough. Proposals and agentic investigations never load unless you turn them on. Service accounts stay off too unless you set the flag.

## HTTP vs start-contract

`withAlertZeroEnabled` (AlertZero routes) checks **(2) + (3)** and then dependencies.

The AlertZero **start contract** used by security_solution (`isAlertTriageWorkerEnabled` / `disableAlertTriageWorker`, added around Kibana #295461) does **not** use that wrapper:

- Enabled-read: kill switch / no workers service / space setting off → `false`. No privilege check, no license/tier check.
- Disable: space setting (`assertAlertZeroEnabled`) + AlertZero write + managed-workflow update. No license/tier check, no `hasManageSecurity` (the Workers HTTP route has that extra).

## Related: alert analysis (not an AlertZero gate)

Triage Worker enable is also blocked unless alert analysis is on for the space.

- Readonly uiSetting `securitySolution:alertAnalysisWorkflowEnabled`, **default `false`**, `technicalPreview: true`.
- Plus the managed Alert Analysis workflow document must be `enabled`.
- Settings UI: Enterprise + rules edit + `advancedSettings.save`. Lives under `/rules/alert_analysis_workflow`.

That is a security_solution setting, not an AlertZero flag.

## What to flip locally

```yaml
xpack.alertzero.enabled: true
xpack.agenticInvestigations.enabled: true
xpack.proposals.enabled: true
xpack.security.serviceAccounts.enabled: true
```

Restart. Then:

1. Advanced Settings → Security Solution → **AlertZero** on for the space (or `uiSettings.overrides.securitySolution:enableAlertZero: true`).
2. Enterprise / trial license (or serverless Security Complete).
3. Role with AlertZero All (or Read).
4. Agent Builder is on by default; if you disabled it, turn `xpack.agentBuilder.enabled` back on.
