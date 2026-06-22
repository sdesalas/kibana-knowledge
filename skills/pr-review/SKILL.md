---
name: pr-review
description: Analyze a GitHub pull request to help the user understand what it does, what assumptions it makes, and where the risks are. Use whenever the user asks to review, analyze, understand, or look at a PR, pull request, diff, patch, or code change — whether they paste a diff, paste a GitHub URL, or reference a branch/commit in the current repo. Runs inside the user's checked-out repository and reads surrounding code directly from the filesystem for context. Produces analysis and questions, not a rubber-stamp approval.
---

# PR Review

Analyze a PR and help the user understand it — in their own repo, with full filesystem access to surrounding code. Output is analysis and questions, not suggested LGTMs.

## When this skill triggers

The user wants to understand a PR. They may provide it as:
- A **GitHub URL** (e.g. `github.com/org/repo/pull/123`) — handle per "Fetching the PR" below.
- A **PR number** alone (e.g. "review #456" or "PR 456") — same as above; `gh` infers the repo from the current directory.
- A **pasted diff** — work from that directly. Ask for the PR number or URL so the description can be fetched; if unavailable, proceed with the diff alone.
- A **branch or commit reference** in the current repo — use `git diff main...branch-name` or `git show <sha>`. Ask whether there's a corresponding PR number.
- An **open file** or file path — treat as "help me understand this change" if it's a diff/patch file.

If the user says something like "review the PR" or "look at my pull request" with no identifier, ask: *"What's the PR number or URL?"* Don't guess from context — a wrong PR wastes the whole analysis.

## Fetching the PR

Always fetch the PR description and linked issues when a PR number or URL is available — the description usually contains the *intent* that isn't visible in the diff itself. Prefer the `gh` CLI:

```bash
# Description, title, body, linked issues, labels
gh pr view <number> --json title,body,author,state,labels,baseRefName,headRefName,closingIssuesReferences

# The diff
gh pr diff <number>
```

If `gh` is not installed or not authenticated, fall back to `web_fetch` on the PR URL for the description and the `.diff` URL (e.g. `https://github.com/org/repo/pull/123.diff`) for the diff. If both fail, tell the user and ask them to paste the description and/or diff.

## Fetching linked issues

When the PR description references a linked issue (e.g. "Fixes #789"), also fetch that issue with `gh issue view 789` — it often contains the problem statement that explains *why* the change is being made. Sometimes the linked issue may not contain a sufficient description, so you may have to go one step further and reference the epic linked to that issue (also using `gh issue view <epic_no>`).

In the Summary section of the output, briefly reconcile the stated intent (in the PR description, or the linked issues) with what the diff actually does. If they diverge (common for PRs that grew beyond their original scope), flag that explicitly.

## Team-aware review (optional)

After confirming the PR to review and before starting the analysis, ask the user:

> *"Do you want a team-aware review? If yes, which team's files should I focus on? (default: `@elastic/security-detection-rule-management`)"*

Accept answers like "yes", "no", "skip", or a different team handle (e.g. `@elastic/some-other-team`). If the user declines, skip this section entirely and proceed with a standard review.

If the user accepts, determine ownership for each changed file:

1. Read `CODEOWNERS` from the repo (check `.github/CODEOWNERS`, then repo root `CODEOWNERS`, then `docs/CODEOWNERS` — use the first one found).
2. If no CODEOWNERS file exists, note "No CODEOWNERS file found — cannot determine ownership" and proceed with the standard review.
3. Parse CODEOWNERS and match each changed file path against the patterns. Rules are `<glob-pattern> <owner1> <owner2> ...`, and **later rules override earlier ones** — take the last matching rule per file. If `gh` is available and the PR is public, `gh pr view <number> --json files` sometimes exposes codeowner data directly; use that if present, otherwise parse manually.
4. Partition changed files into three buckets:
   - **Owned by the target team** (the team handle appears in the matching rule)
   - **Owned by other teams** (list the owning team handles)
   - **Unowned** (no rule matches)

Include an **Ownership** block near the top of the output, before Files touched:

> **Ownership (team: `@elastic/security-detection-rule-management`)**
> - **Your team's files (N):** `path/a.py`, `path/b.py` — *focus review effort here*
> - **Other teams' files:** `path/c.py` (`@elastic/some-other-team`), `path/d.py` (`@elastic/another-team`)
> - **Unowned:** `path/e.py`

If the PR touches **zero** files owned by the target team, say so prominently — the user may have been cc'd for visibility rather than as the accountable reviewer, which changes how much depth is warranted.

When team-aware review is active, weight attention toward the target team's files: deeper flow tracing, more careful assumption/risk analysis. Files owned by other teams still get covered (cross-team changes can still break things), but treated as context rather than the main focus.

## Operating context

This skill runs inside the user's checked-out repository. This is important:

