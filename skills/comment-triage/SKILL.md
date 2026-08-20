---
name: comment-triage
description: Triage every review thread on a GitHub pull request, verify each comment against the current PR head, group duplicate concerns, identify what is actually addressed or still open, and produce a linked Markdown punch list. Use only when the user explicitly invokes /comment-triage or $comment-triage, or explicitly asks to use the comment-triage skill. Do not apply from ambient context or merely because the user asks about PR comments.
disable-model-invocation: true
---

# PR Comment Triage

Turn a long-running PR conversation into an evidence-backed closeout document. The goal is not to restate comments or trust GitHub resolution state; it is to determine what the current code still requires.

Use this skill only after the user explicitly invokes `/comment-triage` or `$comment-triage`, or explicitly asks to use the comment-triage skill. Do not invoke it automatically for ordinary PR review or comment questions.

## Collect the complete conversation

Resolve the repository, PR number, and current head SHA. Fetch PR metadata with `gh pr view`, including the title, body, author, state, base/head refs, head SHA, review decision, and commits.

```bash
gh pr view <number> --repo <owner/repo> \
  --json number,title,url,body,author,state,isDraft,reviewDecision,baseRefName,headRefName,headRefOid,updatedAt,commits
```

Fetch all inline review threads with `gh api graphql --paginate --slurp`. Query `repository.pullRequest.reviewThreads(first:100, after:$endCursor)` and request, at minimum:

- thread fields: `isResolved`, `isOutdated`, `path`, `line`, and `originalLine`;
- every comment's `databaseId`, `url`, `body`, `createdAt`, `updatedAt`, `author.login`, and `replyTo.databaseId`;
- `pageInfo { hasNextPage endCursor }` so pagination is complete.

Also fetch review summaries and top-level comments:

```bash
gh api --paginate --slurp repos/<owner>/<repo>/pulls/<number>/reviews?per_page=100
gh api --paginate --slurp repos/<owner>/<repo>/issues/<number>/comments?per_page=100
```

Store outputs in temporary files when that makes repeated filtering easier.

Do not use `gh pr view --json comments,reviews` as the sole source: it omits inline review-thread structure. Do not omit resolved or outdated threads; both regularly contain requirements that reappear or regress.

Treat non-empty review summaries as acceptance context even though they are not inline threads. Read top-level comments for performance results, test evidence, follow-up links, and decisions that answer an inline ask.

## Verify against the exact PR head

Record the head SHA and branch in the report. Locate a local checkout when possible, but do not assume its working tree is current.

- If the commit exists locally, inspect it with `git show <head>:<path>`, `git grep <head>`, and diffs against its merge base.
- If the branch is behind locally, fetch the remote branch without checking it out or altering the working tree, then inspect the fetched commit.
- If no local repository is available, use GitHub's file/diff APIs and clearly state that verification was remote-only.
- Check tests as well as implementation. A reply saying “addressed” or linking a commit is evidence to investigate, not proof.

Run focused tests only when they materially improve confidence and can run against the checked head without disturbing the user's working tree. A green CI result supports the report but does not replace code verification.

## Build a thread ledger

Number inline threads `T1`, `T2`, and so on in the order returned by GitHub. Use the root comment's canonical `discussion_r...` link for the thread. For every thread, track:

- author and concrete ask;
- replies, claimed fixes, decisions, and linked follow-ups;
- GitHub resolved/outdated flags;
- current-code evidence;
- verified status.

Use these status meanings consistently:

- **Addressed:** the current code, tests, or an explicit accepted explanation satisfies the ask.
- **Not addressed:** the requested behavior or decision is still missing.
- **Partially addressed:** meaningful work landed, but an explicit acceptance criterion remains unmet.
- **Accepted deferral:** not implemented here, but the thread contains a clear agreement and a concrete follow-up issue. Do not call this “done.”
- **Informational / self-note:** no external action is requested, or the note is obsolete.
- **Stale / trap:** the comment describes code that no longer exists or proposes a fix that would now be wrong.
- **Needs decision/reply:** competing reviewer directions or an unanswered architectural choice prevent an objective done/not-done classification.

Never infer status from `isResolved`. Explicitly surface mismatches in both directions: unresolved-but-addressed and resolved-but-still-open.

## Synthesize, don't inventory

Group threads that describe the same underlying issue. Count both raw threads and real remaining issues so duplicate bot findings do not inflate the punch list.

Sort themes strictly by the number of related root review threads, highest count first. Replies and follow-ups provide evidence inside a thread but do not increase the theme count. For equal counts, order by severity or perceived importance.

Within each theme:

1. State the verified status first.
2. Explain the reviewers' underlying concern.
3. Cite all related thread links.
4. Describe the current code/test evidence.
5. Say exactly what action remains, if any.

Call out conflicting reviewer instructions. Prefer explaining which direction the current code follows and why over treating both requests as simultaneously implementable.

Performance requests need their original acceptance dimensions preserved: workloads, enabled/disabled state, batch sizes, environment, machine shape, repetitions, and comparison baseline. Do not treat a smaller or different benchmark as full completion merely because numbers were posted.

## Write the report

Save the result to:

```text
/Users/sdesalas/Code/sdesalas/kibana-knowledge/reviews/comment-triage/pr-<number>-comment-triage.md
```

Use the smallest structure that makes the PR easy to close. For a substantive PR, normally include:

1. Header block: PR, author, checked branch/SHA, date, method, and verification-based counts.
2. Themes ordered by number of related root review threads, descending.
3. Addressed table with concise evidence.
4. Not addressed / partial / decision-needed table.
5. Unsure or trap section when relevant.
6. GitHub resolve-flag mismatch table.
7. Priority punch list phrased as concrete next actions.

Every substantive claim should link to the relevant thread, review summary, result comment, issue, or commit. Distinguish direct verification from inference.

If the report already exists, read it first. Update it to the new checked head while preserving useful historical decisions and noting regressions; do not blindly regenerate it from the latest comments alone.

For style and useful levels of detail, consult these examples only when needed:

- `/Users/sdesalas/Code/sdesalas/kibana-knowledge/reviews/comment-triage/pr-276947-comment-triage.md`
- `/Users/sdesalas/Code/sdesalas/kibana-knowledge/reviews/comment-triage/pr-275695-comment-triage.md`

## Boundaries

- Do not post replies, resolve threads, submit a review, or change PR code unless the user separately asks.
- Do not manufacture action items from style nits or informational comments.
- Do not hide uncertainty. Use “needs decision” when current evidence cannot settle a disagreement.
- Report completion with the absolute path and a short list of the real remaining issues.
