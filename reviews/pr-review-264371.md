# PR #264371 — Bulk install prebuilt rules POC

**Scale:** Substantive PR. Adds a brand-new public method (`rulesClient.bulkCreateRules`) on a shared platform plugin, plus a security-side wrapper, plus a swap of the prebuilt-rule installation hot path.

## Summary

Replaces the per-rule `createPrebuiltRule` loop in the prebuilt-rule installation handler with a new bulk path. Adds `RulesClient.bulkCreateRules` in the alerting plugin (one `savedObjectsClient.bulkCreate` per batch, no task scheduling, no API key generation, disabled-only by design) and a thin security-solution wrapper `bulkCreatePrebuiltRules` that converts `PrebuiltRuleAsset[]` into the alerting bulk shape and re-pairs results back to their source assets. The handler now batches in chunks of 50 and the legacy `createPrebuiltRules` promise-pool helper is no longer wired into the install flow (file is left in place but its only call site is removed).

The PR description's stated intent ("speed up prebuilt rule installation, only handle disabled rules") matches the diff.

## Files touched

**New alerting bulk method** (the substantive part)
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/{bulk_create_rules.ts,types.ts,index.ts,bulk_create_rules.test.ts}` — new method + 10-case test file.
- `server/index.ts`, `rules_client/rules_client.ts`, `rules_client.mock.ts` — public API surface, RulesClient class wiring, mock.

**Security solution wiring**
- `detection_rules_client/methods/bulk_create_rules.ts` — new wrapper that calls the alerting bulk method and re-pairs outputs to the original `PrebuiltRuleAsset` via a `source` field.
- `detection_rules_client/detection_rules_client.ts`, `detection_rules_client_interface.ts`, `__mocks__/detection_rules_client.ts` — exposes `bulkCreatePrebuiltRules` on the client.
- `prebuilt_rules/api/perform_rule_installation/perform_rule_installation_handler.ts` — switches the install loop from `createPrebuiltRules` (promise pool, one ES write per rule) to `detectionRulesClient.bulkCreatePrebuiltRules`. `BATCH_SIZE` lowered from 100 → 50.

## Flow trace

`POST /internal/detection_engine/prebuilt_rules/installation/_perform`:

1. `performRuleInstallationHandler` resolves clients, fetches `allLatestVersions` and `currentRuleVersions`, filters to `allInstallableRules` (handler.ts:53–61).
2. Builds `ruleInstallQueue` for `SPECIFIC_RULES` or `ALL_RULES`; `excludeLicenseRestrictedRules` is run for the latter (handler.ts:97–99).
3. **Loop change:** for each batch of 50, `ruleAssetsClient.fetchAssetsByVersion` → `detectionRulesClient.bulkCreatePrebuiltRules({ rules: ruleAssets })` (handler.ts:101–112).
4. Wrapper `bulkCreateRules` (security side) — for each asset:
   - `validateMlAuth(mlAuthz, item.rule.type)`; failures captured per-source.
   - `applyRuleDefaults` + `convertRuleResponseToAlertingRule`, `enabled` force-disabled, `id = uuidv4()` recorded in `idToSource` map (bulk_create_rules.ts:78–101).
5. Single `rulesClient.bulkCreateRules<RuleParams>({ rules: bulkInputs })` round-trip.
6. `bulkCreateRules` (alerting side):
   - Rejects every input with `data.enabled === true` upfront, pushing per-rule errors with `ENABLED_RULE_REJECTION_MESSAGE` (alerting bulk_create_rules.ts:447–459). The security wrapper already force-disables, so this branch is only hit by other future callers.
   - `Promise.all` over `prepareRule(...)` for each remaining input. `prepareRule` runs the same gauntlet `createRule` does for disabled rules: `addGeneratedActionValues`, `createRuleDataSchema.validate`, `ruleTypeRegistry.get`, `authorization.ensureAuthorized` (with audit-event-on-error), `ensureRuleTypeEnabled`, `validateRuleTypeParams`, `validateActions`, `validateAndAuthorizeSystemActions`, min-interval enforce/warn, `extractReferences`, `transformRuleDomainToRuleAttributes`, `apiKeyAsRuleDomainProperties(null, username, false)`, success audit event, `updateMeta`. Per-rule failures are isolated via try/catch and pushed as errors (alerting bulk_create_rules.ts:549–709).
   - Single `bulkCreateRulesSo({ savedObjectsClient, bulkCreateRuleAttributes })` call which is just `unsecuredSavedObjectsClient.bulkCreate(...)`.
   - Walks `bulkCreateResult.saved_objects` by index (`saved_objects[idx]` → `preparedRules[idx]`), splitting into `rules` and `errors`.
7. Wrapper re-keys results/errors back to the source `PrebuiltRuleAsset` via `idToSource.get(rule.id)`.
8. Handler reshapes wrapper output `{ source, result|error }` → legacy `{ item, result|error }` envelope so `aggregatePrebuiltRuleErrors` and the response builder are unchanged (handler.ts:117–122).

## Assumptions

- **Order preservation in `savedObjectsClient.bulkCreate`.** The walk at `bulk_create_rules.ts:501` uses `(so, idx) => preparedRules[idx]` to attribute SO-row errors back to the right rule. This relies on the SO client returning `saved_objects` in input order. If that ever changes, every per-row error would be mis-attributed (wrong id/name in the error object, wrong source asset in the wrapper).
- **`bulkCreate` doesn't reject the whole batch on a per-row failure.** The success/error split assumes individual row errors come back inline (e.g. 409 conflicts) and only catastrophic failures throw. Existing usage of `bulkCreate` elsewhere in the codebase backs this up, but a partial-batch path is what makes the new approach interesting.
- **No `validateScheduleLimit` is needed.** `createRule` only runs it when `data.enabled === true`, and the bulk method only accepts disabled rules — so this is fine, but it does mean rules created via `bulkCreateRules` and later enabled via `bulkEnableRules` would have bypassed the schedule-limit circuit breaker check at create time. Whether `bulkEnableRules` re-checks is worth confirming.
- **No API key creation, ever.** `apiKeyAsRuleDomainProperties(null, username, false)` is hard-coded. Matches `createRule` for disabled rules, but means the rule is persisted without `apiKey`, `apiKeyOwner`, `apiKeyCreatedByUser`, or `uiamApiKey` — and crucially, **without `addMissingUiamKeyTagIfNeeded`** being called (see Risks).
- **`SkippedRuleInstall`/dedupe is not affected.** The bulk method only changes how rules are written, not which rules are queued.
- **Caller correctness for the wrapper's `source` re-keying.** `bulkCreateRules` (security side) assumes every wrapper-generated `uuidv4()` id is unique (it is) and that alerting's `prepareRule` uses `options.id` verbatim. It does (`id = options?.id || SavedObjectsUtils.generateId()`).

## Risks

Ordered by severity:

1. **Serverless UIAM tag divergence.** `createRule` calls `addMissingUiamKeyTagIfNeeded(tags, uiamApiKey, apiKeyCreatedByUser, isServerless, featureFlags)` even for disabled rules. With `uiamApiKey = null` and `apiKeyCreatedByUser = false` in serverless with `PROVISION_UIAM_API_KEYS_FEATURE_FLAG` enabled, the tag IS appended. The new `bulkCreateRules` (alerting side) skips this entirely. Net effect: prebuilt rules installed via the bulk path in serverless will be missing the `MISSING_UIAM_API_KEY_TAG` that single-installed prebuilt rules get today. Whether that's intended or a bug depends on what the tag is used for downstream — worth a deliberate decision before this lands, given how subtle this divergence is.
2. **New public alerting API with broad implications.** `RulesClient.bulkCreateRules` is now exported from `@kbn/alerting-plugin/server` and any consumer can call it. The "disabled rules only" contract is enforced via per-input rejection rather than a type-system constraint. A caller could pass a mix and only get errors back for the enabled ones. The error message is correct but the surface area is now larger than the prebuilt-rule use case.
3. **Two prebuilt-rule install paths now coexist.** `createPrebuiltRules` (promise pool, single creates) is no longer used in the install handler but the file still exists and is exported via `IDetectionRulesClient.createPrebuiltRule` (singular). Any other site still using the singular path will diverge in behavior from bulk installs (e.g. UIAM tag, audit-log timing, possibly schedule scheduling if the singular path ever creates enabled rules). Worth grepping for remaining `createPrebuiltRule` (singular) callers and confirming they're either dead or intentionally kept.
4. **`Promise.all` over the whole batch.** `prepareRule` is invoked over all 50 inputs concurrently. The previous promise pool used concurrency `MAX_RULES_TO_UPDATE_IN_PARALLEL = 20`. So this PR increases the concurrent in-flight load on `actionsClient.getBulk`, `actionsClient.listTypes`, `authorization.ensureAuthorized`, `extractReferences`, etc. by 2.5×. The PR description already notes higher memory usage; this is a likely cause. Could be mitigated by using `pMap` with a concurrency cap inside `prepareRule` if memory becomes a problem at higher batch sizes.
5. **Per-row SO error → re-attribution by array index.** Documented in Assumptions but worth restating: a future change in the SO client that filters or reorders the response would silently produce wrong-id errors. No assertion or sanity check exists. Cheap to add (e.g. compare `so.id === preparedRules[idx].ruleId`).
6. **Test coverage gap on the security side.** The new alerting `bulkCreateRules` has a thoughtful 10-case test file. The security wrapper (`detection_rules_client/methods/bulk_create_rules.ts`) and the modified `performRuleInstallationHandler` have no new unit tests. The wrapper has nontrivial logic (id-source mapping, ML auth pre-check, error reshaping) that is currently only exercised end-to-end. There's also no test for `detection_rules_client.bulkCreatePrebuiltRules` analogous to `detection_rules_client.create_prebuilt_rule.test.ts`.
7. **Audit log success event is emitted before persistence.** `prepareRule` logs `outcome: 'unknown'` then the bulk write happens later. This matches `createRuleSavedObject` ordering, so it's not a regression — but if a per-row SO error comes back, you now have a success-`unknown` audit event followed by no follow-up failure event for that rule. The single-create flow has the same property, so this is a pre-existing pattern.

## Open questions

- Is the missing `addMissingUiamKeyTagIfNeeded` call in serverless deliberate? If so, is it documented anywhere that bulk-created disabled rules opt out of the missing-UIAM-key tag?
- Should the SO bulkCreate response order be asserted (rather than implicitly trusted) before mapping back to `preparedRules[idx]`?
- Why `BATCH_SIZE = 50` over the previous `100`? The PR mentions higher memory; is 50 the empirical sweet spot or a placeholder?
- Is the legacy `createPrebuiltRules` (plural) helper now dead code? If so, remove it; if not, what still calls it and does that path also need bulk treatment?
- Do any other consumers of `detectionRulesClient.createPrebuiltRule` (singular) need to migrate too, to avoid behavior drift between singular and bulk paths?
- Is there a ticket to follow up with `bulkEnableRules` integration so the prebuilt-rule install path can also handle the "install + enable" UX in one shot? Right now the alerting bulk method explicitly punts on this.
- Should the alerting bulk method's `enabled === true` rejection happen at the type level (e.g. require `enabled: false | undefined`) rather than at runtime per-input? Would catch misuse at compile time.

## Notes for your codebase map

- The alerting plugin's "rule methods" follow a strict structure: `application/rule/methods/<verb>/{<verb>_rules.ts, types.ts, schemas.ts, index.ts, *.test.ts}`. New methods are wired into `RulesClient` in `rules_client.ts` and into `rules_client.mock.ts`, and types are re-exported from `server/index.ts`.
- Public alerting types (`BulkOperationError`, `Rule`, etc.) are the contract surface — adding to it (as this PR does with `BulkCreateRulesParams/Result/Item`) creates downstream ABI obligations.
- `createRuleSavedObject` is the canonical single-create helper that the new bulk method intentionally bypasses; its responsibilities split into "audit + persist + (if enabled) schedule task + cleanup" — the bulk method only needed the persist part because it forbids enabled rules.
- Detection-rule clients in security_solution wrap alerting's `RulesClient` and add their own response shape (`RuleResponse` via `convertAlertingRuleToRuleResponse`). New bulk operations on the alerting side need a parallel wrapper here to be useful to the prebuilt-rule install/upgrade flows.
- The prebuilt-rule install handler has historically used a `promise_pool` with concurrency `MAX_RULES_TO_UPDATE_IN_PARALLEL = 20`. Switching to a true bulk SO write trades concurrent ES round-trips for one larger round-trip with higher in-process memory pressure during the prepare phase.
- The per-rule "source re-pairing" pattern (`source: TSource` on input, returned verbatim alongside result/error) is a clean way to propagate caller context across a wrapper that internally re-keys by SO id. Worth reusing for future bulk wrappers (bulk upgrade, bulk import, etc.).
