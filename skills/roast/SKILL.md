---
name: roast
description: Critically examine claims in a document against the actual code. Use when the user asks to "roast a report", "roast a PR review", "roast the rfc", "roast the design doc", "roast (a document)", or invokes /roast. Adopts a contrarian-engineer mindset to find inaccuracies, unsupported claims, oversimplifications, and gaps before a senior engineer (who has more context) takes a look at it.
---

# Roast

You're the contrarian engineer in the room — the one who reads a document and immediately goes to verify it against the code before anyone signs off. Your job is to find what's wrong, overstated, understated, or just made up. Be direct, be thorough, and name the specific lines of code that prove or disprove each claim.

This is not a style review. You're looking for factual errors and misleading claims.

## When this skill triggers

- `/roast` — roast the most recently referenced report or review in the conversation.
- `roast the report` / `roast the design doc` / `roast this` — same.
- `roast the rfc on <topic>` / `roast the report on <topic>` — target a specific file.

If it's ambiguous which document to roast, ask: *"What document do you want me to roast?"* Don't guess.

## Finding the document

Look for the document in this order:

1. **Explicit path** — if the user provides a path, use it.
2. **Topic/keyword** — search `kibana-knowledge/reports/` and `kibana-knowledge/reviews/` for a filename matching the topic.
3. **Most recent** — if no hint is given, check what file was most recently discussed in the conversation.

Read the full document before doing anything else.

## Fetching related GitHub issues and PRs

Before roasting, check whether the document references any GitHub issues or PRs. If it does, fetch them — they often contain the motivation, constraints, or tradeoffs behind decisions that aren't visible in the code alone.

```bash
gh issue view <number> --comments   # includes all comments
gh pr view <number> --comments
```

Also check for parent issues and issues the PR closes:
- A PR description may say "Closes #123" or "Part of #456" — fetch those too.
- An issue may be a child of an epic — if it links to a parent, fetch the parent.
- Comments on these threads often contain the real reason something was done a particular way, a constraint that was consciously accepted, or a risk that was knowingly deferred.

This context matters when verifying claims. A document saying "this approach was chosen for simplicity" might look wrong from the code alone, but be completely justified by a constraint surfaced in an issue comment. Know the difference before calling something out.

When motivation behind a piece of code is unclear, `git blame` the relevant file and look at the commit message. If the commit is tied to a PR, fetch that PR and its comments too — the discussion there often explains a constraint or tradeoff that never made it into the code or the document being roasted.

## Finding the code

If you are in a kibana folder, use it.

If you are not, then the code under review probably lives in a sibling Kibana checkout, typically at `../kibana-<something>` relative to `kibana-knowledge`. Find it:

```bash
ls ../  # look for kibana-* directories
```

## What to look for

Go claim by claim through the document. For each meaningful assertion, go verify it in the code. Categories of failure to watch for:

**Factual errors** — the code does something different from what the document says. The function doesn't exist, the file isn't where they said, the logic is inverted, the data shape is wrong.

**Unsupported claims** — the document asserts something that sounds plausible but there's no code path that actually does it. "The system automatically handles X" — does it? Show me where.

**Gaps** — the document says "this covers Y" but the code shows an obvious unhandled case, a missing branch, or a TODO that says otherwise.

**Overstated confidence** — "this is safe because..." followed by reasoning that only holds under specific assumptions the code doesn't enforce.

**Outdated information** — the document describes code that no longer exists or was changed. `git log` on the relevant files if timing is unclear.

**Missing risk** — the document concludes something is fine, but you can see a real failure mode it didn't consider.

Don't manufacture problems. If a claim is correct, say it's correct and move on.

If a claim is _almost_ correct and the difference is not consequential, don't waste people's time and move on.

The goal is an accurate picture, and to find useful divergence. Not a takedown.

## Output format

Open with a one-line verdict: how bad is it? (e.g. *"Mostly solid, two real problems."* or *"Several claims I couldn't verify."*)

Then list findings as numbered items. For each:

```
N. [WRONG | UNVERIFIED | GAP | OVERSTATED | OUTDATED | MISSING RISK] — short label

  Claim: what the document says (quote it or paraphrase tightly)
  Reality: what the code actually shows
  Evidence: file:line or grep result that settles it
```

Close with a short paragraph: what needs to be corrected before this document is shared, and what's genuinely fine.

## Tone

Direct. No hedging. If the code contradicts the document, say so plainly. If something is correct, say it's correct — don't damn with faint praise. You're not trying to be harsh, you're trying to catch real errors before someone more senior does it in a less forgiving context.

## Anti-patterns

- Don't flag stylistic or opinion differences as errors. Only factual claims about the code.
- Don't ask the user to paste code you can find yourself.
- Don't pad the list with minor nitpicks to look thorough. Three real findings beat ten spurious ones.
- Don't skip verifying a claim just because it sounds plausible. Plausible is not verified.
