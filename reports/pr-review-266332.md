# PR #266332 — `[ResponseOps][PerAlertSnooze] Add alert severity field to alert documents`

**Author:** @js-jankisalvi · **Base:** `main` · **State:** OPEN
**Closes:** elastic/kibana-team#3170 · **Epic:** elastic/kibana-team#2999 (per-alert snooze)
**Downstream consumer (already merged):** elastic/kibana#264643 — per-alert snooze API

**Scale:** Substantive. Small line count (~60 LOC of real change), but it touches a shared platform contract (`alertFieldMap`, `@kbn/rule-data-utils`) consumed by several solutions, and it changes write-path stripping behavior in the alerting framework. The downstream surface is wider than the diff implies.

## Reconciling intent (issues + downstream PR) vs. diff

Reading the closing issue (#3170), the epic (#2999), and the merged snooze API PR (#264643) reveals an **internal inconsistency in the planned design** that this PR does not resolve:

- **Issue #3170** says: *"Define allowed severity values (e.g., `critical`, `high`, `medium`, `low`, `info`) as a shared enum/constant"* — five values.
- **Merged snooze API (#264643)** hardcodes exactly those five values for the `severity_equals` snooze condition (`x-pack/platform/plugins/shared/alerting/server/saved_objects/schemas/raw_rule/v12.ts:29-35`). It does **not** import the new `ALERT_SEVERITY_VALUES` constant — it inlines its own subset:

```30:35:x-pack/platform/plugins/shared/alerting/server/saved_objects/schemas/raw_rule/v12.ts
      schema.literal('critical'),
      schema.literal('high'),
      schema.literal('medium'),
      schema.literal('low'),
      schema.literal('info'),
```

- **This PR** ships an *8-value* `ALERT_SEVERITY_VALUES` array because the existing APM anomaly producer writes `warning | minor | major | critical`. Backward-compatibility for *existing producers* is reasonable, but the practical effect is that the canonical "shared enum" the issue asked for and the consumer the issue named are now subtly out of sync:
  - APM anomaly rules can emit `'warning'`, `'minor'`, `'major'` — values the snooze API will **reject** with a validation error if a user tries `severity_equals: 'warning'` against such a rule.
  - The new `ALERT_SEVERITY_VALUES` is currently unconsumed. Nothing in the merged snooze API reads it.

So the diff *delivers* what #3170 strictly asked for (a constant + the field), but it doesn't *integrate* with the consumer the issue pointed to. This is the most important finding from cross-checking the issues against the diff.

The issue title also reads "...field to alert documents **review**" (sic) — looks like a stray word, harmless.

## Ownership (team: `@elastic/security-detection-rule-management`)

- **Your team's files (4)** — co-owned with `@elastic/security-detection-engine`, `@elastic/response-ops`, and `@elastic/actionable-obs-team`:
  - `src/platform/packages/shared/kbn-rule-data-utils/src/alerts_as_data_severity.ts`
  - `src/platform/packages/shared/kbn-rule-data-utils/src/default_alerts_as_data.ts`
  - `src/platform/packages/shared/kbn-rule-data-utils/src/legacy_alerts_as_data.ts`
  - `src/platform/packages/shared/kbn-rule-data-utils/src/technical_field_names.ts`
- **Other teams' files (9)** — `@elastic/response-ops` only:
  - `src/platform/packages/shared/kbn-alerts-as-data-utils/**` (5 files: 1 field map + 4 generated schemas)
  - `x-pack/platform/plugins/shared/alerting/**` (4 files: `strip_framework_fields`, mapping test, integration snapshot)
- **Unowned:** none.

Your team is shared owner of the `kbn-rule-data-utils` constants and types. Detection-engine reads `ALERT_SEVERITY` directly (`build_alert.ts`) and ships `kibana.alert.severity` into `.alerts-security.alerts-*` via its own rule-registry-based pipeline, so the field-name move and type widening matter to Security even though no Security plugin file is in the diff. **Focus on the 4 `kbn-rule-data-utils` files; treat the rest as context.**

## Summary

Promotes `kibana.alert.severity` from a *legacy* (rule-registry) field to a *framework* (alerts-as-data) field. Three changes wrapped together:

1. **Constant moves** from `legacy_alerts_as_data.ts` to `default_alerts_as_data.ts` in `@kbn/rule-data-utils`. The string value is unchanged (`kibana.alert.severity`), so existing imports keep working through the package barrel.
2. **`alertFieldMap` gains `kibana.alert.severity` (`keyword`, optional)**, which (a) lands the field in the framework component template, and (b) — crucially — would *strip* the field from any framework rule producer's `report({ payload })` payload unless allowlisted. The PR adds it to `allowedFrameworkFields` in `stripFrameworkFields`, which is what makes opt-in safe.
3. **`AlertSeverity` type widens** from `'warning' | 'critical'` to a superset of every value currently emitted in the codebase: `info | low | medium | high | critical | warning | minor | major`, plus an exported ordered `ALERT_SEVERITY_VALUES` for downstream UX/API validation (the snooze condition schema in #264643 is the named consumer).

Stated intent and diff line up; nothing snuck in beyond the description.

## Files touched

- **Field constant relocation** (`kbn-rule-data-utils/src/{default,legacy}_alerts_as_data.ts`, `technical_field_names.ts`): moves `ALERT_SEVERITY` out of the legacy bucket. The package's root `index.ts` re-exports from both files via `export *`, so importers are unaffected.
- **Severity type & values** (`kbn-rule-data-utils/src/alerts_as_data_severity.ts`): adds 6 new severity literals, widens the `AlertSeverity` union to all 8, and exports `ALERT_SEVERITY_VALUES` ordered "highest → lowest".
- **Framework field map + generated schemas** (`kbn-alerts-as-data-utils/src/field_maps/alert_field_map.ts` and the four generated schema files): registers `kibana.alert.severity` as an optional `keyword` in the framework alerts component template. The four generated schemas are mechanical regenerations.
- **Framework write path** (`alerting/server/alerts_client/lib/strip_framework_fields.ts`): adds `ALERT_SEVERITY` to the allowlist so producers using `alertsClient.report` aren't silently stripped. Test updated.
- **Test fixtures** (`mapping_from_field_map.test.ts`, `alert_as_data_fields.test.ts.snap`): pure expectation refresh; no behavior assertions changed.

`legacy_alert_field_map.ts` — which still imports `ALERT_SEVERITY` from `@kbn/rule-data-utils` and registers it in `legacyAlertFieldMap` — is **not** touched. That's correct: legacy rule-registry consumers (Security detection engine, Observability rule registry) keep their existing mapping path unchanged.

## Flow trace — what happens to `kibana.alert.severity` for a framework rule type after this PR

1. A framework rule type author (e.g. an ES query rule) calls `alertsClient.report({ payload: { [ALERT_SEVERITY]: 'high' } })` from its executor.
2. Inside the alerts client, `stripFrameworkFields(payload)` is called. **Before this PR**: `kibana.alert.severity` was not in `alertFieldMap`, so it was *not* in the strip set and silently flowed through (any rule could write it). **After this PR**: it *is* in `alertFieldMap`, so it would be stripped — except `allowedFrameworkFields` now contains it, so it's preserved (`x-pack/platform/plugins/shared/alerting/server/alerts_client/lib/strip_framework_fields.ts:22`).
3. The flattened payload is written to the rule's alerts-as-data index (e.g. `.alerts-stack.alerts-default`).
4. On Kibana startup / consumer registration, `AlertsService` calls `getComponentTemplate({ fieldMap: alertFieldMap, ... })` (`alerting/server/alerts_service/alerts_service.ts:359`) to build the framework component template. With this PR, that template now includes `kibana.alert.severity: { type: 'keyword' }`. The service's `createOrUpdateComponentTemplate` path then PUTs the template *and* applies the new mapping to existing concrete indices on rolling upgrade.

For **Security detection** alerts: the path is different. Security uses `createSecurityRuleTypeWrapper` and its own rule-registry-based persistence — it does **not** call `alertsClient.report`, so `stripFrameworkFields` is not on its write path. `kibana.alert.severity` already shipped via `legacyAlertFieldMap` (line 133), and `build_alert.ts:243` writes it directly. **Net effect on Security: zero behavior change.** The constant simply now resolves through `default_alerts_as_data.ts` instead of `legacy_alerts_as_data.ts`.

For **APM anomaly**: it writes through the rule registry as well (`register_anomaly_rule_type.ts:337`), with values `warning | minor | major | critical`. Same story — unaffected at runtime.

## Assumptions

- **`alertFieldMap` and `legacyAlertFieldMap` co-defining `kibana.alert.severity` is harmless.** Both definitions are identical (`type: 'keyword'`, `array: false`, `required: false`), and an alerts-as-data index that uses both component templates (Security, Observability) will see the same mapping from both sources. I verified the two definitions match exactly, but worth flagging that this is now a duplicated source of truth — if someone changes one and forgets the other, drift becomes possible.
- **Rolling-upgrade mapping update is reliable for the framework alerts indices.** `AlertsService` calls `createOrUpdateConcreteWriteIndex` after publishing the new template; ES allows adding new top-level mappings to an existing index without reindex, so a node coming up on this Kibana version should pick up the new `kibana.alert.severity` mapping in `.alerts-stack.alerts-default` and similar framework indices.
- **No producer outside the documented set writes `kibana.alert.severity` today.** The PR's compatibility argument depends on this. Security (`low|medium|high|critical`) and APM anomaly (`warning|minor|major|critical`) are the two I confirmed; both fit within the new union. If a third producer is writing something exotic (e.g. numeric, or `'WARNING'` capitalized), it would still be accepted by ES (`keyword` is permissive) but would fall outside the typed union — invisible at runtime, surfaces as a TS error only where `AlertSeverity` is used.
- **`ALERT_SEVERITY_VALUES` ordering is a real ranking, not just an enumeration.** The array is documented as "highest to lowest" and the snooze epic plans to use it for ordered comparison. The chosen order is `critical > high > major > medium > minor > warning > low > info`. This implies that `'high'` (Security) is more severe than `'major'` (APM), and that `'warning'` (APM) is more severe than `'low'` (Security). That mapping is plausible but not obvious — see Open questions.
- **The `ALERT_SEVERITY_IMPROVING` boolean field semantics are not affected.** This PR adds the value field; the "improving" boolean (which depends on a prior-vs-current comparison) already existed and presumably depended on a producer-private severity value. Now that severity is a framework field, ResponseOps may eventually want to compute `severity_improving` framework-side — but that's not in this PR.

## Risks

Ordered by severity.

1. **`ALERT_SEVERITY_VALUES` is not consumed by the merged snooze API (#264643).** The PR description names that PR as the consumer, but `raw_rule/v12.ts:29-35` hardcodes the 5-value subset and never imports the new constant. Two consequences: (a) the `ALERT_SEVERITY_VALUES` ordering this PR introduces has no runtime effect today; and (b) APM anomaly rules emit `'warning'`, `'minor'`, `'major'` — which the merged snooze API will reject. Either the snooze API needs to migrate to `ALERT_SEVERITY_VALUES`, or `ALERT_SEVERITY_VALUES` should be trimmed to the canonical 5 (and the APM legacy values kept as separate exports for backward-compat reads). **Pick one before another consumer copies the wrong subset.**
2. **Cross-vendor severity ordering in `ALERT_SEVERITY_VALUES` is a quiet judgment call that downstream code will inherit.** Assuming risk #1 gets resolved by adopting `ALERT_SEVERITY_VALUES` in consumers, the chosen ordering — `critical > high > major > medium > minor > warning > low > info` — implies `'high'` (Security) > `'major'` (APM) and `'warning'` (APM) > `'low'` (Security). Plausible but not obviously correct, and it becomes the *de facto* ranking for any future `severity_change` evaluation that compares "improving" vs "worsening".
3. **`stripFrameworkFields` allowlist is the load-bearing piece.** Without the addition to `allowedFrameworkFields`, every framework rule producer would have its severity silently dropped. The change is correct, but the test (`strip_framework_fields.test.ts`) only adds an inline assertion and doesn't add a regression test that *fails* in the absence of the allowlist entry — easy to undo later in a refactor without anyone noticing. Low likelihood, but the failure mode is silent data loss.
4. **Framework component template updates on rolling upgrade.** The framework alerts component template changes shape (adds a field). For multi-node clusters that are mid-rolling-upgrade, the Kibana node still on the old version will overwrite the template back to its old shape if it restarts. That's true of every framework field map change and is not unique to this PR; the standard mitigation is "no roll-back after upgrade." Still, worth confirming with ResponseOps that no template version bump is expected for additive-only changes.
5. **Type widening could mask producer bugs.** Extending `AlertSeverity` from a 2-member union to 8 means TS won't catch a typo like `severity: 'majoor'` if a future producer ever uses the type. In practice no one in the repo currently imports the type from `@kbn/rule-data-utils` (only `monitoring` has a same-named local enum, unrelated), so the immediate blast radius is zero. Flagging it as a design point: the type is now a "what we accept" union, not a "what is canonical" union. The PR description says strict validation belongs at user-facing API schemas, which is a defensible split — but the type itself no longer enforces any canonical contract.
6. **Generated schemas (`alert_schema.ts` etc.) typed as `schemaString`, not a literal union.** Consumers of these io-ts schemas won't get value validation either. Consistent with the "permissive at write, strict at API edge" approach.

## Open questions

- **The merged snooze API (#264643) doesn't import `ALERT_SEVERITY_VALUES` and doesn't accept `'warning' | 'minor' | 'major'`.** Issue #3170 explicitly said the goal of this PR was to define values for the snooze API to consume. Is there a follow-up planned to migrate `raw_rule/v12.ts` to `ALERT_SEVERITY_VALUES`? If yes, that follow-up will also need to handle the SO migration question (an existing snoozed-instance with `severity_equals: 'critical'` is fine, but if the constant set ever shrinks back to 5 in v13, what happens to v12 records?). If no, why ship the 8-value array — should the PR just export the 5 canonical values and treat APM's `warning|minor|major` as a separate, *non-canonical* set of constants for read-side compatibility only?
- **Is the `ALERT_SEVERITY_VALUES` ordering definitive, or a placeholder?** Specifically: is `'high' > 'major'` and `'warning' > 'low'` the intended cross-vendor ordering? If a Security PM and an Observability PM independently picked these labels, did anyone reconcile the implied ranking? Worth a comment in the file or a link to a doc that establishes this.
- **Epic #2999 mentions "alert severity is updated by each rule execution" but issue #3170 explicitly scopes rule-type-level severity opt-in as out of scope ("done by rule type owner"). Which rule types are actually committed to opting in?** If the answer is "Security and APM" (which already write the field today), this PR is a no-op behavior-wise on real workloads — the framework-field promotion only matters for *new* opt-ins, and there are none in this PR. Worth confirming with the epic owner that this is expected.
- **Why no `severity_improving` parity?** The PR moves the value field but `ALERT_SEVERITY_IMPROVING` was already in `default_alerts_as_data.ts` before this PR (line 34). If severity is now a framework concept, would it make sense to compute `severity_improving` framework-side from the previous-vs-current value? Probably out of scope, but worth mentioning in the epic.
- **Should `legacyAlertFieldMap` drop `kibana.alert.severity` now that it's in the framework template?** Keeping both is safer (and the PR explicitly chooses that), but it duplicates the source of truth. Is there a planned follow-up to remove the legacy entry once all rule-registry consumers are migrated, or is "legacy will live forever" the answer? Worth a comment in code either way.
- **Test coverage for `stripFrameworkFields`:** the existing test now asserts `'kibana.alert.severity': 'high'` survives, but it does so as part of a larger payload assertion. Would a dedicated assertion (or a parameterized test of every allowlisted field) reduce regression risk?

## Notes for your codebase map

- **Two parallel alerts-as-data plumbing paths still coexist.** The framework path (`alertsClient.report` → `stripFrameworkFields` → `alertFieldMap`-derived component template) is the modern one. The rule-registry path (`createSecurityRuleTypeWrapper`, `legacyAlertFieldMap`-derived component template) is what Security detection engine and APM anomaly still use. Fields can live in *both* mappings simultaneously as long as the definitions agree — that's how this PR sidesteps a migration.
- **`stripFrameworkFields` is a quiet but important boundary.** Anything in `alertFieldMap` is stripped by default from rule-author payloads unless explicitly allowlisted. New framework fields that rule authors are *meant* to set must be added to `allowedFrameworkFields` in the same change. Easy to miss in code review.
- **`@kbn/rule-data-utils` is split-by-history, not by clean concern.** `default_alerts_as_data.ts` is "framework alerts fields", `legacy_alerts_as_data.ts` is "rule-registry-only fields", and `technical_field_names.ts` re-exports from both for back-compat. The package barrel `export *`s all of them, so import paths are stable across moves like this one. When adding/moving constants, check both files plus `technical_field_names.ts` (it has its own import list and an exported `fields` record).
- **`ALERT_SEVERITY_VALUES` is a new cross-domain contract.** The ordered array implicitly ranks Security severity labels and Observability/APM severity labels against each other. Future code that uses `>=` / `<=` comparisons on alert severity will inherit that ranking — keep an eye on consumers of this constant.
- **CODEOWNERS for `kbn-rule-data-utils` is shared four ways** (`security-detection-rule-management`, `security-detection-engine`, `response-ops`, `actionable-obs-team`). Any change to severity, alert state, or rule-execution constants here will pull in reviewers from all four teams; reviews tend to be light because most teams only care about the subset they consume.
