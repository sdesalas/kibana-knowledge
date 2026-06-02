# PR #269617 — [Security Solution] Add MVP UI for rule changes history

- Author: @maximpn
- Base: `main` ← Head: `changes-history/mvp-ui`
- Stats: +1832 / −15 across 33 files
- Resolves: #262697

**Scale: Substantive PR.**

## Ownership (team: `@elastic/security-detection-rule-management`)

CODEOWNERS resolution (last-match wins):

- **Your team's files (29):**
  - All files under `public/detection_engine/rule_details_ui/components/change_history_flyout/**`
  - All files under `public/detection_engine/rule_details_ui/components/change_history_table/**`
  - `public/detection_engine/rule_details_ui/pages/rule_details/{index.tsx,translations.ts,use_rule_details_tabs.tsx}`
  - `public/detection_engine/rule_details_ui/utils/extract_changed_field_names.ts`
  - `public/detection_engine/rule_management/api/api.ts`
  - `public/detection_engine/rule_management/api/hooks/{translations.ts,use_change_history.ts}`
  - `public/detection_engine/rule_management/components/rule_details/json_diff/diff_view.tsx`
  - `public/detection_engine/rule_management/logic/types.ts`
  - `public/rules/routes.tsx`
  - `server/lib/detection_engine/rule_management/logic/history/compute_old_values{.ts,.test.ts}`
- **Other teams' files (4):** `public/detections/components/rules/rule_info/{index.tsx, rule_revision.tsx, rule_version.tsx, translations.ts}` — owned by `@elastic/security-threat-hunting`
- **Unowned:** none

Most of the PR is squarely in your team's area. The four `rule_info/` files are owned by Threat Hunting; they're additive (`RuleVersion`, `RuleRevision`, and translations), but worth a heads-up because the existing `CreatedBy`/`UpdatedBy` family lives there.

## Summary

Adds the MVP UI for the *Rule Changes History* feature behind the existing `ruleChangesHistoryEnabled` experimental flag. When the flag is on, a new **History** tab appears on the rule details page and renders a paginated `EuiTimeline` of recorded change events fetched from `GET /internal/detection_engine/rules/{ruleId}/history` (server route landed in earlier PRs). Each row renders an action‑specific message (created / enabled / snoozed / revision / Elastic upgrade / install / duplicate / import / revert / generic), with a "View" button that opens a flyout containing an **Overview at save** tab (rule snapshot via `RuleAboutSection` + `RuleDefinitionSection`) and a **Change details** tab (per‑field unified diff via the existing `DiffView`). The PR also adds two small subtitle widgets (`RuleVersion`, `RuleRevision`) shown in the rule details page header when the flag is on.

Two side‑changes that aren't strictly UI:

- `server/.../compute_old_values.ts`: arrays are now compared with `lodash.isEqual` instead of `Object.is` per‑index, so deep‑equal arrays of objects no longer produce false‑positive diffs in `old_values`. This is a real semantic fix to data the backend writes.
- `public/.../json_diff/diff_view.tsx`: guards against a `react-diff-view` crash when `hunks` is empty but `oldSource` isn't — relevant here because the flyout calls `DiffView` with arbitrary stringified values.

Intent vs diff: the description matches the diff. The only thing not called out in the description is the `compute_old_values` array‑equality fix, which arguably deserves its own PR but is small and well‑tested.

## Files touched

