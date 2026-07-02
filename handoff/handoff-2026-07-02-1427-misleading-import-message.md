# Handoff — Misleading "change tracking activated" warning on first-time rule import (#273581)

## Context
Kibana Security Solution, detection rules **change history** UI. A first-time rule import (custom or prebuilt, into a space where the `rule_id` doesn't yet exist) shows a misleading yellow callout: *"Change tracking was activated while this rule already existed…"*. This session pinpointed the root cause and produced a tested fix. Next session: open a PR to fix and close [elastic/kibana#273581](https://github.com/elastic/kibana/issues/273581).

## Original dialog
- User: "ruleImport isn't classed as a 'diffable' change history action — after import I get the 'no prior state' warning. Pinpoint where this happens."
  - Insight: `ruleImport` **is** in every diffable/prior-state list. The warning fires from a *combination*, not a missing classification.
- User: "Why don't I get this for the first `ruleInstall`/`ruleDuplicate`? Those show a full green diff, no warning."
  - Insight: correct — those actions are **not** in `EDIT_ACTIONS_REQUIRING_PRIOR_STATE`, so a null `old_values` renders as a clean insertion. `ruleImport` **is** in that list, so the same null case fires the callout. Root cause confirmed: `rule_import` is one action covering both create and overwrite paths.
- User: "If we remove `ruleImport` from the array, consequences for imports that overwrite a rule *with* history?"
  - Insight: none — those have non-null `old_values`, so the array membership is irrelevant (gate already false). Only null-`old_values` items change.
- User: "New imports are the first item, timestamp == tracking start. Avenue?"
  - Insight: that signal == `old_values === null` and can't separate "new-rule import" from "overwrote a pre-tracking rule". The real discriminator is the snapshot's own `created_at` vs `updated_at`.
- User asked to see, then apply, the fix; iterated on form (inline vs top-level fn, comment removed).
- Late in session: GitHub issue #273581 surfaced with matching root-cause analysis and expected behavior.

## Conclusions
- **Symptom:** first-time import (custom + prebuilt, either space direction) shows the "activated while rule already existed" callout. Regular Create-rule flow is unaffected (uses `?? ruleCreate` fallback in `create_rule.ts`).
- **Root cause:** server tags first-time imports as `SecurityRuleChangeTrackingAction.ruleImport` even when semantically a creation (`import_rule.ts` create branch). Frontend `EDIT_ACTIONS_REQUIRING_PRIOR_STATE` treats all `ruleImport` as edits needing prior state; with `old_values === null` the callout fires.
- **Chosen fix (frontend, tested):** in `changes_diff.tsx`, additionally require `created_at !== updated_at` before treating a null-`old_values` item as "no diff available". A genuine creation has `created_at === updated_at` (alerting stamps both to the same instant on `create`; import strips `created_at` as a runtime field so file values can't leak in), so it renders as a clean insertion with no warning. An overwrite bumps `updated_at`, so its (accurate) warning is preserved.
- **Verified facts:**
  - `create_rule.ts` (alerting) sets `createdAt` and `updatedAt` to the same `createTime`.
  - `convert_rule_response_to_alerting_rule.ts` omits `created_at`/`updated_at` as `RuntimeFields`.
  - `old_values` is null iff no predecessor snapshot (`compute_old_values.ts` / `map_rule_history_item.ts` pairs each item with the next-older one in `get_history_for_rule.ts`).
- The `created_at !== updated_at` check correctly handles all three null cases: new-rule import (no warning), overwrite of pre-tracking rule (warning kept), overwrite of tracked rule (non-null `old_values`, unchanged).

## Current state
- Branch: `optimize-rule-bulk-import-create-path`. **Working tree clean** — session code edits were not committed; the patch file is the canonical, tested implementation.
- Fix captured at `.knowledge/patches/273581-misleading-import-message.patch` (single-file change to `changes_diff.tsx`).
- No tests added yet. No PR yet. Issue #273581 still open, assigned to `maximpn`.

## Next session focus
Put together the PR to fix #273581 and close it.
1. Apply `.knowledge/patches/273581-misleading-import-message.patch` to `changes_diff.tsx` (or re-implement equivalently; a top-level `hasNoDiff(item)` fn form was also trialled — either is fine).
2. Add Jest coverage in `changes_diff.test.tsx`: (a) `ruleImport` + null `old_values` + `created_at === updated_at` → **no** `ruleChangesHistoryNoDiffCallout`, renders insertion; (b) `ruleImport` + null `old_values` + `created_at !== updated_at` → callout **shown**; (c) regression: `ruleUpdate`/`ruleRevert` with old timestamps still show callout.
3. Run `node scripts/jest x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_diff/changes_diff.test.tsx`.
4. Open PR (target the issue's branch/version), link and close #273581.

## Suggested skills
- `/kbn-github` — create the PR, link/close the issue, CI status via `gh`.
- `/pr-review` — sanity-check the diff before pushing.

## Artifacts
- `.knowledge/patches/273581-misleading-import-message.patch` — final tested fix (source of truth).
- Issue: https://github.com/elastic/kibana/issues/273581 — bug report + matching root-cause analysis + repro table + expected behavior.
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_diff/changes_diff.tsx` — file to change (+ `changes_diff.test.tsx` for tests).
- Origin commit of the feature/classification: `fb7b562` (PR #269617, "[Security Solution] Add MVP UI for rule changes history").
- Server context (no change needed): `import_rule.ts` create branch tags `ruleImport`; `compute_old_values.ts`, `map_rule_history_item.ts`, `get_history_for_rule.ts`.
