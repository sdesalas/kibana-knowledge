# PR #270446 — [Security Solution] Instrument DetectionRulesClient with change tracking

**Author:** @maximpn · **Base:** `main` · **State:** OPEN · 44 files, +1081 / −285

**Scale:** Substantive PR. Cross-team (Alerting + Security Solution), generic type changes to a shared package, plumbing through ~10 call sites, plus new unit + FTR tests.

## Ownership (team: `@elastic/security-detection-rule-management`)

- **Your team's files (~30):** everything under `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/{rule_management,prebuilt_rules}/...`, the new `common/detection_engine/rule_management/rule_change_tracking.ts`, the new `change_tracking.test.ts` and FTR `change_tracking.ts`, the deleted `rule_history.ts`. **Main review focus.**
- **Other teams' files (~7):**
  - `src/platform/packages/shared/kbn-alerting-types/rule_types.ts` → `@elastic/response-ops` (alerting platform)
  - `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/{bulk_delete,bulk_edit,bulk_edit_params,common_utils,create,update}/...` → `@elastic/response-ops`
  - `x-pack/platform/plugins/shared/alerting/server/rules_client/{common/bulk_edit/...,rules_client.ts}` → `@elastic/response-ops`
  These are signature changes (renaming `changeTrackingAction` → `changeTracking` and making the type generic). They are cross-team but small; still worth a careful sanity check because they change a public-ish RulesClient signature.
- **Unowned:** none material.

## Summary

This PR wires *what kind of action* (and optionally *how big the bulk was*) all the way from Security Solution API routes → `DetectionRulesClient` → alerting `RulesClient` → `@kbn/change-history`, so that the rule history UI/API can later show entries like `rule_install`, `rule_upgrade`, `rule_import`, `rule_revert` instead of just the alerting defaults (`rule_create`/`rule_update`).

Mechanically it does three things:

1. Generalises the alerting `RuleChangeTracking` type to `RuleChangeTracking<ChangeAction extends string = string>` so consumers can plug in their own enum (Security uses `SecurityRuleChangeTrackingAction`).
2. Threads an optional `changeTracking: { action?, bulkCount? }` parameter through `create_rule`, `update_rule`, `bulk_edit_rules`, `bulk_edit_rule_params`, `bulk_delete_rules`, and into `logRuleChanges`. Where the action is unambiguous (delete, bulk edit/delete) the type forbids `action`; where it's caller-dependent (create/update) the default (`ruleCreate` / `ruleUpdate`) is preserved when not overridden.
3. Has every Security write path that ultimately calls `RulesClient.create/update/bulkDelete` provide the right Security-domain action (`ruleInstall`, `ruleUpgrade`, `ruleImport`, `ruleRevert`) and, where it has the info, the original bulk total before chunking.

Intent vs diff: matches. The PR is exactly what the linked issue #262502 ("Detections APIs" → install/upgrade/import/revert/bulk) and the body promise. `duplicate` action is defined in the enum and exercised by a unit test, but no production caller wires it yet — that's noted in the test but not in the PR body. It does also do a small refactor of the FTR test file (rename + extend `rule_history.ts` → `change_tracking.ts`), which is fine but slightly outside scope.

It is gated behind a feature flag in `@kbn/change-history` (set to `false` in main), so the whole change is effectively dormant at runtime until that flag flips.

## Files touched (grouped by role)

