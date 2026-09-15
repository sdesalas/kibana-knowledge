# Handoff — walk change-history files + PRD/RFC vs plan; add 5 comments to pending review 5181813426

### Context

Steven de Salas (`sdesalas`) is reviewing Maxim’s docs-only PR [elastic/kibana#274337](https://github.com/elastic/kibana/pull/274337) (test plan for rule changes history). 11 draft comments already sit on **PENDING** review **`5181813426`**. This session built the change-history PR/commit inventory + affected-file list. Next agent: walk shipped files + PRD/RFC/one-pager against the plan, pick **the 5 most important missing comments**, each with a why, then **add them to that pending review**. Repo: `/Users/sdesalas/Code/sdesalas/kibana-3rd` (not Maxim’s branch). 9.5 has GA’d — **shipped code is the source of truth**, not old Figma / not PRD “NEXT”.

---

### Original dialog

Prior: [handoff-2026-09-11-1823-pr-274337-comment-triage.md](./handoff-2026-09-11-1823-pr-274337-comment-triage.md) (triage), [handoff-2026-09-11-1949-change-history-missed-tests.md](./handoff-2026-09-11-1949-change-history-missed-tests.md) (interview + pending review), chat [PR 274337 review](8de157ac-5d47-4011-801c-5136a13933b5).

This session:

- **“Create a list of all commits/PRs related to change history… looking through related implementation files.”** then **“You may also look through every PR created by maxim and reviewed by me between 1st of May and 15th July.”**
  - *Insight:* inventory = file `git log` + `gh search prs --author maximpn --reviewed-by sdesalas`. Do not include Maxim×Steven PRs that are unrelated (prebuilt-rules perf). First package PR was missing from path-log because of a later rename.

- **“Its missing the first PR I made… the one that created the kbn-change-history component”**
  - *Insight:* that is [#256385](https://github.com/elastic/kibana/pull/256385) (`7403031042d`, 2026-03-20). `#261981` is alerting wiring on top. `#263585` as `--diff-filter=A` first-hit is a git artifact.

- **“The section Maxim PRs Steven reviewed (that are not related to change history) is not needed.”**
  - *Insight:* keep the listing feature-only.

- **“Move the file to ../reports, call it pr-listing-change-history.md”** then **“put a full list of affected files at the end… renamed → current main path; deleted → ignore”** then **“Rename change-history-pr-listing-affected-files.md”**
  - *Insight:* **canonical listing** is `kibana-knowledge/reports/change-history-pr-listing-affected-files.md` (405 lines: PRs + 279 current files). Stale copies may still sit in the editor: `reports/pr-listing-change-history.md` (102 lines, no file list), `reviews/pr-274337-commits.md`. Prefer the 405-line file.

- **“/handoff , next agent is going to open this file and then do some deep research against the current test plan… walk through all the change history related files… also look at PRD, RFC and one pager and come up with a list of 5 things to comment on. The most important ones. Make sure each of those things explain why we need to make that comment. Then add them to the PR review in progress”** + attached review / one-pager / PRD / RFC / plan.
  - *Insight:* **not** a one-at-a-time interview this time. Deliver **exactly 5** new comments, each with why, then **post them onto the existing pending review**. Same bar as before: missing/wrong **test-plan scenario** (or wrong Gherkin), not nits, not “FTR already exists”. Do **not** submit the review.

Voice when posting: British English, technical, no humour, no AI-speak. `/voice`. kbn-github JSON `--input`, **no `event` on create**.

---

### Conclusions

- **PR** [elastic/kibana#274337](https://github.com/elastic/kibana/pull/274337) @maximpn. Head **`002a4b97f87a320805579df7f7c9ad14090a049c`**. One file: `x-pack/solutions/security/plugins/security_solution/docs/testing/test_plans/detection_response/rule_management/rule_changes_history.md` (752 lines). Local file = GitHub RIGHT line numbers. GitHub raw/WebFetch strips HTML comments and shifts lines — **do not use that**.
- **Pending review:** id **`5181813426`**, state `PENDING`, **11** draft comments. URL: https://github.com/elastic/kibana/pull/274337#pullrequestreview-5181813426
- **Recreate source:** `/Users/sdesalas/Code/sdesalas/kibana-3rd/.agents/tmp/pr-274337-review.json` (summary + 11 comments, no `event`).
- **Listing:** `/Users/sdesalas/Code/sdesalas/kibana-knowledge/reports/change-history-pr-listing-affected-files.md` — walk table (feature PRs from `#256385` through `#277380`), platform `@kbn/change-history` PRs, 279 current `main` paths.
- **Product calls already made (do not re-litigate):** `enabled` = state not content; restore **should not** require enable/disable privilege (commented; `restore_rule_state.ts` still passes `enabled` today); rewrite stale UI scenarios, don’t delete them; test-plan comments are not “point at existing FTR”.
- **Already posted (do not duplicate):** L580 unreadable snapshot; L290 “N changes”; L293–307 first *diffable* auto-select; L348–359 rewrite `+N`; L383 enabled unchanged on restore; L453/L459 `changeId` 404; L473 deleted recreate disabled; L531 typo; L532 feature-off 403s restore; L722–737 drop enable/disable privilege from restore RBAC.
- **Interview drops (do not resurrect unless new evidence from PRD/RFC/files):** L108 terminology; L187/L261 “bulk edit” wording; L398 duplicate enabled; L156/L378 “FTR already exists”; L179 alerting actions missing from capture table; L234 pre-tracking e2e count.
- **Known gaps not yet commented** (candidates for the 5 — verify, don’t copy blindly): experimental flag `ruleChangesHistoryEnabled` never in Feature availability; ESS vs Serverless unstated (`@ess @skipInServerless` on existing FTR); license unstated (epic #12367 Basic vs restore epic #12432 Enterprise); space-scoped history has no integration test; capture table still skips `rule_enable`/`rule_disable`/`rule_snooze`/`rule_unsnooze`/`rule_update_api_key`/`rule_delete` (Steven *dropped* a capture-table comment — only re-open if PRD/RFC makes it a must-test); Rule Management bulk-edit (tags/schedule/index patterns) vs bulk import/install/upgrade; no Scout/Cypress for History page (plan already asks e2e — commenting “please add e2e” is empty unless a *specific* shipped behaviour has no scenario); pre-tracking rules largely untested in FTR; upgrade/compat out of scope with no reason (unreadable-snapshot already commented).

**How to add comments to PENDING review `5181813426` (mandatory):**

GitHub allows **one PENDING review per user per PR**. Pending comments are **not editable via API**. `POST .../pulls/274337/comments` with `pull_request_review_id` **will not** attach. File-level comments (`subject_type=file`) are immediately public — never for drafts.

To add the 5:

1. Read back live drafts so you don’t clobber UI edits:
   ```
   GH_PAGER=cat gh api repos/elastic/kibana/pulls/274337/reviews/5181813426
   GH_PAGER=cat gh api repos/elastic/kibana/pulls/274337/reviews/5181813426/comments
   ```
   Compare bodies to `.agents/tmp/pr-274337-review.json`. If Steven edited in the GitHub UI, **use the live bodies**, not the file.
2. Show Steven the 5 (local `rule_changes_history.md:L#`, GitHub L# on `002a4b97` RIGHT, why, `suggestion`/`diff`) **in chat**, then add.
3. Announce: delete `5181813426`, recreate one pending review with **old 11 (or live bodies) + 5 new**, same summary, **no `event`**.
4. Write `/Users/sdesalas/Code/sdesalas/kibana-3rd/.agents/tmp/pr-274337-review.json` (overwrite after backing up if live ≠ file). Schema:
   ```json
   {
     "commit_id": "002a4b97f87a320805579df7f7c9ad14090a049c",
     "body": "<existing approved summary — keep unless Steven changed it>",
     "comments": [ { "path": "x-pack/solutions/security/plugins/security_solution/docs/testing/test_plans/detection_response/rule_management/rule_changes_history.md", "line": N, "side": "RIGHT", "body": "..." } ]
   }
   ```
   Multi-line: `start_line` + `start_side` + `line` + `side`. Path is the plan file only. Verify JSON has **no top-level `event`**.
5. Delete then create:
   ```
   GH_PAGER=cat gh api -X DELETE repos/elastic/kibana/pulls/274337/reviews/5181813426
   GH_PAGER=cat gh api repos/elastic/kibana/pulls/274337/reviews -X POST --input /Users/sdesalas/Code/sdesalas/kibana-3rd/.agents/tmp/pr-274337-review.json
   ```
   `--input` must be an absolute path with no `$VAR` / `$(...)` / `~`. Hook strips stray `event`.
6. Verify: new review `PENDING`; comment count = 16; `GET .../pulls/274337/comments` still empty (drafts stay invisible).
7. **Do not submit** (`.../reviews/{id}/events`). Ask Steven first.
8. `/voice` on comment bodies only when writing the JSON. kbn-github: `/Users/sdesalas/Code/sdesalas/kibana-3rd/.agents/skills/kbn-github/references/review.md`.

---

### Current state

**Done**
- Inventory + 279-file list in `change-history-pr-listing-affected-files.md`.
- Pending review `5181813426` with 11 drafts. Not submitted.
- Interview decisions in `pr-review-274337.md` activity 2 and `pr-274337-comments.md`.

**In progress**
- Nothing. Next agent starts the walk.

**Blocked**
- Submitting the review. Ask.
- Patching comments onto `5181813426` without delete+recreate.

**Ignore:** unrelated dirty tree in `kibana-3rd` (`translations.ts` etc.).

---

### Next session focus

1. **Do not re-review the PR from scratch.** Load this handoff + review doc + comments file + listing.
2. **Open the listing first:** `/Users/sdesalas/Code/sdesalas/kibana-knowledge/reports/change-history-pr-listing-affected-files.md`. Use the walk-table PRs and the affected-file list (skip “Other” incidental: `yarn.lock`, CODEOWNERS, workflow tests, alerting_v2) as the file set.
3. **Read the plan** at the real path (not `.agents/tmp/pr-274337.md`):  
   `x-pack/solutions/security/plugins/security_solution/docs/testing/test_plans/detection_response/rule_management/rule_changes_history.md`
4. **Read product docs** (local copies; treat as intent, not as “must match every FR if 9.5 didn’t ship it”):
   - `kibana-knowledge/reviews/docs-274337/doc-onepager.md`
   - `kibana-knowledge/reviews/docs-274337/doc-prd.md`
   - `kibana-knowledge/reviews/docs-274337/doc-rfc.md`
   - Also useful: `docs-274337/synthesis.md`, `insights-mvp-ui.md`, per-PR notes (`pr-256385.md`, `pr-269617.md`, …). **`synthesis.md` is stale in places** (says restore UI didn’t ship / FR-6 is NEXT). Restore *did* ship (`#274605`). Verify against current code.
5. **Walk shipped files** for behaviours the plan never names. Highest-yield from the listing’s suggested order: alerting actions (`#267350`/`#270446`/`#272552`/`#271908`); shipped UI (`#269617`); restore identity/409 (`#274605`/`#276882`); duplicate/import (`#275559`/`#275962`); flags (`#276307`/`#276585`/`#278052`); serverless usernames (`#278353`); snapshot/hashing (`#273561`/`#274835`).
6. **Produce exactly 5 comments.** For each: local `rule_changes_history.md:L#` link, local code/commit/PRD-RFC evidence, GitHub L# on `002a4b97` RIGHT, **why this comment is needed** (what a tester or implementer would get wrong without it), `suggestion` or `diff`. Pick the five that matter most for plan fidelity / missing must-test scenarios. Skip nits, skip “FTR already exists”, skip anything already in the 11, skip interview drops unless the docs make them newly important.
7. **Add the 5** via delete+recreate as above. Present them in chat with why, then post. Do not submit.

---

### Suggested skills

- `/kbn-github` — delete+recreate pending review; read `references/review.md`; never put `event` on create.
- `/voice` — rewrite the 5 comment bodies in Steven’s voice only when writing the JSON.
- `/pr-review` — only if you update `pr-review-274337.md`. Activity 2 is **his** decision log; append the 5 there after posting, don’t dump investigation notes.

---

### Artifacts

- **Start here:** `/Users/sdesalas/Code/sdesalas/kibana-knowledge/reports/change-history-pr-listing-affected-files.md`
- Prior handoffs: `handoff-2026-09-11-1823-pr-274337-comment-triage.md`, `handoff-2026-09-11-1949-change-history-missed-tests.md`
- Review: `/Users/sdesalas/Code/sdesalas/kibana-knowledge/reviews/pr-review-274337.md`
- Interview log: `/Users/sdesalas/Code/sdesalas/kibana-knowledge/reviews/pr-274337-comments.md`
- Product docs: `/Users/sdesalas/Code/sdesalas/kibana-knowledge/reviews/docs-274337/doc-onepager.md`, `doc-prd.md`, `doc-rfc.md` (+ `synthesis.md`, `insights-mvp-ui.md`)
- Plan: `/Users/sdesalas/Code/sdesalas/kibana-3rd/x-pack/solutions/security/plugins/security_solution/docs/testing/test_plans/detection_response/rule_management/rule_changes_history.md`
- Plan on GitHub: https://github.com/elastic/kibana/blob/002a4b97f87a320805579df7f7c9ad14090a049c/x-pack/solutions/security/plugins/security_solution/docs/testing/test_plans/detection_response/rule_management/rule_changes_history.md
- Posted JSON: `/Users/sdesalas/Code/sdesalas/kibana-3rd/.agents/tmp/pr-274337-review.json`
- Pending review: https://github.com/elastic/kibana/pull/274337#pullrequestreview-5181813426 (id `5181813426`)
- PR: https://github.com/elastic/kibana/pull/274337
- Epics: https://github.com/elastic/security-team/issues/12367 (history), https://github.com/elastic/security-team/issues/12432 (restore)
- Related, out of scope unless the walk says otherwise: https://github.com/elastic/kibana/pull/278197 (remove experimental FF)
- kbn-github review rules: `/Users/sdesalas/Code/sdesalas/kibana-3rd/.agents/skills/kbn-github/references/review.md`

**Approved review summary (keep on recreate unless live review body differs):**

> Hi @maximpn.
>
> A few fidelity fixes against what shipped in 9.5. The main ones are UI/Gherkin that still describe the older design (field-name badges, newest-row auto-select), restore identity (`changeId` vs revision), and `enabled` as state rather than rule content.
>
> One of the comments is an intended-contract change, not a fidelity fix: restore should not require the enable/disable privilege, even though the current API still checks it.
