# PR Review: #304597 — [9.6] [Security Solution] Migrates Rule Details page to use AppHeader (#300180)

**PR:** [elastic/kibana#304597](https://github.com/elastic/kibana/pull/304597) by @jr-araque
**Original PR:** [elastic/kibana#300180](https://github.com/elastic/kibana/pull/300180) (merged to main 2026-11-09, closes [#280387](https://github.com/elastic/kibana/issues/280387))
**Created Date: 2026-11-11**

**Scale:** Substantive original PR (57 files, +3099/−1375), but this is an automated backport (`backport` tool, cherry-pick of `b055ae1715b3`). Review focuses on backport fidelity, not re-reviewing the feature.

## Summary

Backports the Rule Details page move from the old `HeaderPage` to the shared `SecurityAppHeader`/`AppHeader`. Adds `RuleDetailsAppHeader` and four hooks (badges, metadata, menu, snooze) with tests, moves the tabs into the header, deletes `RuleActionsOverflow` and `ModifiedRuleBadge`, and adds `isRuleDetailsPath` / `isPageWithAppHeaderPath` helpers so the global header stops mounting its legacy action menu on these pages.

## Backport fidelity

I diffed the backport commit (`eefd2992`, equals PR head) against the original main commit (`b055ae17`) patch-for-patch (`-U0`, ignoring `index` lines).

- 57 files in both. Only differences are line-number offsets, plus three files where 9.6 context differs from main:
  - `app/home/global_header/index.tsx` and its test: main's version also removed `isEndpointManagementPath` / `isManageLandingPath`; 9.6 doesn't have those, so it removes `isConfigurationsPath` instead. Backport keeps `isConfigurationsPath` inside `isPageWithAppHeaderPath`.
  - `helpers.tsx` / `helpers.test.tsx`: same story. 9.6 list is `ChangesHistory, RulesManagement, RulesAdd, RuleDetails, CoverageOverview, Exceptions, CloudSecurityPosture, Configurations` — no endpoint-management / manage-landing entries. Test cases for `/manage` and `/administration/endpoints` correctly sit in the "returns false" group on 9.6 (they return true on main).
  - Two FTR line offsets only.
- The adaptation looks like the correct resolution: `isEndpointManagementPath`/`isManageLandingPath` don't exist anywhere on 9.6 (grep confirms), and `isConfigurationsPath` still does.

## Verification I ran locally (Node 24.22.1)

- `helpers.test.tsx`: 60/60 pass.
- `detection_engine` config, `rule_details_ui/pages/rule_details`: 10 suites / 110 tests pass.
- `app` config, `home/global_header`: 27/27 pass.
- No dangling references to deleted modules (`ModifiedRuleBadge`, `RuleActionsOverflow`). The remaining `expectModifiedRuleBadge*` hits are Cypress task helpers, which the PR updates.
- **Not run:** `type_check` for the security_solution project, ESLint, i18n check, Cypress/Scout/FTR.

## CI

At time of review: 17 success, 19 skipped, 1 pending (`kibana-ci`, [build 537100](https://buildkite.com/elastic/kibana-pull-request/builds/537100)). PR is `MERGEABLE`. Labels on the source PR include `v9.7.0` and `v9.6.1`.

## Risks

1. Cypress specs (`rule_snoozing`, `privileges`, `fill_all_rule_gaps`, `revert_prebuilt_rule`, etc.) were rewritten against new selectors. They're the most likely thing to behave differently on 9.6 and I didn't run them. Wait for the Buildkite result.
2. Behavior on the 9.6 global header: the combined `isPageWithAppHeaderPath` is now the single gate. If any 9.6-only page relied on `isConfigurationsPath` standalone, that's covered; nothing else in 9.6 was found using it.
3. This is a large UI change landing in a patch release (9.6.1). That's a product call, not a backport defect.

## Open questions

- Is the pending `kibana-ci` check the full pipeline including Cypress? Worth confirming before merge.
- Is the Chrome Next AppHeader (the shared `SecurityAppHeader` wrapper) fully present in 9.6? Tests pass, so imports resolve, but behavior of the sibling migrated pages on 9.6 wasn't checked.

## Notes for your codebase map

- Security Solution global header suppresses its legacy action menu through one predicate (`isPageWithAppHeaderPath`) over per-page path matchers in `public/helpers.tsx`; each AppHeader migration adds a matcher.
- Rule details tab routing is `RULES_PATH/id/:detailName/:tabName(<RuleDetailTabs>)`, so `/rules/id/:id` (no tab) and `/edit` don't count as app-header pages.
- 9.6 vs main drift in this area: main has endpoint-management and Manage landing app-header paths that 9.6 lacks, so backports of AppHeader migrations will conflict in `global_header/index.tsx` and `helpers.tsx`.

## Follow-up Review Activities

1. **Manual side-by-side testing.** Checked out the backport branch locally and ran several manual tests next to an existing `main` instance, comparing the new AppHeader against the previous header on the same page, to see if anything looked strange. An agent also went through the backported code with no significant findings. Comment and approval recorded on the PR: [review comment](https://github.com/elastic/kibana/pull/304597#pullrequestreview-5857654550), approved at 11:07 UTC.
   - Concluded the backport works as expected and the author handled the AppHeader trade-offs well. Findings below are design choices, recorded for follow-up and not blocking this backport.
   - **Metadata and toolbar cut off the rule name.** The enabled/version/revision badges plus toolbar buttons squeeze the title (screenshot in the review).
   - **"Refresh status" button** could be shortened to "Refresh".
   - **Minor: snoozing collapses the version/revision badges** (screenshots in the review).

2. **CI result (build 537100).** Per the bot comment: build succeeded but flaky. Failed steps were FTR Configs #6, Scout Lane #14 and #16 (stateful-classic), and Defend Workflows Cypress #14. The review concluded these are the usual flakiness and unrelated. I haven't opened the individual step logs, so that's taken from the review, not verified by me.

3. **Bot review comment (Libra, P3) on `use_rule_snooze.tsx:70`.** Claims legacy schedules with an invalid recurrence (e.g. `tzid: 'invalid'`) now show as an ordinary scheduled snooze, or vanish if they have no `id`, where the old badge warned about invalid snoozes.
   - Confirmed in `getSnoozeBadge`: there's no invalid-snooze branch, and entries without an `id` are filtered out and produce no badge.
   - Not verified: what the old badge did for invalid snoozes, or whether it's a real regression. This is the same code as on main (not a backport divergence), so it's a question for the #300180 author.