- **Shared alerting types** — `kbn-alerting-types/rule_types.ts`: introduces the generic `RuleChangeTracking<Action>` interface that the rest of the wiring depends on.
- **Alerting server: rule methods** — `create_rule.ts`, `update_rule.ts`, `bulk_delete/bulk_delete_rules.ts`, `bulk_edit/bulk_edit_rules.ts`, `bulk_edit_params/bulk_edit_rule_params.ts`, `common_utils/log_rule_changes.ts`. They accept `changeTracking?` and forward `action` + `metadata.bulkCount` into `logRuleChanges`. `log_rule_changes` also gains an `isEmptyObject` predicate so that all-undefined metadata isn't serialised as `data: { metadata: {} }`.
- **Alerting server: rules client plumbing** — `rules_client/common/bulk_edit/bulk_edit_rules.ts`, `…/bulk_edit_rules_occ.ts`, `rules_client/rules_client.ts`: renames the old `changeTrackingAction` / `totalNumOfRules` pair to the new `changeTracking` object, and changes `bulkDeleteRules` to accept the new `BulkDeleteRulesParams` (extends the request body with `changeTracking?`).
- **Security common (new)** — `common/detection_engine/rule_management/rule_change_tracking.ts`: declares `SecurityRuleChangeTrackingAction` enum and `SecurityRuleChangeTracking<Action>` alias of the generic alerting type.
- **Security DRC interface + impl** — `detection_rules_client_interface.ts`, `detection_rules_client.ts`, and `methods/{create_rule,update_rule,patch_rule,bulk_delete_rules,import_rule,import_rules,revert_prebuilt_rule,upgrade_prebuilt_rule,rbac_methods/update_rule_with_read_privileges}.ts`: every mutating method now accepts `changeTracking?: SecurityRuleChangeTracking`. Methods with a fixed semantic (`importRule`, `upgradePrebuiltRule`, `revertPrebuiltRule`) inject the right default action themselves; create/update pass through whatever the caller provides.
- **Security prebuilt-rule integration code** — `prebuilt_rules/logic/rule_objects/{create,upgrade,revert}_prebuilt_rules.ts`, `prebuilt_rules/logic/integrations/{install_endpoint_security_prebuilt_rule,install_promotion_rules}.ts`: pass the right `{ action, bulkCount }` payload into the DRC. `createPrebuiltRules` also injects `bulkCount: rules.length` as a default that callers can override.
- **Security API route handlers** — `rule_management/api/rules/import_rules/route.ts`, `prebuilt_rules/api/perform_rule_installation/perform_rule_installation_handler.ts`, `…/perform_rule_upgrade/perform_rule_upgrade_handler.ts`, `…/revert_prebuilt_rule/revert_prebuilt_rule_handler.ts`, `install_prebuilt_rules_and_timelines/legacy_create_prepackaged_rules.ts`: each handler is responsible for computing `bulkCount` from its own input list before chunking and passing it into the DRC.
- **Tests** — new `detection_rules_client.change_tracking.test.ts` (DRC unit tests for action/bulkCount propagation), additions to existing DRC unit tests for create/import/upgrade/prebuilt, and a renamed FTR `change_tracking.ts` that subsumes the old `rule_history.ts` and adds `action` + `metadata.bulkCount` assertions per write path.

## Flow trace — prebuilt rule install (`PUT /internal/detection_engine/prebuilt_rules/installation/_perform`)

1. `performRuleInstallationHandler` builds `ruleInstallQueue` and computes `changeTracking = { action: ruleInstall, bulkCount: ruleInstallQueue.length }` *before* it begins chunking with `BATCH_SIZE = 100`. (`perform_rule_installation_handler.ts:110-115`).
2. The handler loops, splicing 100 rules at a time and calling `createPrebuiltRules(detectionRulesClient, ruleAssets, changeTracking, logger)`.
3. `createPrebuiltRules` (`prebuilt_rules/logic/rule_objects/create_prebuilt_rules.ts`) runs them through `initPromisePool` and for each rule calls `detectionRulesClient.createPrebuiltRule({ params: rule, changeTracking: { bulkCount: rules.length, ...changeTracking } })`. The chunk-local default (`rules.length`) gets *overridden* by the handler-supplied total — that's the correct behaviour because each per-rule history entry should record the user-visible total, not the chunk size.
4. `detectionRulesClient.createPrebuiltRule` forwards `changeTracking` straight into `methods/create_rule.ts`, which calls `rulesClient.create({ data, options: { id }, changeTracking, allowMissingConnectorSecrets })`.
5. Alerting's `create_rule.ts` reaches `logRuleChanges({ … changesContext: { action: changeTracking?.action ?? ruleCreate, timestamp, metadata: { bulkCount: changeTracking?.bulkCount } } })`. With the Security caller's action set, this becomes `action: 'rule_install', metadata: { bulkCount: <total> }`.
6. `logRuleChanges` skips changes whose rule type does not have `trackChanges`, and on the remaining ones calls `changeTrackingService.logBulk(changes, { action, spaceId, ...(isEmptyObject(metadata) ? {} : { data: { metadata } }) })`. The new `isEmptyObject` check matters because most non-prebuilt callers will pass `{ bulkCount: undefined }` and would otherwise log an empty `metadata: {}`.