- **Read surrounding code directly.** When the diff references a function, class, or module not shown, use `grep`, `rg`, or file reads to pull up the definition. Do not ask the user to paste it.
- **Use git history.** `git log`, `git blame`, and `git show` on the affected files give you the "why" behind existing code. Use them when the diff modifies something whose original intent isn't obvious.
- **Check tests.** If the diff changes `foo.py`, look for `test_foo.py` or similar — existing test behavior constrains what the change is allowed to break.
- **Don't ask for context you could fetch yourself.** Asking the user to paste a file they've already given you access to via the repo is a failure mode to avoid.

## Scale to the PR

Not every PR deserves the full treatment.

- **Trivial** (typo, single-line config, dependency bump, comment-only): one-paragraph summary plus any non-obvious risk. Stop there.
- **Small** (one component, <~100 lines, clear purpose): summary + a short risk/assumptions note + learning note. Skip the detailed flow trace.
- **Substantive** (multiple components, non-trivial logic, migrations, shared utilities, auth, or anything touching state): full analysis as described below.

State which level you're applying at the top of the output so the user knows what to expect.

## Full analysis structure

For substantive PRs, produce output in this exact structure. Use markdown headers so the user can skim.

The document should open with a header block before any sections:

```
# PR Review: #<number> — <title>

**PR:** [org/repo#<number>](<github url>)
```

Other relevant links (Slack threads, GitHub issues, related commits, design docs) should be included as well but they belong inline within the section where they are referenced.

---

### Context / Motivation *(optional)*
Include this section when the PR is motivated by a specific reported concern, blocker, or discussion — e.g. a GitHub issue, a Slack thread, a team review comment. Omit it for straightforward feature work where the PR description alone is self-explanatory.

Summarise the external context in plain language, then quote the key statements verbatim (using blockquotes). Cover:
- Who raised the concern and where — hyperlink directly to the source (Slack thread, GitHub issue, PR comment) using any URLs the user provided or that appear in the PR description. Do not guess or construct URLs.
- What the original design decision was and why it was made
- What the objection or blocker was
- How the author resolved the tension (and what was explicitly deferred)

The goal is that a reader with no access to Slack or the linked issue can understand the *why* behind every non-obvious choice in the diff.

### Validating the issue — does this PR address it? *(optional)*
Include this section when **Context / Motivation** is present and the concern is technical enough to warrant independent verification. Omit it when the concern is organisational, stylistic, or already self-evident from the diff.

Open with a one-line verdict: **"The concern is technically valid. The PR addresses it correctly."** (or the appropriate variant). Then structure the body as:

- **Where the problem manifests** — locate the exact mechanism in the code that makes the concern real, not just restate the claim.
- **Why the old approach was a problem** — concrete failure mode, ideally with a real or plausible example.
- **How the PR fixes it** — trace the specific change that closes the gap, referencing file/function. A before/after table is useful when the change is a structural shift rather than a line edit.
- **Residual caveat** *(if any)* — one thing the fix doesn't fully cover, and why that's an acceptable trade-off.

### Summary
2–4 sentences in plain language: what behavior changes, what is added, what is removed. Not a file-by-file recap — the *intent* of the change. Draw on the PR description and linked issue for stated intent, but verify it against the diff. If they diverge, note it here.

### Files touched
Group files by concern (not alphabetically). For each group, one line on what role those files play in the system and why this PR needed to modify them. If a file's role isn't obvious from the diff, read it from the repo before writing this section.

### Flow trace
Pick the most important path the change affects — a request, a user action, a background job, a CLI invocation — and walk it end-to-end through the modified code. Reference specific functions/files. If the trace crosses files not in the diff, follow it there by reading those files. Keep to ~10 steps maximum; if it's longer, the PR is probably doing too much.

### Assumptions
What this code assumes that isn't visible in the diff. Be concrete. Categories to consider:
- State of the database, cache, or external services
- Behavior of code outside the diff (callers, callees, middleware)
- Ordering, concurrency, idempotency, retries
- Config values, feature flags, environment
- Input shape and validation upstream

One bullet per assumption. Only list real ones — don't pad.

### Risks
What's most likely to break, ordered by severity. Give each a one-line "why this is risky" justification. Categories that deserve extra scrutiny: schema migrations, shared utility changes, authentication/authorization, anything touching persisted state, anything removing validation, anything changing public API.

### Open questions
Things you are uncertain about after reading the diff *and* the surrounding code — phrased as questions the user could ask the PR author. These should be questions a thoughtful reviewer would genuinely want answered, not formalities. If there are none, say so.

### Notes for your codebase map
A short summary (3–6 bullets) of what this PR reveals about how the codebase works — architectural patterns, conventions, quirks, or the role of specific components. Written so the user can paste it into their running notes doc. Focus on what's *newly learned*, not a recap of the PR.

### Review activities
This is a running log populated during the review session — not written upfront. Leave this section **empty** in the initial output, unless some investigation work has been carried out in the current session (see Follow-up investigations).

## Tone and calibration

