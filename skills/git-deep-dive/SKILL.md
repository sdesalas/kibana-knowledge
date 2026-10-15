---
name: git-deep-dive
description: >-
  Deep-investigate why the codebase behaves a certain way using git blame,
  commit history, and GitHub issues/PRs — not speculation from current code.
  Use ONLY when the user explicitly invokes /git-deep-dive. Do not auto-trigger.
disable-model-invocation: true
---

# /git-deep-dive

Find **evidence** for why a behavior exists. Current code and comments are clues, not answers. Prefer primary sources: commits, PRs, issues, review threads, tests that lock the behavior.

## Inputs

Need a concrete behavior. If fuzzy, pin it first:

- **What** happens (observable outcome)
- **Where** (file/symbol or API + params)
- **Contrast** (when it does *not* happen — e.g. flag true vs false)

## Method (do in order)

1. **Locate the decision** — the `if`/branch/Map/filter that produces the behavior. Grep + read.
2. **Blame the decisive lines** — `git blame -L <start>,<end> -- <file>`. Note commit SHAs and dates. Blaming nearby lines may contain clues too but could lead to work to uncover.
3. **Walk history to birth** — for each SHA: `git show --stat <sha>`, then `git log -S'<symbol>' -- <file>` / `git log -L:<fn>:<file>` until the behavior was introduced. Prefer the *introducing* change over later drive-bys.
4. **Resolve PR + issue** — `gh` only (not WebFetch unless `gh` fails):
   ```bash
   gh api search/issues -f q='<sha> repo:<owner>/<repo>'
   # or from commit message / "(#NNNN)"
   gh pr view <n> --comments
   gh pr view <n> --json title,body,author,mergedAt,closingIssuesReferences,url
   gh issue view <n> --comments
   ```
   Read PR body, linked issues, and review comments for *stated intent*. Search sibling PRs in the same era if the introducing PR is silent.
5. **Check tests that lock it** — e2e/unit assertions often encode intent when product docs don't. Note whether tests differ by flag/path (asymmetry = signal).
6. **Classify** (pick one; say so):
   - **Product-stated** — issue/PR explicitly justifies it
   - **Test-locked** — tests assert it; no written product rationale found
   - **Incidental** — fell out of a refactor/dedupe; no one called out the side effect
   - **Unknown** — history exhausted; say what you checked

## History gotchas

- **Shallow / partial clone** — blame/log stop early. Use a full-history clone (e.g. sibling `../kibana-main`) or `git fetch --unshallow` / deepen. Don't invent history from a truncated log.
- **Squash merges** — intermediate commits vanish from `main`. Fetch the PR head: `git fetch origin pull/<n>/head:pr-<n>` and inspect that branch.
- **Huge repos** — avoid `git log --all`. Scope by path, `-S`/`-G`, or `-L`. Cap with `-n` and paginate.
- **Path moves** — follow renames: `git log --follow -- <file>`; blame may need the pre-move path.
- **Permissions** — checkout/fetch of old refs often needs full sandbox/`all` perms.

## Output (compact)

1. **Verdict** — one sentence + classification above.
2. **Timeline** — table: date | PR/commit | what changed | intent signal (quote or "none").
3. **Evidence** — permalinks (`gh` URLs or `owner/repo@sha` paths). No vibes.
4. **Implications** — if changing the behavior: what tests/docs break; whether silence means "safe to fix" vs "deliberate, ask owners".

Stop when evidence is enough for a confident classification. Don't pad with restated code. If unknown, list what you searched and stop, let the user know the reason has not been fully uncovered.