Same shape applies to `_perform` (upgrade), `revert`, `_import`, and the two integration paths (endpoint security and promotion rules).

## Assumptions

- **`changeTrackingService` is the only off-switch.** `logRuleChanges` short-circuits when there's no `changeTrackingService` on the context, and the feature is gated by `xpack.alerting.ruleChangeTracking.enabled` + the `ruleChangesHistoryEnabled` experimental flag + the `FEATURE_ENABLED` constant in `@kbn/change-history` (currently `false` in main per the PR's "How to test"). Everything else assumes that with the flag off the new code paths are no-ops.
- **`bulkCount` semantics = total before chunking.** The PR consistently treats `bulkCount` as "what the user asked for", computed once at the handler / DRC entry, then propagated through chunking and OCC retries. This relies on callers always providing it from outside the chunking loop — internal defaults inside `createPrebuiltRules` / `bulkDeleteRules` use chunk-local length only as a fallback.
- **Type-change upgrades produce a `rule_delete` + `rule_upgrade` pair.** `upgradePrebuiltRule` does `rulesClient.delete({ id })` followed by `rulesClient.create({ …, changeTracking: { action: ruleUpgrade, … } })` when the rule type changes. The delete is *not* annotated, so the history for that rule_id will show one record with default `rule_delete` and then a `rule_upgrade`. Same for the type-change branch in `upgrade_prebuilt_rule.test.ts`, which doesn't assert the delete record.
- **`logRuleChanges` metadata type widens to allow `undefined`.** The metadata index type changed from `Record<string, number|boolean|string>` to `Record<string, number|boolean|string|undefined>`. Callers and downstream consumers that read `metadata` are expected to tolerate `undefined` fields. The new `isEmptyObject` predicate at least prevents `{ bulkCount: undefined }` from being written out as a real metadata object.
- **No caller of `RulesClient.bulkEditRules` outside this PR was passing the now-removed `changeTrackingAction` / `totalNumOfRules` options.** The renaming is source-incompatible; nothing in the diff suggests the PR searched cross-repo for external callers.
- **Generic `RuleChangeTracking<ChangeAction extends string>` is structurally compatible.** Because `string` is the default, code that imports the un-parameterised type continues to type-check. `SecurityRuleChangeTracking<never>` is used in spots where the caller is forbidden from passing an `action` (delete/import/upgrade/revert) — useful, but relies on callers not constructing the object as `RuleChangeTracking` and assigning it across the boundary.

## Risks (ranked)

1. **`legacy_create_prepackaged_rules.ts` — `bulkCount` is computed from the wrong list for the upgrade call.**

   ```77:96:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/api/install_prebuilt_rules_and_timelines/legacy_create_prepackaged_rules.ts
     const installChangeTracking = {
       action: SecurityRuleChangeTrackingAction.ruleInstall,
       bulkCount: rulesToInstall.length,
     };
     const ruleCreationResult = await createPrebuiltRules(
       detectionRulesClient,
       rulesToInstall,
       installChangeTracking,
       logger
     );
     …
     const upgradeChangeTracking = {
       bulkCount: rulesToInstall.length, // <— copy-paste bug; should be rulesToUpdate.length
     };
     await upgradePrebuiltRules(detectionRulesClient, rulesToUpdate, upgradeChangeTracking, logger);
   ```

   This is the only place in the PR where the bulk-count number diverges from the rule list it accompanies. End result: legacy prepackaged-rule upgrades will show a `bulkCount` reflecting the number of *new* rules, not the number of *upgraded* rules. Worth fixing before merge; it's invisible today because of the feature flag.

