# PR Review: #274337 — [Security Solution] Add test plan for rule changes history

**PR:** [elastic/kibana#274337](https://github.com/elastic/kibana/pull/274337) by @maximpn

**Scale:** Small PR (docs-only, one file). Reviewed as a test-plan fidelity check against the shipped 9.5 feature, not as a code-change review.

---

### Context / Motivation

This is the missing “Write test plan(s)” checkbox on the 9.5 release-readiness list in [security-team#12367](https://github.com/elastic/security-team/issues/12367) (Detection rule changes history and comparison of revisions). That epic’s original MVP explicitly excluded restore:

> We should NOT include the following features that will be developed after this MVP: … Restoring from / reverting to a historical revision

Restore later shipped as its own epic, [security-team#12432](https://github.com/elastic/security-team/issues/12432) (now closed). The PR description is honest about covering both: capture + history page + restore. The original epic also described a History *tab* on Rule Details; what shipped is a dedicated page opened from the overflow **History** menu item.

Acceptance testing and exploratory testing are already marked done on the epic. This plan is the written contract for remaining automation, especially e2e — almost all API integration tests already exist on `main`.

### Validating the issue — does this PR address it?

The “write a test plan for 9.5” ask is real, and this document is the right artifact in the right folder (`docs/testing/test_plans/detection_response/rule_management/`). It follows the local template, uses Gherkin, and maps cleanly to the shipped API + page.

The residual caveat is fidelity: several scenarios describe UI or restore behavior that the current code does not do, and a large share of the API scenarios are already automated without the plan saying so. That’s the part worth pushing on before anyone treats this as the backlog.

### Summary

Adds a 751-line test plan for detection rule changes history: capturing a snapshot on every rule change (including bulk and pre-tracking rules), viewing the dedicated History page (list, auto-select, diff, infinite scroll, tracking-started footer), and restoring a historical revision via UI and API (concurrency, RBAC, deleted-rule recreate).

Stated intent matches the file. Scope is broader than epic #12367’s original MVP because restore is included — that’s correct for 9.5, not scope creep. Out of scope is listed as: upgrade/compat, diff vs current revision, arbitrary-pair diff, filtering, and surfacing history write failures.

### Files touched

- `x-pack/solutions/security/plugins/security_solution/docs/testing/test_plans/detection_response/rule_management/rule_changes_history.md` — new plan next to the existing (much thinner) rule-management plans. CODEOWNERS: `@elastic/security-detection-engineering`.

### Flow trace

The plan’s main path, checked against the code:

1. A detection-rule write (create / update / install / upgrade / duplicate / import / revert / restore) goes through Alerting change tracking and lands as a document in the history data stream, with `event.action`, user, timestamp, and a full `RuleDomain` snapshot.
2. Security Solution’s `GET` history route (`ruleHistoryRoute`) gates on the `securitySolution:enableRuleChangesHistory` advanced setting (403 if off), then `getHistoryForRule` asks Alerting for a newest-first page (`per_page + 1` lookback so `old_values` still works across page boundaries) plus the oldest item for `tracking_started_at`.
3. `mapRuleHistoryItem` converts snapshots to `RuleResponse` and computes `old_values` as an RFC 7396 merge patch (`computeOldValues`). Arrays are whole-value replacements. Create / first-item cases get `old_values: null`.
4. The Rule Details overflow menu shows **History** only when both the `ruleChangesHistoryEnabled` experimental flag *and* the advanced setting are on. That opens the dedicated page, not a tab.
5. The timeline auto-selects the first **diffable** item (`DIFFABLE_CHANGE_ACTIONS`: update/create/install/upgrade/duplicate/import/revert/restore) — not necessarily the newest row. Enable / disable / snooze / API-key / delete rows are subdued and not selectable for a diff, but their overflow menu still offers restore.
6. The diff panel strips `IGNORED_DIFF_FIELDS` (`rule_source`, `revision`, `updated_at`, `updated_by`, `created_at`, `created_by`, `execution_summary`, `meta`). For create/install with no predecessor it renders the full snapshot as an insertion. For import/revert/upgrade without a prior snapshot it shows the “no prior state” callout.
7. Restore is `POST` with `changeId` (which snapshot) and optional `revision` (optimistic concurrency). Existing-rule restore applies the snapshot but **keeps the current `enabled` value**. Deleted-rule restore omits `revision` and recreates the rule **disabled**. Both paths run `validateFieldWritePermissions` (exceptions / note / investigation_fields / enabled). A successful restore writes a new `rule_restore` item; it never rewrites history.

### Assumptions

- The plan assumes a tester already has the History page reachable. In code that also requires the experimental flag `ruleChangesHistoryEnabled`, not only the advanced setting named in the Feature availability scenario.
- Existing API tests are `@ess @skipInServerless` because Alerting change-tracking / the Security Solution flag are not treated as permanently on in Serverless yet. The plan never states ESS vs Serverless.
- License is unstated. Epic #12367 says Basic/Standard/Essentials; restore epic #12432 says Enterprise. I couldn’t tell from the code which one 9.5 actually ships.
- `getHistory` is space-scoped via Alerting’s `context.spaceId`. A cross-space request returns empty 200, not 404 — the plan’s space scenario matches that. There is no existing integration test for it.
- For a deleted rule, Alerting resolves auth from the latest snapshot’s `alertTypeId` / `consumer`. If those are missing, it returns empty `{ total: 0, items: [] }` with no error — the “type metadata cannot be resolved” scenario is real (`get_rule_history.ts`).
- Restore identity is `changeId`. `revision` is only a concurrency hint. The plan’s “non-existent revision → 404” wording treats them as the same thing.
- `mapRuleHistoryItem` always reads `current.user.id` / `current.user.name`. The OpenAPI schema allows `user: null` for system-driven actions, and the timeline already has a “Elastic” fallback (`item.user?.name ?? SYSTEM_USER_LABEL`). I didn’t find a mapper path that actually emits `null`.

### Risks

- **Restore success criteria over-claim “full snapshot”.** `restore_rule_state.ts` sets `enabled: existingRule.enabled`. `restore_deleted_rule.ts` always creates `enabled: false`. The Gherkin “current configuration should match that revision’s snapshot” will fail if someone asserts `enabled`.
- **Auto-select scenario is wrong.** Plan: newest item is auto-selected. Code + Jest: first *diffable* item; a timeline of only `rule_enable` / `rule_disable` leaves nothing selected (`changes_history.test.tsx`).
- **Timeline row UI doesn’t match the plan.** Plan wants changed-field name badges plus a “+N” overflow, and “each row should show … changed field names.” Shipped row shows date, user, a “N changes” count, and the action/revision/version badge. I couldn’t find a +N field-badge in the timeline components. Likely leftover from an older Figma.
- **Feature-off scenario is incomplete.** Disabled advanced setting also 403s restore (already tested in `change_tracking_disabled.ts`). The UI is double-gated by the experimental flag, which the plan never mentions.
- **Upgrade / forwards-backwards compat is out of scope with no reason.** History is a persisted data stream; snapshots are stored as unmapped JSON and never migrated (`get_rule_history.ts` comments exactly this risk). Worth either a deliberate “we accept silent drop of unhydratable snapshots” note or a small upgrade scenario.
- **API automation looks like net-new work, but most of it already exists** in `change_tracking.ts`, `change_tracking_disabled.ts`, and `restore_rule_from_changes_history.ts` (create/update/import/install/upgrade/duplicate/revert, pagination + `old_values` lookback, deleted-rule history, restore custom/prebuilt, 409 races, 404 missing changeId, write-privilege 403). Writing these again is wasted effort. The real hole is e2e/Scout — I found none.
- **Capture table skips alerting actions** that terminology and the UI already treat as first-class (`rule_enable`, `rule_disable`, `rule_snooze`, `rule_unsnooze`, `rule_update_api_key`, `rule_delete`). There’s no “enable/disable is captured and shows the right badge” scenario.
- **“Bulk edit” is underspecified.** Existing tests cover bulk *import / install / upgrade / duplicate* (`metadata.bulk_count`). I didn’t find a bulk-edit-tags/index-patterns/schedule capture test. If “bulk edit” means the Rule Management bulk actions, that’s still an open gap; if it means those other bulks, the wording will send people the wrong way.
- **Deleted-rule restore is API-only in the plan.** No UI path is specified (and Rule Details is gone after delete), so an e2e for “Restoring a deleted rule” would be inventing a surface.
- **Field-level RBAC scenario is accurate** — `validateFieldWritePermissions` treats a non-null `enabled` as gated, and restore always passes `enabled`. Good. Just don’t also claim restore writes the snapshot’s enabled value (it doesn’t).

### Open questions

- Should the auto-select and +N-badge scenarios be rewritten to the shipped UI (first diffable item; “N changes” count, no field badges), or is the UI still supposed to change before 9.5?
- Is restore of `enabled` intentionally excluded? If yes, the restore Gherkin should say “all fields except `enabled`” (and deleted recreate stays disabled).
- When you say “restore to a non-existent revision,” do you mean unknown `changeId` (that’s the 404 the API already has) or a `revision` number that isn’t in history (that’s not how the API works)?
- Are pre-tracking-rule cases still a 9.5 must-test, or only an upgrade-from-pre-9.5 concern? They’re a large chunk of the plan and I didn’t find existing tests for them.
- Should Feature availability also cover the experimental flag off, and restore-403 when the advanced setting is off?
- Do you want this plan to *index* existing integration tests (so “Implement tests” on the epic means e2e + the actual gaps), or is the intent to re-express everything from scratch?
- Forwards/backwards compat: accept silent empty/partial history after snapshot-schema drift, or add a scenario?

### Notes for your codebase map

- History writes live in Alerting change tracking; Security Solution adds solution actions (`rule_install`, `rule_upgrade`, `rule_duplicate`, `rule_import`, `rule_revert`, `rule_restore`) and the user-facing API/page.
- `old_values` is a computed RFC 7396 patch at read time, not stored. Pagination fetches `per_page + 1` so the last item on a page still diffs against the next-older revision.
- Diffable vs non-diffable is a UI list (`DIFFABLE_CHANGE_ACTIONS`). Restore is available on both.
- Restore concurrency: `revision` present ⇒ “I think the rule still exists at this revision”; `revision` omitted ⇒ “I think it’s deleted.” Wrong guess is 409. Same `rule_id` recreated after delete is also 409.
- Existing-rule restore does not flip `enabled`. Deleted-rule restore always comes back disabled.
- Two gates: experimental `ruleChangesHistoryEnabled` (UI) and advanced setting `securitySolution:enableRuleChangesHistory` (UI + API).
- Test-plan home: `docs/testing/test_plans/`, owned per subdomain in CODEOWNERS. This one sits with rule management.

### Follow-up Review Activities