- **Be direct about uncertainty.** If you read the code and still don't understand why something is done a certain way, say so — don't paper over it. "I couldn't tell from the surrounding code whether X is always true" is useful; a confident wrong guess is not.
- **Surface questions, don't invent problems.** If the code looks fine, say it looks fine. Don't manufacture risks to fill the section.
- **Distinguish "this is wrong" from "I don't understand this yet."** The user is newer to this codebase than the PR author — default to the latter framing unless confident.
- **No nitpicks on style, naming, or formatting** unless they genuinely affect correctness or comprehension. Those belong to linters and to more experienced reviewers.

## Output file

After completing the analysis, write the full review to a Markdown file in the current project:

```
/Users/sdesalas/Code/sdesalas/kibana-knowledge/reviews/pr-review-<number>.md
```

Where `<number>` is the PR number (e.g. `pr-review-1234.md`). If the PR has no number (e.g. a pasted diff or local branch), use a short slug derived from the title or branch name (e.g. `pr-review-add-rate-limiting.md`).

- Create folder if it doesn't exist.
- The file content should be identical to the analysis you produce in chat — same headers, same structure, no extra framing.
- After writing the file, tell the user: *"Review saved to `kibana-knowledge/reports/pr-review-<number>.md`."*

## Follow-up investigations

When the user asks you to dig further into something related to a review already saved to file — checking a code path, verifying an assumption, confirming a local test result, exploring a risk — append a new numbered entry to the **Review activities** section of that review file.

Each entry should be one tight paragraph: what was investigated and what was found (or confirmed). Do not rewrite or reorganise existing entries.

This keeps a faithful log of what was actually explored during the session, so the review file reflects not just the initial analysis but the full conversation.

## Anti-patterns

Avoid these. They're common failure modes when analyzing PRs.

- Restating the diff file-by-file without synthesis. The user can read the diff themselves.
- Listing every function changed as a "risk." Risk requires a reason.
- Asking the user for files you could read yourself from the repo.
- Treating every PR as substantive. A dependency bump doesn't need a flow trace.
- Generating suggested approval comments or LGTM verdicts. This skill produces analysis; the user decides what to do with it.
- Padding the Assumptions or Risks sections. Empty is fine when there's nothing real to say.

## Worked example (abbreviated)

For a small PR that adds rate-limiting middleware to an API endpoint:

> **Scale:** Small PR.
>
> **Ownership (team: `@elastic/security-detection-rule-management`):** Both files owned by target team — squarely in scope.
>
> **Context / Motivation:** Security flagged ([issue #4821](https://github.com/org/repo/issues/4821)) that `POST /api/v1/webhooks` was being abused in a credential-stuffing incident. The original endpoint had no rate limiting because webhook throughput was assumed to be low-volume internal traffic. That assumption no longer holds after the endpoint was made public in v2.3.
>
> **Validating the issue — does this PR address it?** The concern is valid. The endpoint accepts unauthenticated POST requests with no throttle — confirmed in `api/webhooks.py` (no middleware in the handler chain). The PR wires in the existing `RateLimiter` at 100 req/min per IP, which matches the limit already applied to the login endpoint. Residual caveat: limits by client IP from `X-Forwarded-For`, so attackers behind a proxy pool can still distribute load across IPs.
>
> **Summary:** Adds a per-IP rate limiter (100 req/min) to `POST /api/v1/webhooks`. Uses the existing Redis-backed `RateLimiter` class rather than introducing a new dependency.
>
> **Files touched:** `api/webhooks.py` (wires the limiter into the route), `config/rate_limits.py` (adds the new limit entry).
>
> **Assumptions:** Redis is available at request time — there's no fallback if the limiter raises. The existing `RateLimiter` key scheme uses client IP from `X-Forwarded-For`, so this assumes the upstream proxy is setting that header correctly (verified in `middleware/proxy_headers.py`).
>
> **Risks:** If Redis is down, all webhook POSTs will 500 rather than degrading open. Worth asking whether that's intentional — other endpoints using `RateLimiter` appear to `try/except` around it.
>
> **Open questions:** Is 100/min the right number? Couldn't find prior discussion in commit history. Should failed-open vs failed-closed behavior match other endpoints?
>
> **Notes for your codebase map:** Rate limiting is centralized in `RateLimiter` (Redis-backed). Configured per-route in `config/rate_limits.py`. Existing convention is to fail open on Redis errors — this PR diverges from that.
>
> **Review activities:**
>
> 1. **Checked Redis failure behavior.** Read `RateLimiter.__call__` in `middleware/rate_limiter.py:42–67` — no `try/except` around the Redis call, confirming the PR will 500 on Redis errors. Checked three other endpoints using `RateLimiter` — all three wrap it in `try/except` and return `200`. This PR diverges from the convention; raised in Open questions.
>
> 2. **Verified `X-Forwarded-For` handling.** Traced the header through `middleware/proxy_headers.py:23` — reads the leftmost IP, falling back to `request.remote_addr` when the header is absent (direct connections). Assumption in main analysis holds.