2. **`importRule` overwrite branch loses `bulkCount` (confirmed — no fallback exists in alerting).**

   ```71:75:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/import_rule.ts
       const updatedRule = await rulesClient.update({
         id: existingRule.id,
         data: convertRuleResponseToAlertingRule(ruleWithUpdates, actionsClient),
         changeTracking: { action: SecurityRuleChangeTrackingAction.ruleImport },
       });
   ```
   vs. the create branch right below:
   ```83:91:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/import_rule.ts
     return createRule({
       …
       changeTracking: { ...changeTracking, action: SecurityRuleChangeTrackingAction.ruleImport },
     });
   ```
   Importing N rules into an empty system records `bulkCount: N` on every history entry, but importing the same N rules a second time with `overwrite=true` records no `bulkCount`. Easy fix — `{ ...changeTracking, action: ruleImport }` in both branches.

   Verified there is no rescue path inside alerting: `updateRule` simply forwards `metadata: { bulkCount: changeTracking?.bulkCount }` into `logRuleChanges` (`update_rule.ts:389-399`), and the new `isEmptyObject` predicate in `log_rule_changes.ts` then strips the whole `data` field when every metadata value is `undefined`. The unit test `log_rule_changes.test.ts:358 "omits metadata when nothing is provided"` pins exactly this behaviour. The FTR test "records rule_import when overwriting an existing rule" only asserts `action`, so this gap isn't caught at any layer.

   Bonus cleanup while in the area: four `// Single-rule callers fall back to ruleSOs.length for bulkCount.` comments are stale and contradict the actual assertions next to them — see `create_rule.test.ts:4995`, `snooze_rule.test.ts:246`, `unsnooze_rule.test.ts:226`, `update_rule_api_key.test.ts:626`. They reflect the *old* docstring in `log_rule_changes.ts` (`Default: ruleSOs.length when not provided`) that this PR explicitly removed.

3. **Public alerting `bulkEditRules` / `bulkDeleteRules` signatures changed.** Renaming `changeTrackingAction` → `changeTracking` and the new `BulkDeleteRulesParams` type are source-breaking for any out-of-tree consumer of `RulesClient.bulkEdit` / `bulkDeleteRules` that was already passing change-tracking metadata. In-tree it looks fine (the only previous user of `changeTrackingAction` was the alerting bulk-edit wrapper itself), but downstream solutions plug into RulesClient and `@elastic/response-ops` should at minimum eyeball this.

4. **`logRuleChanges` index-type widening.** Changing `Record<string, number|boolean|string>` to `Record<string, number|boolean|string|undefined>` is permissive: callers can now silently write `metadata: { foo: undefined }`. The new `isEmptyObject` only catches the all-undefined case, not the mixed case where one field is real and another is undefined. If `changeTrackingService.logBulk` or its persistence layer does anything with `Object.entries(metadata)` it should be reviewed for `undefined`-safety. Low likelihood given the metadata field is small today, but worth a check.

5. **Type-change upgrade emits a misleading `rule_delete` history record.** Unrelated to this PR (the `rulesClient.delete` was already there), but this PR is the first time the records become user-visible and labeled. Worth deciding whether the delete record should be suppressed or relabelled as `rule_upgrade`.

6. **`createCustomRule` accepts a caller-supplied `action` but no production caller passes one.** The new test exercises it with `ruleDuplicate`. If no follow-up wires duplicate / clone routes to pass `{ action: ruleDuplicate }`, this surface is unused but encourages misuse (e.g., a caller could pass `ruleInstall` for a custom rule). Worth being explicit in the issue about which paths still need wiring (the linked epic checklist suggests duplicate, export, delete, plain create/update via PUT/PATCH are all still TODO).

## Action-mapping audit — which DRC paths fall back to alerting defaults

