# Handoff — PR 274337 missed-test walk (from change-history commits)

### Context

Steven de Salas (`sdesalas`) finished an inline-comment interview on Maxim’s docs-only PR [elastic/kibana#274337](https://github.com/elastic/kibana/pull/274337) (`[Security Solution] Add test plan for rule changes history`). Kept comments are in a **PENDING** GitHub review. Next session: (1) see if extra comments can be added to **that same review**, (2) **start by listing every change-history-related commit** in related files, (3) walk those commits for tests/behaviours the plan missed. 9.5 has GA’d — shipped code is the source of truth. Repo: `/Users/sdesalas/Code/sdesalas/kibana-3rd` (checkout is **not** Maxim’s branch).

---

### Original dialog

Prior session (triage setup): [handoff-2026-09-11-1823-pr-274337-comment-triage.md](./handoff-2026-09-11-1823-pr-274337-comment-triage.md) and chat [PR 274337 review](8de157ac-5d47-4011-801c-5136a13933b5).

This session (interview + post):

- **“Can you interview me to see what comments we make?”** then **“The PR review comment is meant to be in rule_changes_history.md, where is the link to that?”**
  - *Insight:* local link must be the real plan file, not `.agents/tmp/pr-274337.md`. Path: `x-pack/solutions/security/plugins/security_solution/docs/testing/test_plans/detection_response/rule_management/rule_changes_history.md`.

- **“One question, can you post via start a review”** then **“What will be the main message”** then **“With summary. Looks good, I can amend after if I'm not happy.”**
  - *Insight:* one pending review, all line comments in `comments[]`, **no `event`**. Summary approved (see Artifacts). He amends in the GitHub UI.

- **“Great work. /handoff … add extra comments to that review. I want to start with making a list of every single change-history related commit in related files, then walking those commits to see if we missed a test that should have been included.”**
  - *Insight:* next work is **commit archaeology → missed plan scenarios**, then **try to attach extra comments to the existing pending review**. Do not invent nits. Same bar as this interview.

Voice when posting: British English, technical, no humour, no AI-speak. `/voice`. kbn-github JSON `--input`, **no `event` on create**.

---

### Conclusions

- **PR** [elastic/kibana#274337](https://github.com/elastic/kibana/pull/274337) @maximpn. Head **`002a4b97f87a320805579df7f7c9ad14090a049c`**. Single new file: `…/docs/testing/test_plans/detection_response/rule_management/rule_changes_history.md` (752 lines locally).
- **Pending review posted:** id **`5181813426`**, state `PENDING`, **11** draft comments. URL: https://github.com/elastic/kibana/pull/274337#pullrequestreview-5181813426
- **Payload (recreate source):** `/Users/sdesalas/Code/sdesalas/kibana-3rd/.agents/tmp/pr-274337-review.json`
- **Product calls Steven made:** `enabled` = state not content; restore **should not** require enable/disable privilege (plan + intended contract; `restore_rule_state.ts:63` still passes `enabled` today); deleting a stale UI scenario is lazy — rewrite it; test-plan comments are not “point at existing FTR”.
- **Adding comments to a PENDING review (kbn-github):** GitHub allows **one PENDING review per user per PR**. Pending comments are **not editable via API**. `POST .../pulls/{n}/comments` with `pull_request_review_id` **will not** attach to the pending review. To change bodies/anchors or add comments: **delete pending review `5181813426` and recreate** the full `comments` array (old 11 + new). Do not submit unless Steven asks. File-level comments (`subject_type=file`) are immediately public — don’t use those for drafts.
- Local plan for line numbers = repo file (same as GitHub RIGHT side of `002a4b97`). GitHub raw/WebFetch strips HTML comments and shifts lines — don’t use that.

**Related implementation files already used as evidence (start the commit list here, then expand):**

- Alerting history read: `x-pack/platform/plugins/shared/alerting/server/rules_client/methods/get_rule_history.ts`
- Alerting bulk edit tracking: `x-pack/platform/plugins/shared/alerting/server/rules_client/common/bulk_edit/bulk_edit_rules.ts`, `…/bulk_edit_rules_occ.ts`
- Restore: `…/restore_rule_from_history/restore_rule_state.ts`, `restore_deleted_rule.ts`
- Field RBAC: `…/detection_rules_client/utils.ts` (`validateFieldWritePermissions`)
- Bulk edit wiring: `…/rule_management/logic/bulk_actions/bulk_edit_rules.ts`, `…/api/rules/bulk_actions/route.ts`
- UI: `…/changes_history/use_change_history_auto_selection.ts`, `…/changes_history_timeline/change_history_item.tsx`, `constants.ts`, `rule_change_action_badge.tsx`, `translations.ts`
- Existing FTR (do **not** comment “already covered” unless Steven asks): `change_tracking.ts`, `change_tracking_disabled.ts`, `restore_rule_from_changes_history.ts`
- Jest: `changes_history.test.tsx`, `changes_diff.test.tsx`

---

### Current state

**Done**
- Interview of 16 drafts. Decisions in `pr-review-274337.md` activity 2 and `pr-274337-comments.md`.
- Pending review `5181813426` created (summary + 11 inline comments). Not submitted.

**In progress**
- Nothing. Next agent starts the commit inventory.

**Blocked**
- Submitting the review (COMMENT / REQUEST_CHANGES). Ask Steven first.
- API-adding comments onto `5181813426` without recreate. Confirm the constraint, then delete+recreate if new comments are approved.

**Files**
- Review doc: `/Users/sdesalas/Code/sdesalas/kibana-knowledge/reviews/pr-review-274337.md` (symlink of `kibana-3rd/.knowledge/reviews/`)
- Working comments: `/Users/sdesalas/Code/sdesalas/kibana-knowledge/reviews/pr-274337-comments.md`
- Posted payload: `/Users/sdesalas/Code/sdesalas/kibana-3rd/.agents/tmp/pr-274337-review.json`
- Plan: `/Users/sdesalas/Code/sdesalas/kibana-3rd/x-pack/solutions/security/plugins/security_solution/docs/testing/test_plans/detection_response/rule_management/rule_changes_history.md`
- Unrelated dirty tree in `kibana-3rd` — **ignore**.

---

### Next session focus

1. **Do not re-review the PR from scratch.** Load the review doc + comments file + this handoff.
2. **Inventory first (Steven’s order).** List every change-history-related commit that touched the related files (Alerting change-tracking + Security Solution history/restore/UI + existing tests). Prefer `git log --follow --oneline -- <paths>` scoped to those trees; include merge/feature PRs if that’s how the work landed. Produce a dated commit list the user can scan.
3. **Walk the commits** against the plan. Ask: is there a shipped behaviour with no scenario? Candidate gaps already known but **not** commented: no Scout/Cypress for History page (plan already asks e2e); pre-tracking rules largely untested in FTR; experimental flag `ruleChangesHistoryEnabled` never mentioned; ESS vs Serverless unstated; license unstated; space-scoped history has no integration test. Only propose a new comment if it is a **missing test-plan scenario** (or a wrong Gherkin), not “FTR already exists” and not nits.
4. **Interview new comments one at a time** — same format as this session: local `rule_changes_history.md:L#` link, local code/commit evidence, GitHub L# on `002a4b97` RIGHT, why, `suggestion` or `diff`, `keep` / `amend` / `drop`. Wait.
5. **If any are kept, try to add them to review `5181813426`.** Expect fail → delete pending review → recreate JSON with original 11 + new (no `event`). Show Steven the recreate plan before deleting. He may have already edited drafts in the UI — **read back pending comment bodies before delete** so you don’t clobber his edits.
6. **Do not submit** the review unless he asks.

---

### Suggested skills

- `/kbn-github` — pending review recreate; read `references/review.md`; never put `event` on create.
- `/voice` — rewrite any new comment in Steven’s voice only when posting.
- `/pr-review` — only if you must update the review doc. Activity 2 is **his** decision log; don’t dump investigation notes there. Put the commit inventory in a **new** file next to the review (e.g. `kibana-knowledge/reviews/pr-274337-commits.md`).

---

### Artifacts

- Prior handoff: `/Users/sdesalas/Code/sdesalas/kibana-knowledge/handoff/handoff-2026-09-11-1823-pr-274337-comment-triage.md`
- Review: `/Users/sdesalas/Code/sdesalas/kibana-knowledge/reviews/pr-review-274337.md`
- Triage file: `/Users/sdesalas/Code/sdesalas/kibana-knowledge/reviews/pr-274337-comments.md`
- Posted JSON: `/Users/sdesalas/Code/sdesalas/kibana-3rd/.agents/tmp/pr-274337-review.json`
- Pending review: https://github.com/elastic/kibana/pull/274337#pullrequestreview-5181813426 (id `5181813426`)
- PR: https://github.com/elastic/kibana/pull/274337 (head `002a4b97f87a320805579df7f7c9ad14090a049c`)
- Plan on GitHub: https://github.com/elastic/kibana/blob/002a4b97f87a320805579df7f7c9ad14090a049c/x-pack/solutions/security/plugins/security_solution/docs/testing/test_plans/detection_response/rule_management/rule_changes_history.md
- Epics: https://github.com/elastic/security-team/issues/12367 , https://github.com/elastic/security-team/issues/12432
- Related (out of scope for comments unless commit walk says otherwise): https://github.com/elastic/kibana/pull/278197 (removes experimental FF)
- kbn-github review rules: `/Users/sdesalas/Code/sdesalas/kibana-3rd/.agents/skills/kbn-github/references/review.md`

**Approved review summary (already on the pending review):**

> Hi @maximpn.
>
> A few fidelity fixes against what shipped in 9.5. The main ones are UI/Gherkin that still describe the older design (field-name badges, newest-row auto-select), restore identity (`changeId` vs revision), and `enabled` as state rather than rule content.
>
> One of the comments is an intended-contract change, not a fidelity fix: restore should not require the enable/disable privilege, even though the current API still checks it.
