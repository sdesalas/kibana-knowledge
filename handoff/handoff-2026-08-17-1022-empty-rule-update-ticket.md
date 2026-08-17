# Handoff — empty rule update ticket search

## Context

Steven (DEX) asked to find-or-create a GitHub ticket for: empty detection-rule updates creating blank change-history entries (`#change-history` `#bulk-primitives`, added 2026-08-17). @banderror confirmed it is a bug and asked if a ticket exists.

 The `#change-history` `#bulk-primitives` tags are context - what triggered the search for a bug, not search criteria (the nature of the bug itself).

 This session locked search criteria, repos, and match buckets. **No GitHub searches were executed and no ticket was created.** Workspace: `/Users/sdesalas/Code/sdesalas/kibana-9.5`.

## Original dialog

**User (job):** Find or create ticket: empty rule updates creating blank change history entries. @banderror confirmed bug + asked if ticket exists. Search kibana + security-team; create if missing. Context: [DEX thread](https://elastic.slack.com/archives/C09S1NKF8HX/p1786733442774769?thread_ts=1781628763.734789&cid=C09S1NKF8HX) (`C09S1NKF8HX`, parent `1781628763.734789`). Walk through searches before running so they can correct.

**Agent (first plan):** Lead with `"change history"` + blank/empty; repos `elastic/kibana` + `elastic/security-team`; match = no-op save writing empty change-history rows.

**User:** Searches too narrow. Better angle: `"empty rules update"` / `"empty rule update"`. Change history only went live ~two weeks ago (~2026-08-03), so few tickets will use that name. Nail search criteria first, then repos, then match rules.

**User:** Lock primary + secondary = 8 criteria. Give the list.

**User:** Repos are `elastic/kibana`, `elastic/security-team`, `elastic/sdh-security-team`. Restate match summary.

**Agent (match summary they asked to confirm):** Close = no-op/empty detection-rule update still producing a side effect (esp. blank change-history row). Maybe = audit log, execution history, prebuilt upgrade diffs. Not = original change-history feature tickets / generic bulk-edit.

**User (go-ahead, with refinements):** Until recently the noticed symptoms were **updated date changes** and **API key rotation**, not change history — but include those anyway. Search **open and closed**. Return **three lists: close matches, weak matches, unrelated matches**. Tickets not focused on rules being updated when there is no change → weak or unrelated.

**User:** `/handoff` (before searches ran). Agent had only fetched `kbn-github` + Slack `slack_read_thread` schema; no `gh search`, no Slack read.

## Conclusions

- **Bug (product):** No-op / empty detection-rule update (save or bulk with no field changes) still has side effects.
- **Current symptom (post change-history GA, ~last 2 weeks):** blank change-history entries.
- **Older symptoms (include in match logic):** `updated_at` / updated date changes; detection-rule API key rotation on empty update.
- **Search must not lead with `"change history"`.** Too new; will mostly hit the feature tickets.
- **Locked 8 queries** (GitHub issue search; quoted = phrase, unquoted = AND):
  1. `"empty rule update"`
  2. `"empty rules update"`
  3. `"empty update" rule`
  4. `empty update rules`
  5. `"no changes" rule update`
  6. `"no-op" rule` **and** `noop "rule update"` (two runs)
  7. `"without changes" rule`
  8. `"unchanged" "rule update"`
- **Extra queries (user-added angle, not in the 8 but required):** API-key rotate/rotation on rule update; updated date / `updated_at` changing on no-op. Keep them as additional passes, not replacements. Suggested:
  - `"api key" rule update`
  - `"api key" rotat` rule (or separate `rotated` / `rotation`)
  - `"updated date" rule` / `updated_at "rule update"` / `"no changes" updated`
- **Do not search** unless results are thin: `"rule changelog"`, `siem-rule-changelog`, `"bulk primitives"`, bare `"bulk update"` / `"bulk edit"` without empty/no-op.
- **Repos (issues, `--state all`):** `elastic/kibana`, `elastic/security-team`, `elastic/sdh-security-team`. Private repos → `gh` with user auth (`required_permissions: ["all"]`). `GH_PAGER=cat`. Prefer `gh search issues --repo A --repo B --repo C --state all --json number,title,url,state,repository,createdAt,updatedAt`.
- **Classification (user-specified):**
  - **Close:** focused on rules being updated when there is no change, including side effects: blank change history, updated date bump, API key rotation.
  - **Weak:** related area (rules, bulk, change history, API keys) but **not focused** on no-op/empty updates.
  - **Unrelated:** keyword noise; original change-history **feature** tickets; generic bulk-edit; audit log; rule **execution** history; prebuilt-rule upgrade diffs; empty updates in a different product.
- **Do not create a ticket until lists are shown and user confirms missing.** Original job said create if missing; `kbn-github` still requires explicit issue-create approval. Draft Kibana issue title/body only after empty close-match set.
- **Slack:** read the DEX thread for @banderror’s wording + any pasted GitHub URLs. Workspace rule: announce channel/scope/query/why in chat **before** any Slack MCP call. Thread read is context, not a ticket search. Do not Slack-search unless GitHub is empty and the thread has no link.
- **Match bar is strict:** “tickets that are not focused on rules being updated when there is no change should be weak or unrelated.”

## Current state

- **Done:** search criteria, repo list, classification buckets, extra symptom angle (updated date + API key).
- **Not done:** GitHub searches; Slack thread read; close/weak/unrelated lists; ticket create.
- **Blocked on:** next agent running the searches and presenting the three lists.
- **Git:** no branch, no uncommitted work for this task. Open file in IDE (`failed-test-investigator.lock.yml`) is unrelated.

## Next session focus

1. **Announce then read** Slack thread `C09S1NKF8HX` / `1781628763.734789` (`slack_read_thread`) for existing ticket URLs and @banderror’s terms. Use those terms as extra queries if they differ from the 8.
2. Run the 8 queries (+ query 6 as two searches) across all three repos, open+closed. Add API-key rotation and updated-date passes.
3. Deduplicate by URL. Read bodies of plausible hits (`gh issue view -R <repo> <n>`).
4. Return **three lists only**: close / weak / unrelated. Each item: repo, number, title, state, URL, one-line why it sits in that bucket.
5. If **no close match:** stop and propose a Kibana issue title/body (do not create until Steven says so). Point at the DEX thread. Labels/tags from the job: change-history, bulk-primitives.
6. If a close match exists: report it as the ticket; do not file a duplicate.

Suggested `gh` shape:

```bash
GH_PAGER=cat gh search issues \
  --repo elastic/kibana \
  --repo elastic/security-team \
  --repo elastic/sdh-security-team \
  --state all --limit 50 \
  --json number,title,url,state,repository,createdAt,updatedAt \
  '"empty rule update"'
```

## Suggested skills

- `/kbn-github` — `gh search issues` / `gh issue view`; do not `gh issue create` without explicit approval.
- Slack MCP + `slack-search` skill — read the DEX thread first; announce intent before any Slack tool.
- `/detection-alerting-architecture` — only if a close match’s technical claims need checking against rule-update / changelog / API-key rotation code.
- `/voice` — only if Steven asks to draft the GitHub issue **as him** or post in Slack.

## Artifacts

- Job source: user checklist item 2026-08-17, `#change-history` `#bulk-primitives`.
- DEX thread: https://elastic.slack.com/archives/C09S1NKF8HX/p1786733442774769?thread_ts=1781628763.734789&cid=C09S1NKF8HX
- This session produced no search output, issue, or PR.