Cross-referenced every production caller of an instrumented DRC mutator against `SecurityRuleChangeTrackingAction` (`ruleInstall`, `ruleUpgrade`, `ruleDuplicate`, `ruleImport`, `ruleRevert`).

| Caller | DRC method | Action logged | Should be | Status |
|---|---|---|---|---|
| `siem_migrations/.../installation.ts:installCustomRules` | `createCustomRule` | `rule_create` (alerting default) | `ruleInstall` (or new SIEM-migration action) | **Missed** — semantically these are installs |
| `bulk_actions/route.ts:duplicate` (line 297) | none — calls `rulesClient.create` directly, bypassing DRC | `rule_create` (alerting default) | `ruleDuplicate` | **Missed + bypasses DRC** — `ruleDuplicate` is currently dead surface |
| `bulk_actions/route.ts:duplicate` followup `rulesClient.update` (exceptions) | none | `rule_update` (alerting default) | `ruleDuplicate` | **Missed + bypasses DRC** |
| `prebuilt_rules/logic/rule_objects/create_prebuilt_rules.ts` callers (×4) | `createPrebuiltRule` | `ruleInstall` (set externally by each caller) | `ruleInstall` | OK today, **fragile** — should be hard-coded inside DRC like `importRule` / `upgradePrebuiltRule` / `revertPrebuiltRule` |
| `rule_management/api/rules/create_rule/route.ts` (PUT `/api/detection_engine/rules`) | `createCustomRule` | `rule_create` (alerting default) | `rule_create` | OK — generic user create |
| `rule_management/api/rules/update_rule/route.ts` (PUT `/api/detection_engine/rules`) | `updateRule` | `rule_update` (alerting default) | `rule_update` | OK — generic user edit |
| `rule_management/api/rules/patch_rule/route.ts` (PATCH `/api/detection_engine/rules`) | `patchRule` | `rule_update` (alerting default) | `rule_update` | OK — generic user patch |
| `rule_management/api/rules/bulk_actions/route.ts:delete` | `bulkDeleteRules` | `rule_delete` (alerting default) | `rule_delete` | OK — no `ruleDelete` in enum, type is `<never>` so callers cannot override |

Bonus: the PR adds `ruleDuplicate` to the enum and has a unit test that exercises it via `createCustomRule({ changeTracking: { action: ruleDuplicate } })` (`change_tracking.test.ts:78-88`), but the only production duplicate path (`bulk_actions/route.ts:297`) never goes through the DRC. So today the `ruleDuplicate` enum value can only appear in tests.

## DRC endpoints still not instrumented (gap analysis)

The linked issue #262502 lists the full target surface (`Create`, `Update`, `Delete`, `Bulk actions`, `Import`, `Export`, `Prebuilt install/upgrade`, `Reverting changes`). This PR covers most of it but several DRC methods (and a few non-DRC write paths the issue mentions) still log unannotated:

