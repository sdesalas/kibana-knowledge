# PR Review: #273433 — fix(security_solution): remove confusing data view skip message from bulk edit toast

**PR:** [elastic/kibana#273433](https://github.com/elastic/kibana/pull/273433)

**Scale:** Small PR — pure removal of one i18n string and the branch that appended it. No new behavior, no API surface change.

**Ownership:** Squarely owned by `@elastic/security-detection-rule-management` (labels `Team:Detection Rule Management`, `Feature:Rule Management`). In scope for your team to review.

---

## Context / Motivation

Resolves [#237635](https://github.com/elastic/kibana/issues/237635). When a user bulk-edits detection rules' index patterns and at least one selected rule is backed by a Kibana data view, those data-view rules get skipped (unless the user ticked "Apply changes to rules configured with data views" earlier). The success toast appended this line:

> "If you did not select to apply changes to rules using Kibana data views, those rules were not updated and will continue using data views."

The issue (a `good first issue`, `impact:low` bug) argues the message is useless either way:

- If the user knows about the checkbox → redundant.
- If they don't → confusing (double negative, and the toast only shows for a few seconds).

The issue offered three options: simplify, remove, or lengthen the toast. This PR takes **option 2 (remove)**. Stated intent matches the diff exactly.

## Summary

Drops the `RULES_BULK_EDIT_SUCCESS_DATA_VIEW_RULES_SKIPPED_DETAIL` i18n key and the conditional that appended it in `explainBulkEditSuccess`. The bulk-edit success toast now just shows the succeeded/skipped count (e.g. "1 rule was skipped."). Translation catalogs (de, fr, ja, zh), the jest test, and the Cypress spec/helper are all updated to drop the warning.

## Files touched

- **Source logic** — `bulk_actions/translations.ts` (removes the branch + unused `BulkActionEditTypeEnum` import) and `common/translations.ts` (removes the i18n key).
- **Test** — `bulk_actions/translations.test.ts` rewrites the four `explainBulkEditSuccess` cases to assert the plain description.
- **Cypress** — `rules_bulk_actions.ts` drops the `showDataViewsWarning` param from `waitForBulkEditActionToFinish`, and `bulk_edit_rules_data_view.cy.ts` removes the four call sites that passed it.
- **Translations** — `de-DE`, `fr-FR`, `ja-JP`, `zh-CN` catalogs drop the corresponding entry.

## Notes / minor observations

- `explainBulkEditSuccess(editPayload, summary)` now ignores `editPayload` entirely — it's dead in the function body. The signature is kept so the caller in `use_show_bulk_success_toast.ts` doesn't change. Won't trip eslint (the unused arg precedes the used `summary`, so `args: after-used` is happy). It's a fair judgment call to leave it; the caller passes `editPayload ?? []` and other branches may still need it. Slightly cleaner would be to drop the param and its caller arg, but that's optional and out of scope for a minimal fix.
- Verified no lingering references: grep for `RULES_BULK_EDIT_SUCCESS_DATA_VIEW_RULES_SKIPPED_DETAIL`, `successIndexEditToastDescription`, and the message text returns nothing across the repo. The removal is complete.

## Risks

Low. This is a UI string removal with matching test updates.

- The Cypress spec for data-view skip behavior still asserts the rule keeps its data view and the skipped count — only the warning-text assertion is gone. So the actual skip behavior is still covered; just the (now-deleted) message isn't.
- i18n: removing a key from `common/translations.ts` and from all four translation catalogs in the same PR is the correct hygiene — `i18n_check` should stay green. Worth a quick `node scripts/i18n_check` to be sure no other catalog or untranslated reference lingers.

## Open questions

- The issue listed three options and the team picked "remove". Was there explicit sign-off that *no* replacement message is needed? Users who skip data-view rules now get zero explanation for why the count was skipped — that's the intended trade-off per the issue, but worth confirming a designer/PM agreed rather than just simplifying.
- Backport labels target v9.5.0, v9.4.4, v9.3.7. The translation-catalog line numbers differ per branch; nothing structural, but the backport should apply cleanly since it's a single-line removal per catalog.

## Notes for your codebase map

- Bulk-action toast text is centralized: `bulk_actions/translations.ts` holds the `summarize*`/`explain*` helpers that map a `BulkActionType` + `BulkActionSummary` to a string; the actual i18n strings live one level up in `detection_engine/common/translations.ts`.
- `explainBulkEditSuccess` is the edit-specific branch (edit is excluded from `explainBulkSuccess`'s union), invoked from `use_show_bulk_success_toast.ts`.
- Data-view-backed rules are intentionally skipped during index-pattern bulk edits unless the user opts in via the "Apply changes to rules configured with data views" checkbox — that skip logic lives server-side; the client only reflected it via this (now removed) message.
- Convention: when removing an i18n string, delete the key in `common/translations.ts` **and** every `translations/translations/*.json` catalog in the same PR.

## Review activities

_(none yet)_
