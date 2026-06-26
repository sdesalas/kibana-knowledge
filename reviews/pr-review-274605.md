# PR Review: #274605 — [Security Solution] Implement rule restore from changes history

**PR:** [elastic/kibana#274605](https://github.com/elastic/kibana/pull/274605) by @maximpn

**Scale:** Substantive — backend + frontend + alerting plugin contract change + integration tests.

**Ownership (team: `@elastic/security-detection-engineering`, the actual codeowner for Rule Management files in this repo; the `@elastic/security-detection-rule-management` handle requested isn't present in CODEOWNERS):**

- **Your team's files (most of the diff):**
  - `x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/rule_management/**`
  - `x-pack/solutions/security/plugins/security_solution/common/detection_engine/rule_management/rule_change_tracking.ts`
  - `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/**`
  - `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_management/api/**`
  - `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/**`
  - `x-pack/solutions/security/test/security_sdolution_api_integration/...` — focus here.
  - `x-pack/solutions/security/packages/test-api-clients/...` and `src/platform/packages/shared/kbn-openapi-common/...` (also detection-engineering-owned).
- **Other teams' files:**
  - `src/platform/packages/shared/kbn-alerting-types/rule_types.ts` (`@elastic/response-ops`) — adds `refresh` to `RuleChangeTracking` + `restoredFromChangeId` to metadata.
  - `x-pack/platform/plugins/shared/alerting/server/**` (`@elastic/response-ops`) — propagates `refresh` through `logRuleChanges`, `create_rule`, `update_rule`; `get_rule_history.ts` learns to authorize deleted rules from the latest history snapshot, and `getRuleHistoryParams` gains a `filters` clause.
- **Unowned:** none.

This is squarely in the rule-management team's scope, but the cross-plugin changes need a response-ops review too — they're contract-level changes on a shared alerting type.

---

### Context / Motivation

This PR delivers the **MVP** of the "restore a rule from its change history" feature tracked by epic [`security-team#12432`](https://github.com/elastic/security-team/issues/12432) (internal), split across:

- [#272862](https://github.com/elastic/kibana/issues/272862) — the API endpoint.
- [#272863](https://github.com/elastic/kibana/issues/272863) — the UI surface.

The premise from the linked issues:

> Implement an internal API endpoint that … applies the snapshot as the current rule state, recording the rollback as a new history entry via `SecurityRuleChangeTrackingAction.ruleRevert` … Works for all rule types: custom, customized prebuilt, and pure prebuilt.

And on the UI side:

> Add a restore action to each entry … Confirmation modal showing the revision number and timestamp before applying … unit tests for the rollback action component and hook, and a **Scout E2E test** for the full rollback flow.

### Validating the issue — does this PR address it?

The concern is technically valid. The PR addresses the API surface and the basic UI hook-up, but **two issue-level requirements aren't met**: the confirmation modal and the Scout E2E test.

- **Where the problem manifests.** Before this PR there was no way to roll back a rule. History entries were observable but not actionable.
- **How the PR fixes it.** A new internal route `POST /internal/detection_engine/rules/{ruleId}/history/{changeId}/_restore` delegates to `DetectionRulesClient.restoreRuleFromHistory`, which fetches the target history item by `event.id`, then either `rulesClient.update`s the live rule with merged snapshot params, or `rulesClient.create`s with the original SO id when the rule was deleted. Both paths log a new `SecurityRuleChangeTrackingAction.ruleRestore` history item carrying `restoredFromChangeId`. The UI adds a 3-dot popover on each (non-current) diffable timeline entry that calls a React Query mutation.
- **Naming divergence.** The linked issue calls the change action `ruleRevert`, the code uses a new `ruleRestore`. That's intentional — `ruleRevert` already exists for the "revert customized prebuilt to base" flow, which is different. Worth confirming this naming with the issue author so the epic stays coherent.
- **Residual caveats.**
  - No confirmation modal — clicking "Restore this version" fires the mutation immediately. The issue explicitly asked for one.
  - No Scout E2E. The integration suite covers backend paths and RBAC; the UI itself relies on existing unit-level coverage of `RuleActionsOverflow` and the new hook isn't unit-tested.
  - No explicit concurrency guard despite the API issue saying "Accepts a rule ID and a history item identifier with a concurrency guard". The route docs a `409` but I don't see where it's produced (see Risks).

### Summary

Adds an internal endpoint and UI affordance to restore a detection rule to any historical revision captured in the changes history. Server-side it overwrites the live rule's params with the snapshot's (via `applyRuleUpdate` + `convertRuleResponseToAlertingRule`) while preserving the live rule's `enabled` state; if the rule was deleted, it's re-created with the original SO id. Both paths record a new `rule_restore` history entry tagged with `restoredFromChangeId`, written with `refresh: 'wait_for'` so the UI's subsequent history refetch sees it. A real bug in `replaceParams` is fixed in passing. The alerting plugin learns to serve history for already-deleted rules by sourcing the authz info (`alertTypeId`, `consumer`, `name`) from the latest snapshot.

### Files touched

**API contracts (codegen + URL).**
- `common/api/detection_engine/rule_management/restore_rule_from_history/*` — OpenAPI yaml + generated Zod schemas + `RULE_RESTORE_FROM_HISTORY_URL`.
- `common/api/detection_engine/rule_management/index.ts`, `urls.ts`, `quickstart_client.gen.ts` — wiring.
- `packages/test-api-clients/supertest/detections.gen.ts` — supertest client method.

**Server route + business logic.**
- `server/.../rule_management/api/rules/restore_rule_from_history/route.ts` + `route.test.ts` — the new POST route.
- `server/.../api/register_routes.ts` — gated behind `ruleChangesHistoryEnabled`.
- `server/.../detection_rules_client/methods/restore_rule_from_history.ts` — the core orchestration.
- `server/.../detection_rules_client/detection_rules_client.ts`, `detection_rules_client_interface.ts`, `__mocks__/detection_rules_client.ts` — client wiring.
- `server/.../detection_rules_client.change_tracking.test.ts` and `.restore_rule_from_history.test.ts` — unit coverage.
- `server/.../methods/utils/map_rule_history_item.ts` — generalises metadata key snake-casing.
- `server/.../methods/get_rule_by_id.ts` — typo fix `GethRuleByIdOptions` → `GetRuleByIdOptions`.

**Alerting plugin (cross-team, response-ops territory).**
- `kbn-alerting-types/rule_types.ts` — adds `refresh` to `RuleChangeTracking`, `restoredFromChangeId` to `RuleChangeTrackingMetadata`.
- `alerting/server/.../common_utils/log_rule_changes.ts`, `create_rule.ts`, `update_rule.ts` — plumbs `refresh` through.
- `alerting/server/rules_client/methods/get_rule_history.ts` + `tests/get_history.test.ts` — fallback to snapshot for deleted-rule authz; adds `filters` to `GetRuleHistoryParams` (used to look up a single history item by `event.id`).

**Frontend.**
- `public/.../changes_history/changes_history.tsx`, `use_rule_restore_from_history.ts`, `translations.ts` — wire the mutation hook + toasts.
- `public/.../changes_history_timeline/{change_history_item,change_history_item_popover,change_history_timeline,rule_change_action_badge,constants,translations}.{ts,tsx}` — popover UI + a `rule_restore` action badge.
- `public/.../pages/rule_changes_history/rule_change_history_page{,_header}.tsx` — passes `ruleId` so the back-link works for deleted rules.
- `public/.../pages/rule_details/index.tsx`, `rule_actions_overflow/index.{tsx,test.tsx}` — exposes the "History" menu item even when `rule == null` (deleted), accepts a separate `ruleId` prop, and gates only the History item on `isRuleChangesHistoryEnabled` rather than the whole popover.
- `public/.../rule_management/api/api.ts`, `hooks/use_restore_rule_revision_mutation.ts` — REST call + React Query mutation with cache invalidations.

**Misc fix.**
- `src/platform/packages/shared/kbn-openapi-common/shared/path_params_replacer.ts` — real bug fix: was overwriting `output` with `path.replace(...)` each iteration so only the last param substitution survived. Replaced with `output = output.replace(...)`.

**Integration tests.**
- `restore_rule_from_changes_history.ts` — covers custom, customized prebuilt, pure prebuilt, deleted-rule, missing-changeId, no-op, and RBAC paths.
- `change_tracking.ts` — un-`.skip`s the suite, switches to snake_case metadata keys, replaces the 404-for-deleted assertion with a 200.
- `trial_license_complete_tier/index.ts` — loads the new suite.

### Flow trace — "user clicks Restore on a non-current history entry"

1. `change_history_timeline.tsx` only renders the restore popover (`ChangeHistoryItemPopover`) when `isRestorableItem(item) && index !== 0 && canEditRules`. Clicking it calls `onRestore(item)` → `useRuleRestoreFromHistory.restoreFromHistory(item)` → `restoreMutate({ ruleId, changeId: item.id })`.
2. `use_restore_rule_revision_mutation.ts` calls `fetchRestoreRuleRevision` which `POST`s to `RULE_RESTORE_FROM_HISTORY_URL`.
3. `route.ts` validates params with the generated Zod schema, requires `RULES_API_ALL` privilege, then resolves `detectionRulesClient.restoreRuleFromHistory({ ruleId, changeId })`.
4. `restore_rule_from_history.ts`:
   - `getRuleById` → returns `existingRule` (`null` if SO is gone).
   - `rulesClient.getHistory({ module: 'security', ruleId, size: 1, filters: [{ term: { 'event.id': changeId } }] })`. If empty → `ClientError(404)`.
   - Hydrates `snapshotRule = convertAlertingRuleToRuleResponse(item.rule)`.
   - **Deleted-rule branch (`existingRule == null`)**: `validateMlAuth` + `validateFieldWritePermissions` against the snapshot, then `rulesClient.create({ data: { ...convertRuleResponseToAlertingRule(snapshotRule, actionsClient), alertTypeId: ruleTypeMappings[snapshotRule.type], consumer: SERVER_APP_ID, enabled: snapshotRule.enabled ?? false }, options: { id: ruleId }, changeTracking: { action: ruleRestore, metadata: { restoredFromChangeId }, refresh: 'wait_for' } })`.
   - **Live-rule branch**: `validateMlAuth`; if `isEqual(convertRuleToDiffable(existingRule), convertRuleToDiffable(snapshotRule))` → return `{ rule: existingRule, no_change: true }`. Otherwise `applyRuleUpdate({ prebuiltRuleAssetClient, existingRule, ruleUpdate: snapshotRule })` (which keeps `existingRule.id/rule_id/revision/immutable/rule_source/timestamps`, then re-runs `calculateRuleSource`), force `enabled = existingRule.enabled`, `validateFieldWritePermissions` on the merged rule, then `rulesClient.update({ id, data, changeTracking })`.
5. The alerting framework writes the rule SO and (via `logRuleChanges`) the `rule_restore` history doc with `refresh: 'wait_for'` so the UI's subsequent history refetch sees it.
6. React Query `onSuccess` invalidates find/filters/coverage/upgrade-review/base-version/history caches and updates the by-id cache with `response.rule`.
7. `onSettled` toasts: if `response.no_change` → info; otherwise `CUSTOM_RULE_RESTORE_SUCCESS_TOAST(revision)` or `PREBUILT_RULE_RESTORE_SUCCESS_TOAST(version, revision)`; on error → error toast.

### Assumptions

- The change-history data stream is indexed and queryable by `event.id` as a term. The PR adds `filters: [{ term: { 'event.id': changeId } }]` and relies on the change-history client's `additionalFilters` being ANDed in correctly.
- `event.id` is unique. `size: 1` with no `from` is treated as "the target document" — the code comment explicitly calls this out, but it assumes the change-history index never has two documents with the same `event.id` (e.g. across spaces, modules, or accidental duplicates).
- `rulesClient.create({ options: { id: ruleId } })` succeeds for a freshly-deleted SO id. There's no check that the id is free; a concurrent re-create with the same id would 409.
- The snapshot stored in `RuleChangeHistoryDocument.rule` is shape-compatible with what `convertAlertingRuleToRuleResponse` expects — i.e. the persistence format hasn't drifted from the live `SanitizedRule<RuleParams>`. The `as SanitizedRule<RuleParams>` cast in `restore_rule_from_history.ts` papers over this.
- For deleted-rule restore the snapshot's `alertTypeId` is mapped via `ruleTypeMappings[snapshotRule.type]`, which assumes every snapshot's `type` exists in the current mapping. Old snapshots after a rule-type deprecation/rename would fail here.
- `applyRuleUpdate` is safe to call with a snapshot whose `version` is older than current — the resulting `version` reverts to the snapshot's value, and `calculateRuleSource` is expected to re-mark the rule as non-customized / customized correctly. The integration tests cover the common cases, but stale prebuilt assets aren't a tested matrix dimension.
- `refresh: 'wait_for'` on the change-history write is fast enough that the UI's invalidation race is tolerable. If the alerting framework's change-tracking write fails or is slow, the toast will fire before the new entry is visible.
- The PR description mentions a "concurrency guard" but no `ifMatch`/revision is sent from the UI nor checked server-side, so the assumption is effectively "last-writer wins on the rule SO, and any 409 surfaces from `rulesClient.update`'s underlying SO conflict logic".

### Risks

Ordered by severity.

1. **No confirmation modal.** Restore overwrites the live rule on a single click in a popover. For a destructive operation that throws away current customizations, this is below the bar set by sibling operations (revert, delete, manual-run all confirm). The linked issue specifically asked for one. Risk of accidental restore that destroys days of in-progress edits with no undo other than "restore to a *different* historical version".
2. **`replaceParams` bug fix is silently a behavior change for callers.** The previous implementation only correctly substituted the *last* param of `Object.entries(params)`. Any caller that worked around this (e.g. by calling `replaceParams` with one param at a time, or relying on JS engine insertion-order quirks) might now produce different URLs. Worth a quick `rg "replaceParams\("` audit to see if anyone was leaning on the broken semantics. This deserves a dedicated PR per the AGENTS.md "Make focused changes" guidance.
3. **`map_rule_history_item.normalizeMetadata` change is a wire-format change.** The pre-PR code only knew about `bulkCount → bulk_count`. The new code lowercases **all** keys via `mapKeys + snakeCase`. The integration tests updated `originalRuleSoId → original_rule_so_id`. Any external consumer that was reading the camelCase field will break. Probably contained because this is an internal route, but the response is also surfaced to the UI — search public types for `originalRuleSoId`.
4. **Deleted-rule branch hard-codes `consumer: SERVER_APP_ID`.** The snapshot has its own `consumer` (used by the alerting plugin for authz fallback in the modified `getRuleHistory`), but `restoreRuleFromHistory` ignores it on recreate. If a rule was originally created under a different consumer (e.g. by a different app re-using the rule type), restore will silently change ownership. Worth confirming Detection rules can only ever have `consumer = SERVER_APP_ID` (likely true, but assert it).
5. **`enabled` semantics differ between the two branches.** Live-rule branch forces `enabled = existingRule.enabled` (snapshot ignored); deleted-rule branch uses `enabled: snapshotRule.enabled ?? false`. The unit test confirms the live-branch behavior explicitly. The mismatch isn't obviously wrong, but it isn't documented anywhere and the UX implication ("restoring a deleted rule might re-enable it") deserves a sanity check.
6. **Cross-plugin contract changes to `@kbn/alerting-types` need response-ops review.** Adding `refresh` to `RuleChangeTracking` and `restoredFromChangeId` to `RuleChangeTrackingMetadata` is a public contract change. The metadata field is named after the security solution's `ruleRestore` action, which is a leak of the consumer's naming into the generic alerting type. Consider either generic naming (`previousChangeId`) or pushing the field into a `metadata` payload that's typed per-consumer.
7. **`getRuleHistory` "deleted rule" fallback uses `unsecuredSavedObjectsClient` and then trusts the snapshot for authz.** A user who can still resolve the SO id of a deleted rule (e.g. because they knew it) can now fetch its history if the snapshot's `consumer` + `alertTypeId` happen to grant them `GetHistory`. That's effectively the same trust model as the live path. Worth a brief eyes-on from response-ops since it loosens a pre-existing assumption that the rule must currently exist.
8. **No Scout/UI test for the restore flow** despite issue #272863 explicitly asking for one. The risk isn't immediate correctness; it's that future UI churn on the popover/timeline will silently break the flow.
9. **`isRestorableItem` only filters by `DIFFABLE_CHANGE_ACTIONS`.** It includes `ruleRestore` itself, so users can restore a previous restore. Probably fine — it's idempotent in effect — but it's worth a sanity check on the UX: after restoring to v3, the new top item is `rule_restore`, then `rule_update`s, then the original `rule_restore`'s target. The user might be confused which `rule_restore` "lands" them at v3.
10. **`index !== 0` to disable the top item is positional, not semantic.** It correctly suppresses no-op restores to the current state in the normal case, but it depends on the timeline being sorted desc and the topmost item always being "current". If the sort order ever changes (e.g. ascending), the wrong item becomes non-restorable. A semantic check (e.g. `item.id === currentChangeId`) would be more durable.

### Open questions

- Where does the documented `409 Conflict` response in `restore_rule_from_history_route.schema.yaml` actually come from? I couldn't trace a code path that surfaces a 409. If it's a transitive ES conflict from `rulesClient.update`, is the error mapped to 409 via `transformError`? Worth a quick check or removing the documented status if it can't happen.
- Was a confirmation modal intentionally deferred from the MVP, or accidentally dropped? Issue #272863 lists it as a requirement.
- Why is the new alerting metadata field named `restoredFromChangeId` (security-specific verb) rather than something neutral like `previousChangeId`? Should this live under the generic `RuleChangeTrackingMetadata` at all, or be put on a per-consumer extension?
- The `rule_restore` action enum value is added in `SecurityRuleChangeTrackingAction`, separate from `ruleRevert`. The linked issue used the verb "revert"; is the distinction (restore = roll-back to history snapshot, revert = drop customizations) well-established and documented in the user-facing copy?
- For deleted-rule restore, what guarantees the original `consumer` was `SERVER_APP_ID`? If it's enforced elsewhere, a code comment would help — otherwise it's a silent ownership rewrite.
- The unit test asserts `enabled` state is preserved on update, but for the **deleted** rule branch the snapshot's `enabled` value is used. Is "restoring a deleted rule resurrects it in the enabled state it had at the time" the intended UX?
- The integration test `'restores a non-customized prebuilt rule…'` asserts `body.rule.version).toBe(1)` after restoring from the v1 install entry. After this, the live rule advertises `version: 1` even though prebuilt asset v2 exists in the repo. Does the upgrade-review query treat it as "v1 → upgrade to v2 available"? (If yes, the cache invalidation for `useInvalidateFetchPrebuiltRulesUpgradeReviewQuery` is well-placed.)
- `useRestoreRuleFromHistoryMutation` invalidates six caches but doesn't invalidate the per-rule rule history list query that fed `useInfiniteChangeHistory` — actually it calls `useInvalidateChangeHistory`. Confirm that hook invalidates the *infinite* query key correctly so the new `rule_restore` entry appears (the `refresh: 'wait_for'` write is what makes the refetch see it).

### Notes for your codebase map

- `DetectionRulesClient` is the SecuritySolution wrapper that orchestrates `rulesClient` (alerting framework) + actionsClient + prebuilt-asset client + ML/RBAC authz. New methods follow the pattern: a thin file in `methods/<name>.ts`, an arg type in `detection_rules_client_interface.ts`, wiring in `detection_rules_client.ts` (with `withSecuritySpan`), and a mock in `__mocks__/detection_rules_client.ts`.
- `applyRuleUpdate` is the centralised "merger" used by both update and restore: it preserves `id`/`rule_id`/`revision`/`immutable`/`rule_source`/timestamps from the existing rule, then re-runs `calculateRuleSource` to recompute the `external + isCustomized` flag.
- Change-tracking metadata sent into the alerting framework is now passed through `mapKeys + snakeCase` on the way out — so any new field you add to `RuleChangeTrackingMetadata` will automatically be snake-cased in the API response.
- The `RuleActionsOverflow` popover button used to be entirely disabled when `rule == null` (deleted). With this PR it stays enabled while `isRuleChangesHistoryEnabled` so the user can still get to History/Restore. The pattern for "an action is rule-agnostic" is to spread it before the `rule != null` branch.
- `RuleChangeTracking.refresh` is the supported way for callers to force a `wait_for` write of the change-history doc. Use it whenever a UI refetch immediately follows the change.
- `getRuleHistory` on the alerting framework side now tolerates deleted rules by falling back to the latest snapshot for authz info. Don't assume the rule SO exists when reading history.

### Review activities

1. **Local validation on clean ES/Kibana.** Pulled the branch locally on a clean Elasticsearch + Kibana setup, applied the required configuration (`xpack.alerting.ruleChangeTracking.enabled`, `xpack.securitySolution.enableExperimental: ['ruleChangesHistoryEnabled']`), and walked through the main user flows: rule creation, rule editing, and restoring historical changes from the changes-history page. This is what surfaced the UX concern logged as activity #2 — the restore flow firing immediately on a single click with no confirmation step felt jarring during real usage, even before any code review.

2. **PR comment on the UX flow** (2026-06-25 10:53). Issue-comment ([`#issuecomment-4798467962`](https://github.com/elastic/kibana/pull/274605#issuecomment-4798467962)) raising the missing confirmation modal — directly aligned with Risk #1 in this review and explicitly required by linked issue [#272863](https://github.com/elastic/kibana/issues/272863) ("Confirmation modal showing the revision number and timestamp before applying"). Quoted the issue requirement and proposed a confirmation modal + slight delay before jumping to the latest version of the rule, with a screenshot of the current "instant restore" behavior and a mock of the proposed modal. Awaiting author response.

3. **License-tier coverage check.** Verified that the new restore route (`route.ts`) and `restoreRuleFromHistory` method don't include any `license.hasAtLeast(...)` or `getRuleCustomizationStatus()` calls — gating is entirely via the `ruleChangesHistoryEnabled` experimental flag and the `RULES_API_ALL` API privilege. This matches how `update_rule` / `patch_rule` are structured (no per-method license checks; customization is gated transitively in `calculateRuleSource`). Integration tests live only under `trial_license_complete_tier/restore_rule_from_changes_history.ts`; there is no equivalent in `basic_license_essentials_tier/`. The pre-existing `change_tracking.ts` suite (un-skipped by this PR) follows the same trial-only placement, so this is internally consistent. **Open concern:** restoring a prebuilt rule to a snapshot that differs from the live prebuilt asset transitively requires `MINIMUM_RULE_CUSTOMIZATION_LICENSE` (because it forces `isCustomized: true` via `calculateRuleSource`), but the PR ships no test or documentation for the basic-tier path. Worth asking the author whether prebuilt-rule restore on basic-tier is intended to (a) silently no-op customization, (b) fail explicitly with a license error, or (c) succeed and bypass the gate, and adding a test covering whichever it is.

4. **`getRuleHistory` 404 → 200 regression for never-existed ruleIds.** The PR's modification to `x-pack/platform/plugins/shared/alerting/server/rules_client/methods/get_rule_history.ts` collapses three previously-distinct states into two: (a) rule SO exists → 200 with history, (b) rule SO gone but change-history has snapshots → 200 with history (intended new behavior), (c) rule SO gone and change-history is empty (i.e. random UUID, or a rule that predates change-tracking) → **200 with `{ total: 0, items: [] }`** instead of the prior 404. The deleted-rule branch's `if (latestHistory.items.length === 0) { return { total: 0, items: [] }; }` early-return short-circuits both the 404 and the downstream `ensureAuthorized` call. The integration test `change_tracking.ts` was rewritten to drop the `uuidv4()`-based 404 assertion and replace it with the new "deleted rule with history → 200" case, so the regression is uncovered. Recommended fix: throw `SavedObjectsErrorHelpers.createGenericNotFoundError(RULE_SAVED_OBJECT_TYPE, ruleId)` in that branch instead of returning empty, and keep both test cases. The restore route is incidentally OK on bogus ruleIds (the `event.id` term filter returns no items and `restoreRuleFromHistory` throws a 404 `ClientError`), but the error message ("changeId: ... not found") misleadingly blames the changeId rather than the missing rule.

5. **Concurrency guard / 409 reachability — and a precedent in prebuilt-rule upgrade.** Traced the documented `409 Conflict` response in `restore_rule_from_history_route.schema.yaml`. It IS reachable, but only weakly: `rulesClient.update` (`x-pack/platform/plugins/shared/alerting/server/application/rule/methods/update/update_rule.ts:373`) reads `version` from the original rule SO and passes it into `createRuleSo({ id, version, overwrite: true, … })`, so a `version_conflict_engine_exception` from ES will surface as `statusCode: 409` and pass through `transformError` (`src/platform/packages/shared/kbn-securitysolution-es-utils/src/transform_error/index.ts:44–55`). However that only protects the few-ms window between the alerting framework's *own* internal SO read and write. It does **not** protect the much larger TOCTOU window in `restoreRuleFromHistory` between the security-solution layer's `getRuleById` (used to compute the merge via `applyRuleUpdate`) and `rulesClient.update`'s internal re-read; a concurrent edit landing in that window is silently overwritten because `rulesClient.update` re-fetches the latest version before writing. That's almost certainly the case the linked issue meant by "with a concurrency guard". The codebase already has a precedent for the explicit form of this guard in **prebuilt rule upgrade**: `RuleUpgradeSpecifier` requires the client to send `revision` (`x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/prebuilt_rules/perform_rule_upgrade/perform_rule_upgrade_route.ts:104–112`), and `perform_rule_upgrade_handler.ts:168–177` rejects with a `Revision mismatch` error when the supplied revision doesn't match the live rule (commented "no update slipped in since the user reviewed the list"). To bring restore to parity, the request schema would need a `revision` (and likely `version`) field, `restoreRuleFromHistory` would compare it against `existingRule.revision` and throw a `ClientError` with status 409 on mismatch, and the UI would send the revision it last saw and react to 409 with a refetch + "rule changed under you" toast. Without that, the documented 409 in the OpenAPI spec is misleading — it only catches a narrow native ES race, not the user-meaningful "rule moved while I was looking" case.

6. **PR comment on the concurrency guard** (2026-06-25 13:57). Raised activity #5 on the PR as a review comment ([`#discussion_r3474954588`](https://github.com/elastic/kibana/pull/274605#discussion_r3474954588), anchored on `restore_rule_from_history.ts:56`), framed around the cross-user scenario (User A on the history page while User B edits the rule from another browser → A's restore silently overwrites B's edit). Suggested mirroring the prebuilt-rule upgrade pattern: add `revision` to the request, compare against `existingRule.revision` in `restoreRuleFromHistory`, throw a 409 on mismatch, send the revision from `useRestoreRuleFromHistoryMutation`, react to 409 with a refetch + "rule was edited by someone else" toast. Linked to the precedent at `perform_rule_upgrade_handler.ts:168-177` (commit `dcb3675`) and `RuleUpgradeSpecifier` at `perform_rule_upgrade_route.ts:104-112` (commit `0b13de4`).

7. **Follow-up on concurrency thread — narrowed scope to time-separated requests** (2026-06-26 06:58). Replied to Maxim's pushback ([`#discussion_r3479684636`](https://github.com/elastic/kibana/pull/274605#discussion_r3479684636)) after he noted that simultaneous restore requests can't be technically fenced due to write-skew. Agreed with the limitation but narrowed the ask: two browsers loading the same `rule.revision` and acting at *different times* (e.g. User1 edits at R1→R2, then User2 restores 2 minutes later thinking they're going R0→R2 but actually creating R3) is the realistic, fixable case. Proposed a concrete 409 toast: *"The rule was updated while you were on this screen. Please refresh the history if you still want to restore to an earlier revision."* Acknowledged the trade-off vs the SO-version (base-64 `seq_no:primary_term`) approach: SO version is technically more correct (catches things like background enable), but `revision` is simpler and covers the majority case. Also called out that `RulesClient.update` already has internal OCC ([`update_rule.ts:373`](https://github.com/elastic/kibana/blob/2c0f95c251784cf4dfe46917350c0e451446032e/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/update/update_rule.ts#L373)) so a small slice of the lifecycle is already protected — the new check would extend coverage to the larger window between `DRC.restoreRuleFromHistory()` and `RulesClient.update()`.

8. **Bug surfaced via local validation — duplicate Elastic Defend rule after restore** (2026-06-26 09:31). Filed as issue-comment [`#issuecomment-4808293867`](https://github.com/elastic/kibana/pull/274605#issuecomment-4808293867). Scenario: created an Elastic Defend rule → deleted it → a new one was auto-created (presumably by Defend's rule provisioning) → restored the original from history. Result: two rules visible in the list with **different `rule.id` (SO id) but identical `rule.rule_id`**. This bypasses the normal `rule_id`-uniqueness assumption that downstream code (find queries, prebuilt-asset matching, upgrade review) relies on. Suggests the deleted-rule restore branch in `restoreRuleFromHistory` doesn't check for an existing rule with the same `rule_id` before recreating from the snapshot. Screenshot attached to the comment.

9. **Bug surfaced via local validation — revision goes backwards after restoring a deleted rule** (2026-06-26 09:39). Filed as issue-comment [`#issuecomment-4808351917`](https://github.com/elastic/kibana/pull/274605#issuecomment-4808351917). Scenario: created/updated/deleted a rule sitting at `R1` at time of deletion → navigated to its historical state via the Alerts page → restored. The recreated rule starts at `R0` instead of `R1+1`, so further edits walk back through revisions the rule has already been at (`R1 → R0 → R1`). Confusing for users who reason about revision as a monotonically increasing identifier. Proposed fix: pass the last-known revision to `RulesClient.createRule()` in the deleted-rule branch of `restoreRuleFromHistory` so the recreated rule starts at `lastRevision + 1`. Screenshot attached. Open question for the author on whether `createRule` accepts a starting revision today, or whether this needs an alerting-framework change.
