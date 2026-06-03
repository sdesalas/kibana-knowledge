---
name: weekly-update
description: Generate a draft for the weekly status update form. Gathers data from GitHub (PRs merged/opened/reviewed, issues created), Google Calendar (meetings attended and upcoming), and Obsidian weekly notes, then synthesizes into WORK DONE / NEXT UP / BLOCKERS / ANYTHING ELSE format. Use when the user asks to "generate status update", "Monday form", "fill out the status update", "weekly update", or "status update draft".
allowed-tools: Bash, Read, Write, Glob, mcp__google-calendar__*
---

# Weekly Status Update Generator

Generates a draft weekly status update by gathering GitHub activity, Google Calendar meetings, and Obsidian daily note context, then synthesizing into the 4-section form format.

## Prerequisites

- `gh` CLI installed and authenticated
- Obsidian daily notes at the configured path
- Google Calendar MCP server configured in Cursor (e.g. [`@cocal/google-calendar-mcp`](https://github.com/nspady/google-calendar-mcp)) and authenticated. The skill expects MCP tools matching the names below to be available:
  - `list-calendars`
  - `list-events` (params: `calendarId`, `timeMin`, `timeMax`)
  - `search-events` (params: `calendarId`, `query`, `timeMin`, `timeMax`) — optional
  - If your installed server exposes different tool names, map them mentally to the equivalent operation; the rest of the workflow is unchanged.

## Configuration

```yaml
github:
  username: sdesalas
  repos:
    - elastic/kibana
    - elastic/security-team
    - elastic/docs-content
    - elastic/sdh-security-team

obsidian:
  vault_root: "/Users/sdesalas/obsidian/weekly-update"
  daily_notes_dir: "/Users/sdesalas/obsidian/weekly-update"

calendar:
  # MCP calendar IDs to pull from. "primary" is the user's main calendar.
  # Add additional shared/team calendar IDs (the email-style IDs returned by
  # `list-calendars`) if relevant for status reporting.
  calendar_ids:
    - primary
  timezone: "Europe/Madrid"
  # Filter out noisy events from the raw output and the synthesis.
  exclude_patterns:
    - "lunch"
    - "block"
    - "focus time"
    - "ooo"
    - "out of office"
    - "wfh"
  # Treat events as "skipped" (don't count as attended) when the user's
  # response status is one of these.
  skip_response_statuses:
    - declined
    - needsAction

output:
  dir: "/Users/sdesalas/obsidian/weekly-update/Status-notes"
```

## Execution Workflow

### Step 1: Compute Date Range

Calculate the date range for the status update:
- **Start**: Previous Monday (if today is Monday, go back 7 days)
- **End**: Sunday after "Start" (yesterday if today is Monday)
- Format: `YYYY-MM-DD`

### Step 2: Gather GitHub Data

Run these commands across ALL repos listed in configuration. Use the Bash tool to run them in parallel where possible. Replace `START_DATE` and `END_DATE` with computed values.

**PRs authored and merged:**
```bash
gh pr list --author sdesalas --state merged --search "merged:>=START_DATE merged:<=END_DATE" --repo REPO --json title,url,mergedAt --limit 50
```

**PRs authored and opened (not merged):**
```bash
gh pr list --author sdesalas --state all --search "created:>=START_DATE created:<=END_DATE -is:merged" --repo REPO --json title,url,createdAt,isDraft,state --limit 50
```

**PRs reviewed:**
Note: GitHub's `updated:` filter reflects the PR's last-updated timestamp, which can move past END_DATE due to later activity (new commits, bot comments, other reviews). To avoid missing PRs reviewed during the week, extend the upper bound by a few days.
```bash
gh api search/issues -X GET -f q="type:pr reviewed-by:sdesalas updated:>=START_DATE updated:<=END_DATE+3d repo:REPO" --jq '.items[] | {title, html_url}'
```

**Issues created:**
```bash
gh issue list --author sdesalas --search "created:>=START_DATE created:<=END_DATE" --repo REPO --json title,url --limit 50
```

**Issues commented on (to catch discussion contributions):**
```bash
gh api search/issues -X GET -f q="commenter:sdesalas updated:>=START_DATE updated:<=END_DATE repo:REPO -author:sdesalas" --jq '.items[] | {title, html_url}'
```

### Step 3: Gather Google Calendar Data (via MCP)

Use the Google Calendar MCP tools to pull both **past meetings** (the week being reported) and **upcoming meetings** (the next 7 days, used to inform NEXT UP).

For each `calendar_id` in `calendar.calendar_ids`, call the MCP `list-events` tool twice:

1. **Past meetings (this week):**
   - `calendarId`: the configured ID
   - `timeMin`: `START_DATE` at `00:00:00` in `calendar.timezone` (RFC3339 with offset, e.g. `2026-04-13T00:00:00+02:00`)
   - `timeMax`: `END_DATE` at `23:59:59` in `calendar.timezone`

2. **Upcoming meetings (next 7 days, for NEXT UP):**
   - `calendarId`: the configured ID
   - `timeMin`: today at `00:00:00` in `calendar.timezone`
   - `timeMax`: today + 7 days at `23:59:59` in `calendar.timezone`

If `list-calendars` shows multiple calendars and the user hasn't pre-configured `calendar.calendar_ids`, default to `primary` only and mention to the user that additional calendars can be added.

**Filtering rules** applied to every event before it lands in the raw file:

- Drop events whose summary case-insensitively matches any pattern in `calendar.exclude_patterns`.
- Drop all-day events with no attendees (typically OOO/holiday markers) **unless** the summary mentions a project keyword from the daily notes.
- Drop events where the user's `responseStatus` is in `calendar.skip_response_statuses` (treat as "skipped").
- Drop events whose summary starts with `Canceled:` or whose `status` is `cancelled`.
- Deduplicate recurring instances by summary within the week — collapse them into a single entry annotated with the count (e.g. `"Team standup" ×4`).

**Per-event fields to keep:**
- `summary` (title)
- `start.dateTime` / `start.date`
- `end.dateTime` / `end.date`
- `attendees` length (only — never include attendee emails in the raw file)
- `htmlLink` (link back to the Calendar event)
- First non-empty paragraph of `description` (max ~200 chars), if it looks substantive (skip auto-generated Google Meet boilerplate, Zoom invite text, dial-in numbers).
- Any URL in `description` that points to GitHub, Google Docs, Slack, or the configured Obsidian/Elastic domains — these often back-link to project work.

**Classify each kept event** into one of:
- `1:1` — exactly 2 attendees including the user, or summary matches `/\b1[:\s-]?1\b/i`
- `team` — recurring team meetings (standup, planning, retro, sync, demo)
- `project` — meeting whose summary or description mentions a project name pulled from the GitHub data or Obsidian notes
- `interview` / `onboarding` — summary contains those keywords
- `other`

### Step 4: Read Obsidian Daily Notes

1. Look for file matching `/Users/sdesalas/obsidian/weekly-update/Week-starting-YYYY-MM-DD.md` for the START_DATE of the week.
2. Compare it to the file matching same pattern for the START_DATE of the previous week.
3. **Scope**: Only parse content **above** the `## REFERENCE` (or `## REFERENCE / THINGS IN THE BACKBURNER`) header. Everything below that header is backlog/reference material and MUST NOT be treated as current-week activity. If the header is absent, parse the entire file.
4. Within the in-scope region, daily activity lives under day headers (`#### Monday`, `#### Tuesday`, etc.).
5. Extract from each note:
   - **Project names**: Look for likely candidates in the body of each line, particularly on a top-level bullet point with items underneath.
   - **Work done**: Plain bullet points (`-` or `*`) under day headers represent completed work for that day. Also include `- [x]` if present.
   - **NEXT UP candidates**: Lines containing `TODO` (inline, in any case) or `📍` are strong NEXT UP signals. Also treat `- [ ]` as a NEXT UP candidate **only if it appears above the `## REFERENCE` header**. Bias toward Thursday/Friday entries.
   - **Links**: All markdown links `[text](url)` to PRs, issues, Slack threads.
   - **Blocker language**: Mentions of "blocked", "waiting for", "paused", "need X before".
   - **Non-project items**: Reviews, SDH rotation, onboarding, misc tasks.

### Step 5: Cross-Reference Data

- Match GitHub PRs/issues with daily note mentions (same URL = same item)
- Enrich GitHub-only items with just their title
- Enrich notes-only items (Slack discussions, docs, meetings) with context from notes
- A PR opened AND merged in the same week → show as "Merged" only
- PRs from the "issues commented on" results (URLs containing `/pull/`) that are not authored by nikitaindik and not already in the "PRs reviewed" list → add to "PRs reviewed". The `reviewed-by:` query can miss these due to `updated:` timestamp drift.
- **Calendar ↔ notes**: If a calendar event's `summary` or `description` matches a project name extracted from notes, attach the event to that project. If a daily note bullet describes a meeting (e.g. "had sync with X about Y") and matches a calendar event by date + topic, prefer the note's wording but keep the calendar `htmlLink` as the source link.
- **Calendar ↔ GitHub**: If a calendar event's description contains a GitHub PR/issue URL that also appears in the GitHub data, attach the event to the same project grouping (don't double-count, just enrich).
- **De-noise meetings**: Drop classified-`team` recurring meetings from the synthesized output unless the daily notes explicitly call out a decision/outcome from one of them. Recurring `team` meetings stay in the raw file but are summarized only as a count in the polished draft (see Step 7 rule 12).

### Step 5.5: Back Up Existing Output Files

Before writing either output file, check if it already exists and rename it (not delete it) using its last-modified timestamp. Run both checks in parallel:

```bash
RAW_FILE="/Users/sdesalas/obsidian/weekly-update/Status-notes/Week-starting-YYYY-MM-DD-raw.md"
if [ -f "$RAW_FILE" ]; then
  MTIME=$(date -r "$RAW_FILE" "+%Y-%m-%dT%H-%M-%S")
  mv "$RAW_FILE" "${RAW_FILE%.md}.${MTIME}.md"
fi
```

```bash
HTML_FILE="/Users/sdesalas/obsidian/weekly-update/Status-updates/Week-starting-YYYY-MM-DD.html"
if [ -f "$HTML_FILE" ]; then
  MTIME=$(date -r "$HTML_FILE" "+%Y-%m-%dT%H-%M-%S")
  mv "$HTML_FILE" "${HTML_FILE%.html}.${MTIME}.html"
fi
```

If a rename happens, note the old filename in the final reply so the user knows a backup exists (e.g. "Renamed existing raw file to `Week-starting-2026-04-21-raw.2026-04-28T14-30-00.md`").

### Step 6: Write Raw Data File

Create directory if needed, then write to `/Users/sdesalas/obsidian/weekly-update/Status-notes/Week-starting-YYYY-MM-DD-raw.md`:

```markdown
# Raw Data for Status Update – YYYY-MM-DD

## GitHub Activity (START_DATE to END_DATE)

### PRs Merged
- [title](url) — merged YYYY-MM-DD — repo

### PRs Opened
- [title](url) — opened YYYY-MM-DD — repo — [draft]

### PRs Reviewed
- [title](url) — repo

### Issues Created
- [title](url) — repo

### Issues Commented On
- [title](url) — repo

## Calendar — Past Week (START_DATE to END_DATE)

### Meetings Attended
- YYYY-MM-DD HH:MM — [Event title](htmlLink) — N attendees — class: 1:1|team|project|interview|onboarding|other
  - Linked project: <project name from notes/GitHub, if any>
  - Linked URLs: <GitHub/Slack/Docs URLs from description, if any>
  - Notes: <first substantive line of description, if any>

### Recurring Team Meetings (collapsed)
- "Standup" ×4 — class: team
- "Backlog refinement" ×1 — class: team

### Skipped / Declined (informational only)
- YYYY-MM-DD HH:MM — Event title — reason: declined|needsAction|cancelled

## Calendar — Upcoming 7 Days (used for NEXT UP)

### Upcoming Meetings
- YYYY-MM-DD HH:MM — [Event title](htmlLink) — class: 1:1|team|project|interview|onboarding|other
  - Linked project: <if any>

## Daily Notes Highlights

### YYYY-MM-DD (Day)
**Projects active**: Project A, Project B
**Work done**: [list of bullets under the day header — both plain `-` items and `- [x]` items]
**NEXT UP candidates**: [lines containing `TODO`, `📍`, or unchecked `- [ ]` items above the `## REFERENCE` header]
**Key context**: [notable bullets, decisions, discussions]
```

### Step 7: Synthesize Polished Draft

Write to `/Users/sdesalas/obsidian/weekly-update/Status-updates/Week-starting-YYYY-MM-DD.html`.

**Synthesis rules:**
1. **Group by project**: Each active project gets a `<strong>`-wrapped header with an epic/issue link if referenced in notes
2. **Verbs**: "Merged", "Opened", "Created", "Reviewed", "Requested", "Investigated", "Discussed", "Met with", "Synced with", "Demoed", "Interviewed"
3. **Link format**: `<a href="URL">PR</a>`, `<a href="URL">issue</a>`, `<a href="URL">epic</a>`, `<a href="URL">SDH</a>`, `<a href="HTMLLINK">meeting</a>` for calendar events
4. **One item per `<li>`**: Keep list items to one line where possible
5. **Reviews section**: Separate "Reviewed" sub-section under WORK DONE
6. **NEXT UP**: Derive from `TODO` markers, `📍` markers, and unchecked `- [ ]` items in the most recent daily note (only those **above** the `## REFERENCE` header — never pull from the backburner section). Group by project. Then append upcoming meetings (Step 3 result #2) — but **only** `1:1`, `project`, `interview`, and `onboarding` events, never `team` recurring meetings. List them under their matched project, or under a final `<strong>Upcoming meetings</strong>` block if unmatched.
7. **BLOCKERS**: Only if explicit blocking language found. Default to `<p>-</p>`
8. **ANYTHING ELSE**: Miscellaneous items (onboarding, docs, process work, **non-project meetings worth flagging** like all-hands, interviews, training). Default to `<p>-</p>`
9. **Don't fabricate**: Only include information found in raw data
10. **Don't duplicate**: If a PR was both opened and merged same week, list as "Merged". If a meeting is already covered by a daily-note bullet, prefer the note's wording — don't list both.
11. **HTML escaping**: Escape literal `<`, `>`, and `&` characters in titles/descriptions (e.g. `&lt;`, `&gt;`, `&amp;`). Smart-quote / curly characters can be written as-is.
12. **Recurring `team` meetings**: Don't list individually. If at least one had a substantive outcome documented in notes, mention that outcome under the relevant project. Otherwise omit entirely (the count stays in the raw file only).
13. **Project-related meetings**: Add as a `<li>` under the matching project group with the format `<li><a href="HTMLLINK">Met with</a> <Person/Team> about <topic from summary or note></li>`. Keep it to one line.

## Output Format

Write to `/Users/sdesalas/obsidian/weekly-update/Status-updates/Week-starting-YYYY-MM-DD.html`.

The polished draft MUST be a valid HTML fragment (no `<html>`, `<head>`, or `<body>` wrapper) following this exact structure:

```html
<p><strong>WORK DONE</strong></p>

<p><strong>Project Name</strong> (<a href="URL">epic</a>)</p>
<ul>
  <li>Merged <a href="URL">PR</a>: "PR title"</li>
  <li>Opened <a href="URL">PR</a>: "PR title"</li>
  <li>Created <a href="URL">issue</a>: "Description of what the issue is about"</li>
</ul>

<p><strong>Another Project</strong> (<a href="URL">SDH Rotation</a>)</p>
<ul>
  <li>Investigated further based on diagnostic bundle from the customer</li>
  <li><a href="SLACK_URL">Discussed</a> approach with the team</li>
</ul>

<p><strong>Reviewed</strong></p>
<ul>
  <li><a href="URL">PR</a>: "PR title"</li>
  <li><a href="URL">PR</a>: "PR title"</li>
</ul>

<p><strong>NEXT UP</strong></p>

<p><strong>Project Name</strong> (<a href="URL">epic</a>)</p>
<ul>
  <li>Task description (<a href="URL">issue</a>)</li>
  <li>Review Person's <a href="URL">PR</a></li>
</ul>

<p><strong>BLOCKERS</strong></p>
<p>-</p>

<p><strong>ANYTHING ELSE?</strong></p>
<p>-</p>
```

## Style Reference

Don't use `;` characters in the output.
These examples demonstrate the expected tone, structure, and level of detail.

### Example 1 (23 February 2026)

```html
<p><strong>WORK DONE</strong></p>

<p><strong>Rule Execution Log on the Rule Details page – Milestone 1</strong> (<a href="https://github.com/elastic/security-team/issues/15617">epic</a>)</p>
<ul>
  <li>Merged <a href="https://github.com/elastic/kibana/pull/252374">PR</a>: "Adjust log level and wording of logs written from rule executors"</li>
  <li>Merged <a href="https://github.com/elastic/kibana/pull/253992">PR</a>: "High-level rule execution info logging"</li>
  <li>Opened <a href="https://github.com/elastic/kibana/pull/254495">PR</a>: "Enable feature flag for Execution events tab"</li>
  <li>Created discussion <a href="https://github.com/elastic/security-team/issues/15997">issue</a>: "Separate logging levels for console and event log"</li>
  <li>Created <a href="https://github.com/elastic/security-team/issues/16022">issue</a> for future enhancements in the rule execution logger</li>
  <li>Created <a href="https://github.com/elastic/security-docs/issues/7145">issue</a>: "Document the new Execution Events tab on Rule Details page"</li>
  <li><a href="https://github.com/elastic/security-team/issues/15617#issuecomment-3944448352">Requested</a> exploratory testing in the epic. Waiting for Paula's response.</li>
</ul>

<p><strong>ConnectWise rule deletion timeouts</strong> <a href="https://github.com/elastic/sdh-security-team/issues/1578">SDH</a></p>
<ul>
  <li>Merged <a href="https://github.com/elastic/kibana/pull/253116">PR</a>: "Speed up rule bulk rule deletion"</li>
  <li><a href="https://elastic.slack.com/archives/C0725R9C0KZ/p1771487011428279?thread_ts=1771436117.368999&amp;cid=C0725R9C0KZ">Stressed</a> the importance of moving away from an internal API to our supported API in ConnectWise Slack channel.</li>
  <li>Will investigate further if we get a diag. bundle from the customer.</li>
</ul>

<p><strong>Reviewed</strong></p>
<ul>
  <li><a href="https://github.com/elastic/kibana/pull/253127">PR</a>: "Allow custom closing reasons for alerts"</li>
  <li><a href="https://github.com/elastic/docs-content/pull/5219">PR</a>: "9.2.6 release notes"</li>
  <li><a href="https://github.com/elastic/docs-content/pull/5218">PR</a>: "9.3.1 release notes"</li>
</ul>

<p><strong>NEXT UP</strong></p>

<p><strong>Detection Engine health UI – Milestone 1</strong> (<a href="https://github.com/elastic/security-team/issues/15618">epic</a>)</p>
<ul>
  <li>Review Maxim's initial visualisation <a href="https://github.com/elastic/kibana/pull/253176">PR</a></li>
  <li>Work on "Extend Detection Engine Health API with top N rules by metrics" (<a href="https://github.com/elastic/kibana/issues/251302">issue</a>), incorporate it into Maxim's initial visualisation <a href="https://github.com/elastic/kibana/pull/253176">PR</a></li>
</ul>

<p><strong>Rule Execution Log on the Rule Details page – Milestone 1</strong> (<a href="https://github.com/elastic/security-team/issues/15617">epic</a>)</p>
<ul>
  <li>Merge the feature flag enabling <a href="https://github.com/elastic/kibana/pull/254495">PR</a> once exploratory testing and docs are done</li>
</ul>

<p><strong>Review</strong></p>
<ul>
  <li><a href="https://github.com/elastic/kibana/pull/253043/changes">PR</a>: "Attach rule to AI Agent from details/edit/alerts flyout with exploration mode". Started reviewing this one.</li>
</ul>

<p><strong>BLOCKERS</strong></p>
<p>-</p>

<p><strong>ANYTHING ELSE?</strong></p>
<p>-</p>
```

### Example 2 (2 February 2026)

```html
<p><strong>WORK DONE</strong></p>

<p><strong>Investigate prebuilt rule installation timeouts</strong> (<a href="https://github.com/elastic/kibana/issues/248662">issue</a>)</p>
<ul>
  <li>Cleaned up the rule installation script a bit and <a href="https://github.com/elastic/kibana/issues/248662#issuecomment-3804285914">posted it</a> in the ticket</li>
</ul>

<p><strong>Onboarding Alainna</strong></p>
<ul>
  <li>Did the "Product Overview" team session with Alainna</li>
</ul>

<p><strong>Performance testing process documentation and gathering feedback</strong></p>
<ul>
  <li>Wrote a dev docs <a href="https://docs.elastic.dev/security-solution/process/detections/rule-management/performance-testing">article</a> (<a href="https://github.com/elastic/security-team/pull/15587">PR</a>) that describes how to do perf. testing based on my recent experience.</li>
  <li>Outlined perf. testing process done for the recent pagination effort in a <a href="https://docs.google.com/document/d/1mRRlpwvdYvT1eSCJWJzD_zVv0nRoBb0Qp6nbjdggXkk/edit?tab=t.0#heading=h.3h92gxil7o4h">Google Doc</a>. Requested feedback from the Engineering Productivity team.</li>
</ul>

<p><strong>Rule Execution Log on the Rule Details page – Milestone 1</strong> (<a href="https://github.com/elastic/security-team/issues/15617">epic</a>)</p>
<ul>
  <li>Planned upcoming work and discussed expectations with Georgii and Maxim.</li>
  <li>Decomposed work and created tickets in the <a href="https://github.com/elastic/security-team/issues/15617">epic</a> together with Maxim.</li>
  <li>Started working on the first task of the epic: "Add essential filters to the Execution events tab" (<a href="https://github.com/elastic/kibana/issues/251206">issue</a>)</li>
</ul>

<p><strong>NEXT UP</strong></p>
<p>Going to zero-in on the epic:</p>

<p><strong>Rule Execution Log on the Rule Details page – Milestone 1</strong> (<a href="https://github.com/elastic/security-team/issues/15617">epic</a>)</p>
<ul>
  <li>Continue working on "Add essential filters to the Execution events tab" (<a href="https://github.com/elastic/kibana/issues/251206">issue</a>) and next task from the <a href="https://github.com/elastic/security-team/issues/15617">epic</a>. Open a PR with some changes ASAP.</li>
  <li>Triage the tickets in the epic: add proper labels, object fields and such.</li>
</ul>

<p><strong>BLOCKERS</strong></p>
<p>-</p>

<p><strong>ANYTHING ELSE?</strong></p>
<p>-</p>
```

## Edge Cases

- **No daily notes for a day**: Skip it, rely on GitHub and calendar data
- **PR in GitHub but not in notes**: Include with just the GitHub title
- **Activity in notes but not in GitHub**: Include from notes context (Slack discussions, docs, meetings)
- **Draft PRs**: Note as "Opened draft [PR]"
- **Same PR mentioned as both created/merged and reviewed**: Include as created or merged (whichever is applicable), not as reviewed.
- **Weekend notes**: Include if they exist within the date range
- **Output directory doesn't exist**: Create `/Users/sdesalas/obsidian/weekly-update/Status-notes/` (and the `Status-updates/` subdirectory) before writing
- **Calendar MCP not available / not authenticated**: Log a single warning line, skip Step 3 entirely, continue with GitHub + notes only. Do **not** prompt the user mid-run; mention the missing data in the final reply so they can wire up the MCP.
- **Calendar MCP returns an auth error**: Same as above — skip the calendar step and surface the error in the final reply.
- **Calendar event with no title**: Skip (likely a spurious entry).
- **Calendar event spanning multiple days**: List under its start date.
- **All-day OOO/PTO events on the user's calendar during the week**: Don't include in WORK DONE. If they cover ≥1 working day, mention briefly under ANYTHING ELSE (e.g. "Out Wed–Fri").
- **Private events** (`visibility: private` or summary literally `"Busy"`/`"Private"`): Skip entirely — never leak to the raw file.
- **Tentative events** (`responseStatus: tentative`): Include but mark with `(tentative)` in the raw file; treat as attended for synthesis purposes.
