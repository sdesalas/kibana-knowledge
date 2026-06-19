# PR Review: #269617 — [Security Solution] Add MVP UI for rule changes history

**PR:** [elastic/kibana#269617](https://github.com/elastic/kibana/pull/269617)
**Linked issue:** [#262697](https://github.com/elastic/kibana/issues/262697) — Implement Rule Changes History UI

---

**Scale:** Substantive — 62 files, ~6k diff lines. Four layers: authorization/privilege wiring, server-side history retrieval, client API + hooks, and a full new page with several components. Mostly net-new behind an off-by-default flag, but touches shared things (`HeaderPage`, `DiffView`, `global_header`, alerting privilege builder).

**Ownership (team: `@elastic/security-detection-rule-management`):** All `rule_details_ui/**`, `rule_management/**`, and server `detection_rules_client/methods/**` files are owned by the team. Shared touchpoints owned by `@elastic/security-solution`: `header_page/index.tsx`, `helpers.tsx`, `rules/routes.tsx`, `global_header/index.tsx`, `common/constants.ts`, `breadcrumbs.ts`, `deeplinks/security/deep_links.ts`. Authorization core files owned by `@elastic/kibana-security`. Focus review on shared edits — regressions there hit ~34 other pages.

---

## Summary

Adds an MVP Detection Rule Changes History UI gated behind `ruleChangesHistoryEnabled`. When enabled:

- A **History** entry appears in the rule details overflow menu (⋮), navigating to a new `/rules/id/:ruleId/changes-history` route.
- The new page has a custom page header (`RuleChangesHistoryPageHeader`) showing rule name, metadata, and execution status, with the main area showing a JSON diff panel and a push flyout (400px, right side) showing an infinite-scroll timeline of all recorded rule changes.
- Selecting a timeline entry reconstructs the before-state from `old_values` (RFC 7396 merge patch) and renders a unified JSON diff.
- Rule details page subtitle now shows `Revision` and (for prebuilt rules) `Elastic version` badges.
- `getHistory` was added to the alerting authorization read operations, wiring every rule-consumer feature privilege to include `alerting:{ruleType}/{consumer}/rule/getHistory` automatically.
- `compute_old_values.ts` was rewritten to fix three correctness bugs — the main one being that `undefined`-as-absent wasn't handled correctly, causing newly added fields to appear invisible to the diff.

**Description ↔ diff:** the PR description says the layout is an `EuiResizableContainer` split-panel, but the implementation is a fixed `EuiFlyout type="push"` at 400px. Not resizable. Either the description is stale or the implementation diverged.

---

## Files touched

- **Authorization / privilege** — `authorization_core/.../alerting.ts` (+ tests): adds `getHistory` to `readOperations.rule`. Hundreds of lines of snapshot updates in observability and security serverless auth tests — correct pattern for a read-only rule operation, no manual privilege declarations needed.
- **Public route plumbing** — `common/constants.ts`, `deeplinks/security/deep_links.ts`, `rules/routes.tsx`, `helpers.tsx`, `use_show_timeline_for_path.ts`, `breadcrumbs.ts`, `global_header/index.tsx`. Adds the new path constant, deep-link enum entry, FF-gated route, and tells the timeline/breadcrumb/global-header machinery to treat this URL specially.
- **Public API + hooks** — `rule_management/api/api.ts` (`fetchRuleChangeHistoryById`), `use_infinite_change_history.ts` (infinite query + invalidation hook), `use_bulk_action_mutation.ts`, `use_update_rule_mutation.ts`, `use_perform_rules_upgrade_mutation.ts`, `use_revert_prebuilt_rule_mutation.ts` (all gain `useInvalidateChangeHistory()` in `onSettled`), `rule_management/logic/types.ts` (new `FetchRuleHistoryProps`).
- **Public UI — page** — `rule_changes_history/rule_change_history_page.tsx` + `rule_change_history_page_header.tsx`. The page header is a new standalone component with rule name/metadata/back link; the page wires header + history body together.
- **Public UI — components** — `changes_history/{changes_history.tsx,changes_history.test.tsx,use_change_history_auto_selection.ts,index.ts,translations.ts,images/no_change_history.png}`, `changes_history_timeline/{change_history_timeline.tsx,change_history_item.tsx,change_history_footer.tsx,rule_change_action_badge.tsx,constants.ts,translations.ts,index.ts}`, `changes_diff/{changes_diff.tsx,utils.ts,translations.ts}`, `rule_details_ui/utils/extract_changed_field_names.ts`.
- **Rule details page** — `rule_details_ui/pages/rule_details/index.tsx` (subtitle: revision + version badges under FF), `rule_details_ui/pages/rule_details/rule_actions_overflow/index.tsx` (History menu entry under FF).
- **Shared UI tweaks** — `common/components/header_page/index.tsx` adds `backInlined` and icon-only back link variant (snapshot updated). `rule_management/.../json_diff/diff_view.tsx` exposes `renderGutter` prop and fixes empty-hunks crash. `detections/components/rules/rule_info/{rule_revision.tsx,rule_version.tsx}` are new badge components.
- **Server** — `detection_rules_client/methods/get_history_for_rule.ts` runs two concurrent `rulesClient.getHistory` queries (descending for page data, ascending single-item for `tracking_started_at`). `methods/utils/compute_old_values.ts` (rewritten — see below). `methods/utils/map_rule_history_item.ts` adds `normalizeMetadata` renaming `bulkCount` → `bulk_count`. `common/api/.../rule_history_route.schema.yaml` + `.gen.ts` add the `tracking_started_at` optional response field and rename `perPage` → `per_page`.

---

## Flow trace

1. User on rule details page, flag enabled → ⋮ overflow → "History" (`rule_actions_overflow/index.tsx`) → `navigateToApp(APP_UI_ID, { deepLinkId: SecurityPageName.rules, path: getRuleChangesHistoryUrl(rule.id) })`.
2. URL becomes `/rules/id/{ruleId}/changes-history`. `RulesContainer` matches the FF-gated route, mounts `RuleChangesHistoryPage`.
3. Side effects: `GlobalHeader` calls `setHeaderActionMenu(undefined)` (clears chrome action toolbar); `useShowTimelineForPath` hides the timeline (`EXTRA_HIDDEN_TIMELINE_PATHS`); breadcrumb system appends "History" crumb via `getTrailingBreadcrumbs` (triggered by `pathname.includes('/changes-history')`).
4. `RuleChangesHistoryPage` calls `useRuleWithFallback(ruleId)` for rule snapshot, renders `RuleChangesHistoryPageHeader` (back arrow inline with title, metadata subtitle) and `<RuleChangesHistory ruleId={ruleId} rule={...} />`.
5. `RuleChangesHistory` calls `useInfiniteChangeHistory({ ruleId })` → `fetchRuleChangeHistoryById` → `GET /api/.../rules/{ruleId}/history?page=1&per_page=20`.
6. Server `getHistoryForRule` runs two concurrent `rulesClient.getHistory` calls: one descending (page items + 1 predecessor for `old_values` computation), one ascending `size=1` for `tracking_started_at` (runs on every page, not just page 1 despite comment).
7. `mapRuleHistoryItem` shapes each raw event into `{ id, timestamp, action, user, rule, old_values }`. `computeOldValues` produces the RFC 7396 patch for each item except the oldest (which has no predecessor).
8. Client renders an `EuiFlyout type="push" ownFocus={false} hideCloseButton pushMinBreakpoint="xs"` (400px) as the timeline sidebar. `useChangeHistoryAutoSelection` auto-selects the first item whose `action` is in `DIFFABLE_CHANGE_ACTIONS`.
9. `IntersectionObserver` sentinel at timeline bottom triggers `fetchNextPage` when scrolled into view.
10. On selection, `RuleChangesDiff` calls `filterAndSort(rule)` (strips `IGNORED_DIFF_FIELDS`, sorts keys), then `reconstructBefore(after, old_values)` (applies RFC 7396 patch), then renders `<DiffView viewType="unified" renderGutter={...} />`.
11. Close (× in flyout-style header or back arrow) → back to `/rules/id/{ruleId}` Overview tab.

---

## `compute_old_values` rewrite — key details

Three bugs fixed:

1. **`undefined`-as-absent**: Optional fields that were never set serialize to `undefined` in Zod output. Previously `undefined` was treated as a real value — so a field going from absent → set would emit `null` as if the field was being removed. Fixed: `key in obj && obj[key] !== undefined` is the "field exists" test throughout.
2. **Array reference equality**: `current.every((v, i) => Object.is(v, previous[i]))` uses reference equality on array elements — arrays of objects (e.g. `threat` MITRE entries) that are structurally identical but different allocations always diffed. Fixed: `isEqual(current, previous)` from lodash.
3. **`undefined` as "no change" sentinel**: The recursive helper used `undefined` as the "no change" return value, which collided with the absent-key treatment. Fixed: `const NO_CHANGE = Symbol('NO_CHANGE')` is the private sentinel; `undefined` now only means "absent".

---

## Assumptions

- `xpack.alerting.ruleChangeTracking.enabled` is on. Without it, `rulesClient.getHistory` always returns empty and the feature is silently inert (no error).
- `rulesClient.getHistory` accepts the arbitrary `sort: [{ '@timestamp': { order: 'asc' } }]` shape passed by `getHistoryForRule` — the alerting API contract for `sort` is not shown in this diff.
- `old_values` from the server is always a valid RFC 7396 patch. `computeOldValues` and `reconstructBefore` share the same `IGNORED_DIFF_FIELDS` so they can't independently drift.
- `RuleHistoryItem.rule` is the full post-change snapshot; bookkeeping fields are stripped client-side before diffing.
- `EuiFlyout type="push" pushMinBreakpoint="xs"` permanently takes 400px from the main content area regardless of viewport width — acceptable for the target screen sizes.
- `useRuleWithFallback(ruleId)` returns a usable rule even for soft-deleted rules; the page assumes the rule exists to render the header.
- `SpyRoute` with explicit `detailName={ruleId}` is enough for the breadcrumb pipeline to render the History crumb (verified: `getTrailingBreadcrumbs` checks `pathname.includes('/changes-history')` and reads `state.ruleName`).
- `SecurityPageName.rulesChangesHistory` will not be matched by `useNormalizedAppLinks()` — the page deliberately bypasses the AppLink system and relies on hardcoded path checks instead.

---

## Risks

0. **[MEDIUM] Explicit `@timestamp`-only sort drops same-millisecond tiebreakers.** `getHistoryForRule` passes `sort: [{ '@timestamp': { order: 'desc' } }]` (and the `asc` mirror) to address a reviewer ask to make ordering explicit. The `@kbn/change-history` client *replaces* its default sort with the caller's (`opts?.sort ?? defaultSort`), and that default is three-level: `object.sequence` → `@timestamp` → `event.id` (uuidv7), with the latter two purely as tiebreakers. **Chronological order is still correct** — we still sort by `@timestamp`, which is the dominant key — so this is *not* HIGH. The only loss is deterministic ordering among events recorded in the **exact same millisecond**: those now sort non-deterministically, and since `old_values` pairs `items[i]` with `items[i+1]`, a same-ms collision could pair them in the wrong order and produce a wrong diff. Realistic but narrow (requires two changes in the same ms). **Suggested feedback:** pass the full `[object.sequence, @timestamp, event.id]` sort (desc for the page query, asc for `tracking_started_at`) so ordering is explicit *and* keeps the tiebreakers.
   _Files:_ `server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/get_history_for_rule.ts`; root cause in `x-pack/platform/packages/shared/kbn-change-history/src/client.ts`

1. **`HeaderPage` JSDoc is now stale (minor — doc only).** The precedence flipped — old code: `backOptions` wins; new code: `backComponent ?? (backOptions ? ... : null)` so `backComponent` wins. But this is a behavioral no-op: no `HeaderPage` caller passes both. The only `backComponent` caller is `rule_creation_ui/pages/index.tsx` and it doesn't set `backOptions`. The `??` refactor is what enables the inline back-link, so keep it — just fix the JSDoc, which still reads *"Used only if `backOption` is not defined."* Suggested: *"Takes precedence over `backOptions` if both are provided."*
   _File:_ `public/common/components/header_page/index.tsx`

2. **`SecurityPageName.rulesChangesHistory` is a dead shared-type entry.** Added to `@kbn/deeplinks-security` but nothing in the plugin references it — two in-code comments even explain why ("deep linking doesn't support path parameters"). It pollutes a shared enum and will confuse anyone who tries to use it. Delete it and add a comment on the overflow menu item explaining the limitation, or wire it up properly.
   _File:_ `src/platform/packages/shared/deeplinks/security/deep_links.ts`

3. **`tracking_started_at` extra query fires on every page, not just page 1 (downgraded — comment-only).** The inline comment says "page 1 only" but no `if (page === 1)` guard exists, so the ascending `size=1` query runs on every page. **Decision: acceptable** — it's one cheap ES query and we're fine eating it. Not a functional bug. Note it's **server-side only**: both `rulesClient.getHistory` calls run inside the single `/history/_list` handler via `Promise.all`, so it's invisible in the browser network tab (you only ever see one `/history/_list` per page). The remaining ask is just to **fix the misleading comment** so it doesn't claim a guard that isn't there. (Optional tidy-up if ever revisited: gate the query to page 1 — the client only reads `pages[0].tracking_started_at` anyway.)
   _File:_ `server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/get_history_for_rule.ts`

4. ~~**`staleTime: 0` on `useInfiniteQuery`.**~~ **Resolved/stale.** The hook now uses `staleTime: ONE_MINUTE` (60s), not `0`. No longer a refetch-on-every-focus concern.
   _File:_ `public/detection_engine/rule_management/api/hooks/use_infinite_change_history.ts`

5. **`EuiFlyout type="push"` used as a permanent panel — accessibility concern.** `EuiFlyout` is designed as a transient overlay with `ownFocus={true}` semantics. Here `ownFocus={false}` and there is no "close" action — the × navigates away entirely. Screen-reader users expect a flyout to be dismissible; this one isn't. The PR description describes a resizable split-panel (which would be semantically correct) — the implementation diverged.
   _File:_ `public/detection_engine/rule_details_ui/components/changes_history/changes_history.tsx`

6. **Mutation hooks now invalidate history cache — invalidation scope too broad.** `useInvalidateChangeHistory` calls `queryClient.invalidateQueries({ queryKey: CHANGE_HISTORY_QUERY_KEY })` with no ruleId scoping. A bulk edit of 50 rules invalidates the cache for whatever single rule the user happens to have open. Likely fine in practice but not intentional.
   _File:_ `public/detection_engine/rule_management/api/hooks/use_infinite_change_history.ts`

7. **No client-side unit tests for most new components.** `RuleChangesHistoryPage`, `RuleChangesHistoryPageHeader`, `RuleChangesDiff`, `RuleChangesHistoryTimeline`, `ChangeHistoryItem`, `useInfiniteChangeHistory`, `RuleVersion`, `RuleRevision` — all untested. The `changes_diff.tsx` branching (loading / nothing-selected / no-old_values / no-visible-changes / normal diff) is the kind of state machine that breaks silently. `changes_history.test.tsx` exists but only covers auto-selection on ruleId change.
   _Files:_ `public/detection_engine/rule_details_ui/pages/rule_changes_history/**`, `public/detection_engine/rule_details_ui/components/{changes_diff,changes_history_timeline}/**`, `public/detection_engine/rule_management/api/hooks/use_infinite_change_history.ts`

8. ~~**i18n typo in "no diff available" callout.**~~ **Resolved (Jun 19, later session).** Re-read `changes_diff/translations.ts` — the callout now reads *"...a before/after comparison is unavailable. The complete rule state at the time of this update is shown instead."* Punctuation fixed. No action.
   _File:_ `public/detection_engine/rule_details_ui/components/changes_diff/translations.ts`

9. **`subTitle` array builds React nodes without `key` props** in both `RuleChangesHistoryPageHeader` and the existing `RuleDetailsPage`. Minor (React dev warning), same pattern existed before, but this PR adds more elements to the array.
   _Files:_ `public/detection_engine/rule_details_ui/pages/rule_changes_history/rule_change_history_page_header.tsx`, `public/detection_engine/rule_details_ui/pages/rule_details/index.tsx`

10. ~~**`change_history_timeline.tsx` mixes `style={{ ... }}` inline styles with `css={...}` EUI theme tokens.**~~ **Stale/resolved.** Re-checked Jun 19 — the timeline module no longer uses any `style={{ ... }}`; it's `css={...}` throughout. No action.
   _File:_ `public/detection_engine/rule_details_ui/components/changes_history_timeline/change_history_timeline.tsx`

11. **OpenAPI path mismatch — documented path ≠ registered route.** The schema yaml documents the path as `/rules/{ruleId}/history`, but the `RULE_HISTORY_URL` constant (used by the route registration and the client) is `/rules/{ruleId}/history/_list`. The yaml `paths:` key only drives codegen/doc generation, so nothing breaks at runtime — but the generated OpenAPI spec documents the wrong URL. Fix by aligning the yaml path with the constant (or dropping `_list`). Separately, `_list` is a novel verb — the established list endpoints use `_find`/`_search`.
   _Files:_ `common/api/detection_engine/rule_management/rule_history/rule_history_route.schema.yaml`, `common/api/detection_engine/rule_management/urls.ts`

12. **Offset pagination over a live log → duplicate/skipped rows + duplicate React keys.** `useInfiniteChangeHistory` pages with `getNextPageParam` offset math (`page * per_page < total`) and the server fetches offset windows (`from = (page-1)*perPage`). Offsets assume a stable list. If a change is recorded between loading page 1 and scrolling to page 2 (another tab/user, or a background mutation), every item shifts down, so page 2 re-returns the item that was last on page 1 — the flattened `items` then has a duplicate `id`, and the timeline keys rows by `item.id` → React duplicate-key warning + a doubled row (or a skipped item on deletion). The non-ruleId-scoped invalidation (risk 6) with `refetchType: 'active'` masks this *after a user-triggered mutation* (refetches all pages consistently), but a plain scroll against externally-changed data still hits it. `search_after`/cursor pagination keyed on the `[object.sequence, @timestamp, event.id]` tuple would avoid it.
   _Files:_ `public/detection_engine/rule_management/api/hooks/use_infinite_change_history.ts`, `public/detection_engine/rule_details_ui/components/changes_history_timeline/change_history_timeline.tsx`

13. **Selected item can be orphaned after a refetch (minor).** `selectedItem` is a value snapshot in parent state. If an invalidation refetch reorders or drops the selected revision, the timeline highlight (`selectedItem?.id === item.id`) matches no row, but `RuleChangesDiff` keeps rendering the stale `selectedItem`. No crash — just a quiet mismatch between what's highlighted and what's shown.
   _File:_ `public/detection_engine/rule_details_ui/components/changes_history/changes_history.tsx`

14. **Orphaned / over-exported symbols (minor — dead code).** Found in the Jun 15 orphaned-exports scan; re-checked Jun 19 (twice — still present in the later session): `INLINE_CHANGED_FIELDS_LIMIT` is defined in the timeline `constants.ts` but never imported anywhere — its doc comment describes inline-badge + "+N" overflow behavior that isn't wired up (`change_history_item.tsx` only renders a "N changes" count via `N_CHANGES`, no badges/overflow). `UseInfiniteChangeHistoryArgs` is `export`ed but only used as the local parameter type in its own file (could drop the `export`). (`POPOVER_CHANGED_FIELDS_LIMIT`, also flagged on Jun 15, has since been removed — resolved.) Delete the unused constant or wire up the overflow behavior it documents.
   _Files:_ `public/detection_engine/rule_details_ui/components/changes_history_timeline/constants.ts`, `public/detection_engine/rule_management/api/hooks/use_infinite_change_history.ts`

15. **Infinite-scroll observer attaches only by coincidence (latent silent breakage).** In `change_history_timeline.tsx` the `IntersectionObserver` effect has deps `[onLoadMore]`, but the `sentinelRef` div it observes is rendered *after* the empty/loading early returns. First render (`items.length === 0 && isLoading`) returns `<Loading />` with no sentinel, so the effect bails (`sentinelRef.current` is null). When page 1 lands and the sentinel mounts, the effect **only re-runs if `onLoadMore`'s identity changed** — nothing in the deps tracks that the sentinel now exists. It works today only because the parent's `onLoadMore` (`handleNextPageLoading`, deps include `hasNextPage`) changes identity exactly when `hasNextPage` flips false→true. Stabilize `onLoadMore` (a ref, or a case where `hasNextPage` never flips) and the observer never attaches → infinite scroll silently dies, no error. Fix: use a **callback ref** on the sentinel (attach/detach the observer as the node mounts/unmounts) or add a dep reflecting the sentinel's presence.
   _File:_ `public/detection_engine/rule_details_ui/components/changes_history_timeline/change_history_timeline.tsx`

16. **`memo()` on `ChangeHistoryItem` is defeated by an inline `onClick` closure (perf).** The timeline maps rows with `onClick={() => onSelectItem?.(item)}`, allocating a new closure per row every render. `ChangeHistoryItem` is wrapped in `memo(...)`, but the changing `onClick` prop fails the shallow compare, so **every row re-renders on every parent render** (selection change, refetch, theme tick). On an infinite-scroll list that grows to hundreds of rows that's real wasted work, and the explicit `memo` buys nothing. Fix: pass `item` + a stable `onSelect(item)` and bind inside the child, or memoize per-item handlers.
   _Files:_ `public/detection_engine/rule_details_ui/components/changes_history_timeline/change_history_timeline.tsx`, `.../change_history_item.tsx`

17. **IntersectionObserver has no `root` — observes the viewport, not the scroll container (robustness).** The scrollable element is the inner `changesTimeline` div (`overflow-y: auto`), but the observer is created with no `root`, so intersection is computed against the browser viewport. It works approximately because the flyout is full-height, but it's not anchored to the actual scrolling element; if the layout changes (not full height, nested scroll, reused elsewhere) the trigger point drifts. Fix: pass `root: <scroll-container ref>` so "scrolled to the bottom of the list" is what fires `onLoadMore`.
   _File:_ `public/detection_engine/rule_details_ui/components/changes_history_timeline/change_history_timeline.tsx`

18. **Long run of non-diffable changes → diff panel lands empty, then jumps mid-scroll.** When a consecutive run of non-diffable changes (e.g. repeated enable/disable) is longer than `PER_PAGE` (20), page 1 contains no diffable item. `useChangeHistoryAutoSelection` does `items.find(DIFFABLE_CHANGE_ACTIONS)`, gets `undefined`, and bails **without setting `lastAutoSelectedRuleRef`** — so it stays armed and auto-selects the first diffable item the instant page 2+ loads, making the diff panel suddenly populate while the user is scrolling. Inherent to offset pagination + client-side diffable filtering (related to risk 12); the timeline shows all events but "what to diff by default" is resolved against only the loaded pages. Fix options: (1) MVP client-only — decide auto-select once on page-1 settle, set the ref even when nothing diffable, and show an honest empty state ("no comparable changes in the most recent events — scroll and pick one"); (2) bounded auto-fetch until a diffable item appears (papers over the offset weakness); (3) proper — server returns the latest diffable change + its predecessor as a separate diff seed, decoupled from pagination (follow-up, lines up with `search_after`/deep-link arc); (4) product — "comparable changes only" filter / collapse non-diffable runs. Recommendation: do #1 now, log #3 as follow-up.

19. **[NEW Jun 19] Timeline's empty-state (`NoData()`) is now unreachable dead code + duplicate/drifted copy.** The empty state moved up to the parent: `changes_history.tsx` short-circuits on `hasNoHistory = !isLoading && items.length === 0` and renders its own image-based `EuiEmptyPrompt` (`no_change_history.png`) *before* the flyout/timeline ever mount. So `change_history_timeline.tsx`'s `NoData()` branch (`items.length === 0` while not loading) can never fire — the only way the timeline renders with zero items is while `isLoading` is true, which hits `Loading()` instead. Dead with it: the timeline module's `NO_CHANGE_HISTORY_TITLE` / `NO_CHANGE_HISTORY_BODY` (ids `...ruleChangeHistory.emptyPromptTitle` / `emptyPromptBody`), which are only consumed by `NoData()`. Compounding it, the **copy has drifted** between the two modules — timeline says *"No change history yet"* while the live parent (`changes_history/translations.ts`, ids `...ruleChangesHistory.noChangeHistoryTitle`/`Body`) says *"No changes have been recorded for this rule yet." / "Subsequent edits will appear here."* Cleanest fix: delete `NoData()` and its two i18n keys from the timeline module. This is the clearest single orphan created by the empty-state-moved-to-parent churn.
   _Files:_ `public/detection_engine/rule_details_ui/components/changes_history_timeline/change_history_timeline.tsx`, `.../changes_history_timeline/translations.ts`

19. **[NEW Jun 19] Inline `style={{}}` left behind by the emotion migration (minor — consistency).** `rule_change_history_page.tsx` still sizes its `SecuritySolutionPageWrapper` via a raw `style={{ height: ..., display: 'flex', ... }}` object, even though the rest of the feature was migrated to emotion `css` (there's a dedicated "use emotion/react instead React's style" commit on the branch). Out of place — convert to `css={...}` for consistency with the sibling components.
   _File:_ `public/detection_engine/rule_details_ui/pages/rule_changes_history/rule_change_history_page.tsx`

---

## Open questions

- Why `EuiFlyout type="push"` instead of the `EuiResizableContainer` the PR description promises? Scope cut, Figma drift, or deliberate? The description is actively misleading for reviewers. At minimum update the description.
- Should `SecurityPageName.rulesChangesHistory` be removed before merge? It's a no-op in a shared platform type.
- `staleTime: 0` — intentional? Any scenario where "always fresh" is needed here?
- The `ruleChangesHistoryEnabled` flag gates the route, the History menu entry, and the revision/version subtitle badges together. Are the badges part of this feature or an independent concern? If a user has the flag off they also lose the version/revision info.
- `useInvalidateChangeHistory` uses a bare `CHANGE_HISTORY_QUERY_KEY` with no ruleId scope — is that intentional, or should cache invalidation be per-rule?
- `RuleChangesDiff` has a warning callout for `ruleUpdate`/`ruleImport`/`ruleRevert` with no `old_values`. After the `compute_old_values` rewrite, can that path still be reached for normal mutations? If not, is it dead code or a guard for edge cases?
- Final UI copy sign-off from `@nastasha-solomon`? The PR issue mentions this as an open action item. "Version history", "Rule changes history", "History" breadcrumb — terminology is inconsistent.
- Is item-level deep linking (URL → specific `changeId`) on the roadmap? It's **not supportable as-is**: (a) offset pagination only holds the pages loaded so far and you can't compute which page a given `changeId` is on without scanning, so the item may not be in memory; (b) even if a URL param seeded `selectedItem`, `useChangeHistoryAutoSelection` overwrites it with the first diffable item on load. Supporting it needs a by-id fetch endpoint (returning the item *and* its predecessor for `old_values`) plus auto-select deferring to a URL-provided selection. (This is separate from the dead `SecurityPageName.rulesChangesHistory` enum in risk 2 — removing that enum doesn't get you item-level linking.)
- Should pagination move to `search_after`/cursor (keyed on `[object.sequence, @timestamp, event.id]`) to fix the offset-drift dup/skip problem (risk 12) and enable item-level deep linking?

---

## Notes for your codebase map

- **Detection rule change history is alerting-framework-owned.** `rulesClient.getHistory({ module, ruleId, from, size, sort? })` is the sole entry point; security passes `module: 'security'`. No security-specific storage layer. The Alerting plugin must also have `xpack.alerting.ruleChangeTracking.enabled: true` for events to be captured.
- **`old_values` is an RFC 7396 merge patch.** `computeOldValues` (server) produces it; `reconstructBefore` (client, `changes_diff/utils.ts`) applies it to the current snapshot to recover the before-state. `IGNORED_DIFF_FIELDS` is shared across both via `extract_changed_field_names.ts`.
- **Authorization pattern for new rule read operations:** add the operation to `readOperations.rule` in `authorization_core/.../alerting.ts`. All rule-consumer feature privileges pick it up automatically — no per-consumer wiring.
- **`HeaderPage` is the canonical Security solution page header** (~35 callers). Subtitles are arrays of React nodes. After this PR it also supports `backInlined` for an inline back link on the same row as the title.
- **`EXTRA_HIDDEN_TIMELINE_PATHS` + `isRuleChangesHistoryPath`** are workarounds for routes that don't have an AppLink (`useNormalizedAppLinks` isn't consulted for routes registered inside `RulesContainer`). If more such pages get added this pattern will need to be formalized.
- **`DiffView`** (`rule_management/components/rule_details/json_diff/diff_view.tsx`) is now the shared unified-diff component used by both the upgrade-rule UI and the changes-history UI. It's `renderGutter`-pluggable and handles the empty-hunks edge case.
- **`useInvalidateChangeHistory`** exports from `use_infinite_change_history.ts` and is imported by all four rule-mutation hooks. This is the cache invalidation pattern for keeping the history panel fresh after mutations.

---

## Review activities

**Jun 15 — earlier sessions (from chat transcripts):**

- **Reviewed `changes_diff.tsx` + `reconstructBefore` semantics.** Verified `old_values` is generated server-side in `compute_old_values.ts` as an RFC 7396 merge patch and that `reconstructBefore` (`changes_diff/utils.ts`) matches the spec (`null` → key deleted, value → key set). **Flagged an RFC 7396 null-ambiguity** — the patch can't distinguish a deleted key from a key legitimately set to `null`. Concluded it's **theoretical, not exploitable** in the current schema: the only `nullable: true` field in the whole `rule_schema` is `actions[].throttle`, and `mergePatchFromTo` treats arrays as atomic (whole-array replace), so it never emits a `null` patch for it. Recommended a code comment documenting the limitation + a `compute_old_values.test.ts` guard if any rule field ever becomes nullable.
- **Walked through `changes_history.tsx`; top-3 concerns + `memo()` analysis.** Concluded `memo()` on `RuleChangesHistory` is technically effective (the parent memoizes the `header` prop via `useMemo`, so shallow-equality holds) but borderline — optimizing a boundary with no measured problem; a "nit, drop or leave."
- **Orphaned-exports scan of the PR's changed files.** Flagged `INLINE_CHANGED_FIELDS_LIMIT`, `POPOVER_CHANGED_FIELDS_LIMIT`, and `UseInfiniteChangeHistoryArgs` as unused / exported-but-internal-only → logged as risk 14 (re-checked Jun 19: `POPOVER_CHANGED_FIELDS_LIMIT` since removed; the other two still stand).

**Jun 19 — this session:**

- Added a file path under each of the 10 risks for quick navigation (risk 2 lives in the shared `@kbn/deeplinks-security` package; the rest in `security_solution`).
- **Verified `perPage → per_page` rename is safe.** Traced the full chain — client query (`per_page`) → server query schema → route handler (`per_page: perPage` alias) → server response (`per_page`) → client hook (`lastPage.per_page`). All consistent. Leftover: UI test mock in `changes_history.test.tsx` still uses `perPage: 20` (harmless dead key, component never reads it). The rename aligns the response with the internal-API convention (prebuilt-rules review endpoints already use `per_page`); the public `_find`'s `perPage` is the legacy outlier.
- **Checked consistency vs similar APIs.** Found OpenAPI path mismatch (yaml `/history` vs constant `/history/_list`) → added as risk 11. `_list` verb diverges from `_find`/`_search`. Response uses `items` where `_find` uses `data` (both exist in-repo, not wrong).
- **Re-examined risk 1 (`HeaderPage` precedence).** Confirmed precedence flipped via `git diff` but it's a behavioral no-op — no caller passes both `backComponent` and `backOptions`. Downgraded to a doc-only fix; the `??` refactor is required for the inline back-link feature. Suggested JSDoc wording provided.
- Marked risk 4 (`staleTime: 0`) as stale — current code uses `staleTime: ONE_MINUTE`.
- **Investigated review comment [r3364604035](https://github.com/elastic/kibana/pull/269617#discussion_r3364604035) (banderror) re: explicit sort.** Fetched the comment via `gh api`. The author addressed it by adding `sort: [{ '@timestamp': { order: 'desc' } }]`, but that overrides the change-history client's three-level default sort (`object.sequence` → `@timestamp` → `event.id`/uuidv7), losing same-millisecond tiebreakers → potential silently-wrong diffs. Logged as risk 0 (HIGH). Drafted a reply for the PR thread suggesting the author pass the full tiebreaker sort instead.
- **Traced `useInfiniteChangeHistory` and its consumers** (hook, `use_change_history_auto_selection.ts`, `change_history_timeline.tsx`). Found offset-pagination-over-live-data dup/skip + duplicate React key issue (risk 12) and the orphaned-selection-after-refetch case (risk 13). Analyzed the changeId deep-link scenario: not supportable today (offset pagination can't locate an unloaded item + auto-selection clobbers any URL-seeded selection) → added to Open questions, plus a follow-up on moving to `search_after`/cursor pagination.
- **Re-validated risk 3 (`tracking_started_at` extra query).** Confirmed no `page === 1` guard — the asc `size=1` query runs every page. Clarified it's **server-side only** (both ES queries run inside one `/history/_list` handler via `Promise.all`), which is why the user couldn't see it in the browser network tab; suggested ES query logging / search slowlog to observe it. **Decision: accept the extra ES hit**; downgraded risk 3 to comment-only (just fix the misleading "page 1 only" comment).
- **Discussed risk 7 testing strategy.** Confirmed there are **no Cypress/Scout tests** for the feature (backend is well covered: `change_tracking.ts` API integration + server unit tests; client only has `changes_history.test.tsx` for auto-selection). Agreed UI unit tests on presentational pieces are low-value/brittle and should be skipped; the high-value targets are the pure logic (`changes_diff/utils.ts` `reconstructBefore`, `extract_changed_field_names.ts`, hook `getNextPageParam`) and the `changes_diff.tsx` state machine. Conclusion: a Scout smoke does **not** substitute for the logic units.
- **Wrote two example tests locally (to be reverted — illustrative for the PR ask):**
  - `changes_diff.test.tsx` — RTL test covering all 5 branches + the `reconstructBefore` old→new reconstruction (stubs `DiffView`). Ran Jest: **6/6 pass**.
  - `test/scout/ui/parallel_tests/detections/rule_changes_history.spec.ts` — Scout UI smoke (create+edit rule → navigate → timeline + auto-selected diff → select another entry). Not run (needs live stack); flagged assumptions: `apiServices.detectionRule` return shape / `patchRule`, and the two FF/config args (`ruleChangesHistoryEnabled`, `xpack.alerting.ruleChangeTracking.enabled`).
- **Confirmed Scout is the right harness, not FTR** — security_solution already has a full Scout-security UI harness (config, fixtures, roles, `apiServices.detectionRule`), so adding one spec is cheap; no need to stand up FTR. Drafted PR review comments for both the unit-test and Scout asks.
- **Deep-dived `change_history_timeline.tsx`** (+ `change_history_item.tsx`, `change_history_footer.tsx`). Found three new risks beyond 10/12: the infinite-scroll observer attaches only by coincidence of `onLoadMore` changing identity (risk 15, latent silent breakage), `memo()` on `ChangeHistoryItem` defeated by the inline `onClick` closure (risk 16, perf), and the `IntersectionObserver` having no `root` so it watches the viewport not the scroll container (risk 17). Noted a minor cosmetic: bottom spinner shows during full refetches (parent passes `isLoading || isFetching`).
- **Severity pass.** Downgraded risk 0 HIGH → MEDIUM (chronological `@timestamp` order is preserved; only exact-same-ms tiebreaks are lost). Crossed out risk 10 as stale/resolved (timeline module uses `css={...}` throughout, no inline `style={{}}`). Risk 4 already marked stale; risk 3 already accepted/comment-only.

**Jun 19 — risk 15 deep-dive + fix (later in session):**

- **Confirmed risk 15 is latent, not a live bug.** Re-read `change_history_timeline.tsx` and the parent `changes_history.tsx`. The observer effect has deps `[onLoadMore]` and the sentinel `<div ref={sentinelRef}/>` mounts *below* the `items.length === 0` early returns. It works today only because the parent's `onLoadMore` (`handleNextPageLoading`, deps `[hasNextPage, isFetchingNextPage, fetchNextPage]`) gets a new identity exactly when `hasNextPage` flips `false→true` on the page-1 render — same render the sentinel mounts. Verified no currently-reachable state breaks (multi-page works via the flip; single-page never flips but has nothing to load; cached-data attaches on the mount effect). So it's a **silent-failure trap**, not a current break.
- **Clarified the real risk:** the component isn't self-contained — its effect deps don't capture the actual trigger condition (sentinel presence), so it piggybacks on the parent's `onLoadMore` reference churning. The reasonable/textbook cleanup (stabilize `onLoadMore` via ref or trim its deps — which still fires `fetchNextPage`, just keeps a stable reference) silently kills infinite scroll: no error, no failing test, scroll-to-bottom just does nothing.
- **Applied the fix** to `change_history_timeline.tsx`: swapped the `useEffect` + `useRef` for a **callback ref** on the sentinel (`observerRef` + `onLoadMoreRef` read through `.current`, deps `[]`) so the observer attaches when the node mounts regardless of `onLoadMore` identity. Lints clean. (Also the clean spot to add `root: <scroll-container>` for risk 17, left as follow-up.)
- **Found prior art in-repo** confirming the callback-ref approach is the established pattern: `response-ops/rule_form/.../template_list.tsx` (`setPaginationObserver`, lines ~106–121) and `triggers_actions_ui/.../rule_tag_filter.tsx` (`setObserver`, lines ~212–221). Both attach via callback ref + a separate unmount-cleanup `useEffect`, and both pass `root`. Difference: they keep `onLoadMore`/`fetchNext` in the callback-ref deps; our version reads it through a ref (deps `[]`) so the observer never churns — same end result.

**Jun 19 — full re-scan for orphaned / out-of-place items (this session):**

- **Re-pulled the actual PR file set the right way.** `main...HEAD` was showing 3298 files because local `main` is stale; switched to `git merge-base origin/main HEAD` (= `408590635258`) → real diff is **62 files, +2402/−175**. Pulled the GitHub file list via `gh pr view 269617 --json files` to cross-check.
- **Read the branch commit log** — the author has been actively cleaning up ("remove orphaned definitions", "clean up leftovers", "remove an unused constant", "remove current version", "use emotion/react instead React's style"). The re-scan was specifically to catch what that churn left behind.
- **Found risk 18 (new): timeline `NoData()` is now dead code.** The empty state was moved up into `changes_history.tsx` (image-based `EuiEmptyPrompt` gated on `hasNoHistory`), which short-circuits before the timeline mounts — so `change_history_timeline.tsx`'s `NoData()` branch is unreachable, and its two i18n keys (`emptyPromptTitle`/`emptyPromptBody`) are orphaned. Confirmed `RuleChangesHistoryTimeline` has exactly one consumer (`changes_history.tsx`), so unreachability is total. Also flagged the **drifted empty-state copy** between the two translation modules.
- **Found risk 19 (new): inline `style={{}}` in `rule_change_history_page.tsx`** left behind by the emotion migration — out of place vs the rest of the feature.
- **Re-confirmed risks 2 & 14 still live:** `SecurityPageName.rulesChangesHistory` is still a dead shared-enum entry (only referenced by two "we can't use this" comments in `rule_actions_overflow/index.tsx` and `rule_change_history_page.tsx`); `INLINE_CHANGED_FIELDS_LIMIT` and the `export` on `UseInfiniteChangeHistoryArgs` are both still present.
- **Marked risk 8 resolved** — the no-diff callout punctuation typo is fixed in the current `changes_diff/translations.ts`.
- **Verified the clean items** so they don't get re-flagged: `no_change_history.png` *is* used now (parent empty state), the version/revision badges (`RuleVersion`/`RuleRevision`) are both wired into the rule-details subtitle and consistently gated on `isRuleChangesHistoryEnabled`, the IntersectionObserver callback-ref fix (risk 15) is in place, `staleTime` is `ONE_MINUTE`, and the server `compute_old_values.ts` / `map_rule_history_item.ts` were fully moved into `methods/utils/` with **no leftover copies** at the old paths.
- **Noted the stale test mock** (`changes_history.test.tsx:94` still uses `perPage: 20` vs the renamed `per_page`) — harmless (unread by the component), consistent with the earlier-session note.
- **Recommendation to the user:** the cleanest single win is risk 18 (delete `NoData()` + its two i18n keys); risks 2, 14, 19 are safe follow-on deletions/tidy-ups.
- **Verified the PR comment for accuracy.** Claims hold; tone correctly frames it as fragile/non-blocking, not currently broken. One wording fix: the repro's `observe()` is called **zero** times (not "not the second time" — it never fires the first time either, since the loading-render bails before the sentinel mounts). Recommended adding a "not blocking / not broken today" preamble so it doesn't read as a merge gate.

**Jun 19 — non-diffable-run auto-selection bug (new, risk 18):**

- **User-reported bug:** with a long run of consecutive non-diffable changes (e.g. someone repeatedly enabling/disabling a rule), if that run is longer than the page size (`PER_PAGE = 20`), the diff panel lands empty and then **suddenly populates mid-scroll** once page 2+ brings in the first diffable change. Reproduced via reasoning, not the live stack.
- **Root cause:** two concerns are tangled — the timeline shows *all* events, but the "what to diff by default" is resolved client-side by scanning only the *loaded* pages. In `use_change_history_auto_selection.ts`, `items.find(DIFFABLE_CHANGE_ACTIONS)` returns undefined when page 1 is all non-diffable, and the effect bails **without setting `lastAutoSelectedRuleRef`** — so it stays armed and fires the moment page 2 arrives. That's the jump. Inherent to offset pagination + client-side diffable filtering (related to risk 12); not fixable purely client-side-after-the-fact unless every change is diffable.
- **Suggested options (cheapest first):** (1) MVP client-only — decide auto-select *once* when page 1 settles; if nothing diffable, set the ref anyway so it can't ambush later, and show an honest empty state ("no comparable changes in the most recent events — scroll and pick one"). Files: `use_change_history_auto_selection.ts` + `changes_diff.tsx`/`translations.ts`. (2) Auto-fetch a bounded number of pages until a diffable item appears (papers over the same offset weakness — low priority). (3) Proper fix — server returns the latest diffable change (+ its predecessor for `old_values`) as a separate diff seed, decoupled from timeline pagination (follow-up; lines up with the `search_after`/deep-link arc). (4) Product: a "comparable changes only" filter / collapse non-diffable runs — raise with `@nastasha-solomon`.
- **Recommendation:** do #1 now (small, kills the jarring jump), log #3 as follow-up. Logged as risk 18.