- **Server / shared logic** (`compute_old_values{,.test}.ts`): the `old_values` patch builder, used when each new history record is written.
- **API contract / client** (`rule_management/api/api.ts`, `api/hooks/use_change_history.ts`, `logic/types.ts`, `api/hooks/translations.ts`): adds `fetchRuleChangeHistoryById` + `useChangeHistory` react-query hook around the existing `RULE_HISTORY_URL`.
- **History tab plumbing** (`pages/rule_details/index.tsx`, `use_rule_details_tabs.tsx`, `pages/rule_details/translations.ts`, `public/rules/routes.tsx`): registers `RuleDetailTabs.history`, wires the route, hides the tab when the flag is off, mounts `ChangeHistoryTable` inside the rule details page.
- **Timeline UI** (`components/change_history_table/*`): `ChangeHistoryTable` (list + pagination + flyout state), `ChangeHistoryTimelineItem`, `RuleChangeHistoryAction` (action-type switch), `RuleActionItemWrapper` (consistent row chrome), `ChangedFieldsBadges` (inline badges + overflow), constants, translations.
- **Flyout UI** (`components/change_history_flyout/*`): `ChangeHistoryFlyout` (tabs + state), `ChangeHistoryFlyoutHeader`, `ChangeHistoryFlyoutActions`, `OverviewTab`, `ChangeDetailsTab`, `describeAction` utility, translations.
- **Subtitle widgets** (`detections/components/rules/rule_info/{rule_revision,rule_version}.tsx`): standalone `RuleRevision` / `RuleVersion` badges rendered in the rule details header when the flag is on.
- **Utility** (`rule_details_ui/utils/extract_changed_field_names.ts`): turns an `old_values` merge patch into a list of visible field names, filtering bookkeeping fields (`updated_at`, `revision`, `meta`, …).
- **Diff view fix** (`json_diff/diff_view.tsx`): one‑line workaround for `react-diff-view`'s `expandCollapsedBlockBy` crash on empty hunks.

## Flow trace

User clicks the "History" tab on a rule with the flag enabled:

1. `useRuleDetailsTabs` reports the tab as visible (flag is on, rule loaded, `hiddenTabs` doesn't include `history`). User clicks the tab; React Router navigates to `/rules/id/<ruleSO>/history`.
2. `public/rules/routes.tsx` matches the path (the `history` token was added to the `:tabName(...)` regex on both branches of the `endpointExceptionsTabEnabled` ternary).
3. `RuleDetailsPage` mounts a `<Route path={…/:tabName(history)}>` that's only rendered when `isRuleChangesHistoryEnabled` is true; the route renders `<ChangeHistoryTable ruleId={ruleId} />`.
4. `ChangeHistoryTable` calls `useChangeHistory({ ruleId, page: activePage + 1, perPage })` (1‑based page for the API).
5. `useChangeHistory` wraps `useQuery` (key: `['GET', RULE_HISTORY_URL, queryArgs]`, `staleTime: 0`) and calls `fetchRuleChangeHistoryById`, which hits `GET ${INTERNAL_DETECTION_ENGINE_URL}/rules/{ruleId}/history?page&per_page=…` with `version: '1'`. Server route is in `server/lib/detection_engine/rule_management/api/rules/rule_history/route.ts` and gated by `RULES_API_READ`.
6. Response (`RuleChangesHistoryResponse`) is mapped to `EuiTimelineItem`s by `ChangeHistoryTimelineItem` → `RuleChangeHistoryAction`. Each item picks a message based on `item.action`, which is either an alerting‑framework `RuleChangeTrackingAction` (e.g. `ruleEnable`) or a Security‑specific `SecurityRuleChangeTrackingAction` (e.g. `ruleUpgrade`, `ruleInstall`).
7. For actions that pass `onOpenDetails`, `RuleActionItemWrapper` renders a "View" button. Clicking it sets `selectedItem` and mounts `<ChangeHistoryFlyout key={item.id} …>`.
8. The flyout computes `changedFields = extractChangedFieldNames(item)` (top‑level keys of `old_values` minus the ignored bookkeeping set). If there are any, the Changes tab is shown first; otherwise only the Overview tab is shown.
9. **Change details tab**: for each `fieldName`, renders a `SplitAccordion` containing a `DiffView` with `oldSource = JSON.stringify(old_values[field])` and `newSource = JSON.stringify(rule[field])`. `formatValueForDiff` JSON‑stringifies objects/arrays, returns `''` for `null`/`undefined`, and stringifies primitives. The previously crashing `useExpand` path in `DiffView` is now safe because of the `oldSource` guard.
10. **Overview tab**: renders the existing `RuleAboutSection` and `RuleDefinitionSection` against `item.rule`, the full snapshot at save time.

## Assumptions

- **Backend route + bg writer are deployed and behaviorally stable.** The flag's docstring (`ruleChangesHistoryEnabled: false`, line 266 of `experimental_features.ts`) says "Both must be enabled for the API to return non-empty results" — implying a second flag/setting controls whether records are actually written. The UI assumes the API endpoint exists and returns the schema in `rule_history_route.gen.ts`. There's no UI handling for "endpoint exists but writer is off" beyond the empty state.
- **`item.rule` is a complete, current‑shape `RuleResponse`.** `OverviewTab` feeds it directly into `RuleAboutSection`/`RuleDefinitionSection`, which expect the full schema. For older recorded events (rules from before some schema migration), missing fields could surface as blank rows but probably won't crash.
- **`item.old_values` is the top‑level RFC 7396 merge patch.** `extractChangedFieldNames` takes `Object.keys` of it. The "ignored fields" list is hardcoded for top‑level only — nested patches (e.g. `note: { blob: 'old' }`) are treated as a single changed field, which matches the diff‑view's display granularity.
- **`describeAction` always receives a non‑empty string.** `translations.tsx` does `action[0].toUpperCase()` inside `UPDATED_BY` — if `item.action` is ever `''`, this throws.
- **`rule.rule_source.type` is populated for every rule.** The subtitle conditional `rule.rule_source.type === 'external'` assumes the field is present. The schema marks it as required, but flag‑gated UI on historical SOs can be fragile.
- **No two history items share the same `id`.** `ChangedFieldsBadges` and the flyout use `id` as React keys.

## Risks

Ordered by likely severity:

1. **`compute_old_values.ts` semantic change affects already-written history records.** Switching the array equality check from per-index `Object.is` to `lodash.isEqual` is correct, but every history record written before this fix that contains a structurally-equal-but-referentially-different array field still has that field in `old_values` — the new UI will display those as legit field changes (e.g. "threat" badges on revisions that didn't actually touch threat). Worth confirming with the writer team whether existing history docs are throwaway dev data, will be backfilled/cleaned, or just accepted as known noise pre-MVP.
2. **Flag-off deep link to `/rules/id/X/history`.** `public/rules/routes.tsx` now includes `history` in the parent route regex *unconditionally*, but the inner `<Route>` in `RuleDetailsPage` is wrapped in `{isRuleChangesHistoryEnabled && …}`. With the flag off, the URL matches the outer route (no 404), no inner route handles `history`, and the user lands on a blank tab area. Minor, but easy to hit when sharing URLs across environments with different flag values.
3. **`describeAction` formatting in `UPDATED_BY`.** `action[0].toUpperCase()` will throw on an empty string. `describeAction` itself looks safe (defaults to `action.replaceAll('_',' ')`), but an upstream typo or future API change that returns `""` would crash the flyout header. Cheap guard.
4. **`OverviewTab` runs a current‑shape renderer against a past snapshot.** Field renames or shape migrations between when the event was recorded and when it's displayed can produce confusing output. Not a regression — same risk exists in the prebuilt-rule upgrade flyout — but the MVP makes it visible across *all* historical rule states, not just one.
5. **No tests for any of the new UI.** This is an MVP, but `extractChangedFieldNames`, `describeAction`, `ChangedFieldsBadges` (inline/overflow math), and the action `switch` in `RuleChangeHistoryAction` are all pure-ish and would be easy to unit-test. The PR description's "How to test" is manual only.
6. **`use_change_history.ts` uses `staleTime: 0`.** The change history view will refetch on every tab focus / mount. For a rule with a large `RuleResponse` and 50 items per page, payloads can be sizable. Probably fine for MVP, but worth checking with the writer team whether throttling or longer `staleTime` (say 30s) is acceptable.
7. **Default-case fallthrough in `RuleChangeHistoryAction`.** Most "no-payload" actions (`ruleEnable`/`Disable`/`Snooze`/`Unsnooze`/`ApiKeyUpdate`) deliberately don't pass `onOpenDetails`, but the `default:` branch *does*. If the alerting framework adds a new no-payload action, it'll get a "View" button that opens an empty Changes tab. Inverting the default to *not* pass `onOpenDetails` (and treating any actionable cases as the explicit list) would be safer.

## Open questions

- The PR description says it Resolves #262697. Is this the whole MVP, or is there a follow-up to handle the existing-history-with-spurious-array-diffs problem mentioned in Risk #1?
- Why does the default case in `RuleChangeHistoryAction` enable the details flyout but the known no-payload actions disable it? Intentional ("inspect anything unknown") or unintended?
- Is the "blank History tab when flag is off" behavior intentional, or should the outer route gating in `routes.tsx` also be flag-aware? (Easy to forget which side is gating what when two flag gates coexist.)
- `ChangeHistoryFlyout` uses `item.old_values?.revision as number | undefined` even though `extract_changed_field_names.ts` adds `'revision'` to `IGNORED_DIFF_FIELDS`. The ignore set is only for *display*; `old_values.revision` is still consumed for the header. Worth confirming this asymmetry is by design (it appears to be).
- The added `expect(threat).not.toBe(patch)` assertion in `compute_old_values.test.ts` doesn't actually verify the regression — `threat` is an array, `patch` is `{}`, they're trivially not the same reference. The preceding `toEqual({})` is what actually proves the bug is fixed. Consider replacing or removing the second assertion to avoid future readers being confused about its purpose.
- `RuleVersion`/`RuleRevision` live under `public/detections/components/rules/rule_info/` which CODEOWNERS assigns to `@elastic/security-threat-hunting`. Is that intentional placement (next to `CreatedBy`/`UpdatedBy`), and has Threat Hunting been looped in for review? The components are otherwise generic and could equally live under `public/detection_engine/rule_management`.

## Notes for your codebase map

- **Change tracking is split across two namespaces.** `@kbn/alerting-types` exports the generic `RuleChangeTrackingAction` enum (the alerting framework's built-in actions: create/update/enable/disable/snooze/...), and `common/detection_engine/rule_management/rule_change_tracking.ts` extends it with `SecurityRuleChangeTrackingAction` for security-domain actions (`ruleInstall`, `ruleUpgrade`, `ruleDuplicate`, `ruleImport`, `ruleRevert`). UI switch statements need to handle both unions.
- **`old_values` is an RFC 7396 merge patch, not a list of changed fields.** The server stores the *previous values* of changed fields (top-level keys = changed fields; nested objects recurse; arrays are emitted whole). `extract_changed_field_names.ts` is the canonical way to derive the field list from a record — IGNORED set includes `updated_at`, `updated_by`, `created_at`, `created_by`, `revision`, `execution_summary`, `meta`.
- **The history API is keyed by Saved Object id, not `rule_id`.** `RULE_HISTORY_URL = /internal/detection_engine/rules/{ruleId}/history` where `ruleId` is the SO `id`. The route uses `buildRouteValidationWithZod` with `RuleObjectId`, version `'1'`, and is gated by `RULES_API_READ`.
- **Rule details tabs are gated in two places.** The outer route in `public/rules/routes.tsx` enumerates allowed `:tabName` values; the inner `<Route>` in `pages/rule_details/index.tsx` mounts a component; and `use_rule_details_tabs.tsx` controls *visibility* of tab buttons. All three need to agree when adding or flag-gating a tab.
- **`react-diff-view` has a known crash when `hunks` is empty but `oldSource` is non-empty.** The workaround in `diff_view.tsx` (pass `''` for `oldSource` when `hunks.length === 0`) is now load-bearing for any caller that may render the diff against arbitrary text — including the new Change details tab.
- **`EuiTimeline` is the Kibana-blessed primitive for activity-style histories.** This is the first detection-rule UI to use it. `EuiTimelineItem` provides a left-rail avatar slot; this PR's `ChangeHistoryTimelineItem` wires it to the user (or `logoElastic` for system events).
- **Translations as JSX-returning functions.** Several translation modules in this PR (e.g. `change_history_table/translations.tsx`) export `UPPER_CASE` *functions* that wrap `FormattedMessage` with interpolated React nodes (badges, dates). Used at call sites as `<i18n.X .../>`. Departs from the more common `i18n.translate(...)` + string pattern; worth knowing when grepping for i18n IDs.