| DRC method / surface | Instrumented in this PR? | Today's behaviour | Comment |
|---|---|---|---|
| `createCustomRule` | ✅ accepts `changeTracking` | Falls back to `rule_create`; SIEM migration caller doesn't set it | Wired, but caller coverage incomplete (see table above) |
| `createPrebuiltRule` | ✅ accepts `changeTracking` | All callers set `ruleInstall` | Fragile (no internal default) |
| `updateRule` | ✅ accepts `changeTracking` | Falls back to `rule_update` | Sufficient — no domain action exists |
| `patchRule` | ✅ accepts `changeTracking` | Falls back to `rule_update` | Sufficient — no domain action exists |
| `deleteRule` (singular) | ❌ **NOT instrumented** | Alerting's `delete_rule.ts` doesn't even call `logRuleChanges` — **nothing is logged at all** | Issue checklist `- [ ] Delete`. UI is unaffected (all UI delete flows go through `bulkDeleteRules`, see below); only direct API consumers of `DELETE /api/detection_engine/rules` lose history |
| `bulkDeleteRules` | ✅ accepts `changeTracking<never>` | Logs `rule_delete` with `bulkCount` | OK |
| `upgradePrebuiltRule` | ✅ accepts `changeTracking<never>` | Hard-codes `ruleUpgrade` | OK |
| `revertPrebuiltRule` | ✅ accepts `changeTracking<never>` | Hard-codes `ruleRevert` | OK |
| `importRule` / `importRules` | ✅ accepts `changeTracking<never>` | Hard-codes `ruleImport` | OK except the overwrite-branch `bulkCount` drop (Risk #2) |
| `getRuleCustomizationStatus` | n/a | Read-only | No instrumentation needed |
| `getHistoryForRule` | n/a | Read-only | No instrumentation needed (it consumes history) |

### Write paths that bypass the DRC entirely and remain unannotated

These show up in the issue's checklist but the PR does not cover them, because they don't go through `IDetectionRulesClient`. Worth listing so they're not forgotten in follow-up PRs:

| Surface | Where | Today's behaviour |
|---|---|---|
| `POST /api/detection_engine/rules/_bulk_action` — `duplicate` | `bulk_actions/route.ts:297` → `rulesClient.create` + `rulesClient.update` | Logs as `rule_create` + `rule_update`, no `bulkCount`, no `ruleDuplicate` action |
| `…_bulk_action` — `enable` / `disable` | `bulk_actions/route.ts` → `bulkEnableDisableRules` → `rulesClient.bulkEnable` / `rulesClient.bulkDisable` | Alerting's bulk_enable/disable already self-log via `logRuleChanges` (see `bulk_enable_rules.ts:375`, `bulk_disable_rules.ts:258`) with their own internal `totalNumOfRules`. They do *not* use the new `changeTracking` API; OK for now but inconsistent |
| `…_bulk_action` — `edit` | `rule_management/logic/bulk_actions/bulk_edit_rules.ts:129` → `rulesClient.bulkEdit` (no `changeTracking` passed) | Logs as `rule_update`, alerting's `total`-derived `bulkCount` will be set automatically by the new `{ bulkCount: total, ...options.changeTracking }` default in `bulk_edit_rules.ts:114`, but no Security domain action |
| `…_bulk_action` — `edit` (params-only RBAC path) | same file: `rulesClient.bulkEditRuleParamsWithReadAuth` | Same — logs `rule_update`, no domain action |
| `…_bulk_action` — `manual_rule_run`, `fill_gaps`, `gap_auto_fill_scheduler` | Various wrappers under `bulk_actions/` | These are execution-control, not rule mutations — likely intentional to skip |
| Bulk `disable` after duplicate-creation, bulk `enable` after install/upgrade | Various | Same self-logging as bulk_enable/disable |
| `POST /api/detection_engine/rules/_export` and `…/_bulk_action:export` | `bulk_actions/route.ts:367` → `getExportByObjectIds` | Read-only — no instrumentation needed (issue's `- [ ] Export` may be tracking metadata about who exported, which is a separate audit concern from change history) |

### Bulk edit — does it need other-than-`rule_update` cases?

`IDetectionRulesClient` has no `bulkEdit` method. Bulk edit lives in `rule_management/logic/bulk_actions/bulk_edit_rules.ts` and goes straight to alerting via two sinks:

- `rulesClient.bulkEdit` (line 129) — for normal attribute edits.
- `rulesClient.bulkEditRuleParamsWithReadAuth` (line 116) — actions-only-read-auth shortcut.

Neither is passed `changeTracking` from Security. Alerting auto-supplies `bulkCount: total` (`bulk_edit_rules.ts:70`) and defaults `action` to `ruleUpdate`.

Mapping of every `BulkActionEditPayload` operation to a Security domain action:

| Bulk-edit operation | Maps to a non-`rule_update` action? |
|---|---|
| `tags` (add/set/delete) | No |
| `index` patterns | No |
| `investigation_fields` | No |
| `timeline_template` | No |
| `schedule` | No |
| rule `actions` | No |
| `alert_suppression` | No |
| `snooze_schedule` / `api_key` | No |

Foreseeable cases where a non-default action *would* matter (not in PR scope, not in the enum today):

| Scenario | Suggested action | Why |
|---|---|---|
| Bulk-editing a prebuilt rule that flips `rule_source.is_customized` to `true` | `ruleCustomize` (new) | History analytics — distinguish customization from plain edits |
| Bulk edit inside a larger workflow (post-import normalization, post-install defaults) | Workflow's own action (`ruleImport`, `ruleInstall`, …) | Group child writes under the workflow that drove them |

**Recommendation:** add `bulkEdit` to `IDetectionRulesClient` (mirror `bulkDeleteRules`) and route the two existing sinks through it so future actions can be injected centrally. No action work required today.

### Concrete follow-up checklist

Ordered by priority. Issue #262502 covers the scope-level items; the bug fixes are this-PR concerns.

**In-PR (should land before merge):**

- [ ] **Fix `legacy_create_prepackaged_rules.ts:94`** — `upgradeChangeTracking.bulkCount` should be `rulesToUpdate.length`, not `rulesToInstall.length`. Copy-paste from the install block above.
- [ ] **Fix `methods/import_rule.ts:74`** — overwrite branch drops `bulkCount`. Match the create branch four lines below: `changeTracking: { ...changeTracking, action: SecurityRuleChangeTrackingAction.ruleImport }`.
- [ ] **Hard-code action inside `createPrebuiltRule`** — match `importRule` / `upgradePrebuiltRule` / `revertPrebuiltRule`. Inject `action: SecurityRuleChangeTrackingAction.ruleInstall` inside `methods/create_rule.ts` (prebuilt branch) and narrow `CreatePrebuiltRuleArgs.changeTracking` to `<never>` so future callers can't forget.
- [ ] **Delete stale comments** in `create_rule.test.ts:4995`, `snooze_rule.test.ts:246`, `unsnooze_rule.test.ts:226`, `update_rule_api_key.test.ts:626`. They claim a "fall back to ruleSOs.length" behaviour that the implementation never had and that this PR explicitly removed from the docstring.
- [ ] **Remove `ruleDuplicate` from the enum**, *or* wire the bulk-duplicate path through the DRC in this PR. Today it's only exercised by `change_tracking.test.ts:78-88` against a code path no production caller uses.

**Follow-up PR (#262502 next items):**

- [ ] Singular `deleteRule` — needs both DRC plumbing **and** alerting-side `logRuleChanges` invocation in `application/rule/methods/delete/delete_rule.ts`. Today a single rule delete records nothing. Low user-visibility: all UI delete flows (rule details page `rule_actions_overflow/index.tsx:237`, rules table row + bulk actions, deprecation modal) go through `_bulk_action`→`bulkDeleteRules` and *are* instrumented. The gap only affects direct API consumers of `DELETE /api/detection_engine/rules`.
- [ ] Bulk `duplicate` — route through `createCustomRule({ changeTracking: { action: ruleDuplicate, bulkCount } })` and the followup exception-list `update` through `updateRule({ changeTracking: { action: ruleDuplicate } })`.
- [ ] Add `bulkEdit` to `IDetectionRulesClient` (mirror `bulkDeleteRules`) and route the two existing sinks in `logic/bulk_actions/bulk_edit_rules.ts` through it. Action stays `ruleUpdate` for now.
- [ ] SIEM migrations `installCustomRules` — pass `changeTracking: { action: ruleInstall, bulkCount }` (or introduce a dedicated migration action if the analytics target wants to distinguish them).
- [ ] Decide on bulk `enable` / `disable` — keep their pre-existing self-logged `totalNumOfRules` defaults or migrate them to the new `changeTracking` API for consistency.

## Open questions

Genuine questions for the PR author, after the in-PR fixes above are addressed:

- **Q1:** When `upgradePrebuiltRule` hits the type-change branch (`ruleAsset.type !== existingRule.type`), the prior `rulesClient.delete({ id })` is unannotated, so the history for that rule_id will gain a default `rule_delete` record immediately followed by a `rule_upgrade`. Is that the intended UX, or should the delete be suppressed/labelled as part of the upgrade? Pre-existing structurally, but newly visible after this PR.
- **Q2:** The route handler `importRulesRoute` sets `bulkCount: validatedResponseActionsRules.length` *after* multiple filtering passes (parse → action validation → response-action validation). So `bulkCount` reflects the number of rules that actually reached the import pipeline, not the number the user attempted to import. Is that the desired definition? It might surprise a user who imported 10 rules, had 2 rejected for missing actions, and sees `bulkCount: 8` in history.
- **Q3:** `BulkEditRuleParamsOptions` gained `changeTracking?: RuleChangeTracking` (i.e., callers *can* override `action`), even though the only known Security invocation (`update_rule_with_read_privileges.ts`) doesn't set `action`. Is that on purpose, or should it be `Omit<…, 'action'>` like `BulkDeleteRulesParams`, to mirror "implicit action for bulk-param edits"?
- **Q4:** Was a search done across out-of-tree plugins (e.g. `oblt-*`, `kibana-extra/*`) for callers of `RulesClient.bulkEdit` that passed `changeTrackingAction` or `totalNumOfRules`? Those will fail to compile after this PR.
- **Q5:** Does the analytics target for the change-history epic want a `ruleCustomize` action to distinguish bulk-edits that flip `rule_source.is_customized` to `true` from plain edits? Not in scope for this PR, but the answer determines whether the future `IDetectionRulesClient.bulkEdit` should narrow `changeTracking` to `<never>` or leave the action open.
- **Q6:** Does the SIEM-migration "install custom rule" workflow want to share `ruleInstall` with prebuilt-rule install, or have its own action (e.g., `ruleMigrationInstall`) for analytics separation?

## Notes for your codebase map

- `RuleChangeTracking` lives in `@kbn/alerting-types/rule_types.ts` as a *generic* type — `RuleChangeTracking<ChangeAction extends string = string>` — so consumers can narrow the `action` to their own enum (e.g. `SecurityRuleChangeTracking<SecurityRuleChangeTrackingAction>`). `SecurityRuleChangeTracking<never>` is the idiom for "no action allowed, only bulkCount".
- The convention for bulk operations is: **the route handler computes `bulkCount` once from its own pre-chunk input**, then passes it down through `DetectionRulesClient` → `RulesClient`; chunking layers (`createPrebuiltRules`, `bulkDeleteRules`) provide a chunk-local default that the caller-supplied value overrides via `{ bulkCount: <chunkLen>, ...changeTracking }`.
- `logRuleChanges` (in `alerting/server/application/rule/methods/common_utils/log_rule_changes.ts`) is the single point where rule changes are forwarded to `changeTrackingService.logBulk`. It now treats "all-undefined metadata" as no metadata via a small `isEmptyObject` helper. Useful to know if you ever need to add a new metadata field.
- The "default action" pattern lives in *both* sides of the wiring: alerting's `create_rule` / `update_rule` / `bulk_edit_rules` default to `ruleCreate` / `ruleUpdate`; the Security DRC `importRule` / `upgradePrebuiltRule` / `revertPrebuiltRule` override that default unconditionally with their domain action and merge caller-provided extras with spread (`{ action: …default…, ...changeTracking }`). Spread order matters — *defaults first, caller second* in alerting (caller wins), *caller first, override last* in Security overrides (Security action wins).
- `BulkDeleteRulesParams` extends `BulkDeleteRulesRequestBody` to attach an optional `changeTracking?: Omit<RuleChangeTracking, 'action'>`. The `Omit<…, 'action'>` trick is the codebase's idiom for "caller can't pick a domain-specific action because the operation's semantic is fixed". The same pattern is used downstream as `SecurityRuleChangeTracking<never>`.
- The FTR change-tracking suite is gated by `describe.skip` (`@kbn/change-history` feature flag); the integration tests are not exercised in CI today and won't catch regressions until the flag flips.
