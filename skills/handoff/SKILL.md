---
name: handoff
description: Compacts the current conversation into a handoff document so another agent (or a future session) can pick up where this one left off. Use when the user says "handoff", "hand off", "create a handoff", "handoff to next agent", or similar. Accepts an optional argument describing the next session's focus.
---

# Handoff

Produce a handoff document that lets a fresh agent continue this conversation without re-reading the full history.

## When this skill triggers

The user says something like:
- `/handoff`
- `create a handoff`
- `handoff to next agent`
- `handoff — focus on X`

If no argument is given, write a general continuity handoff. If an argument is given, tailor the document toward that focus area.

## Output file

Save to:

```
/Users/sdesalas/Code/sdesalas/kibana-knowledge/handoff/handoff-<YYYY-MM-DD>-<HHmm>-<slug>.md
```

- `<YYYY-MM-DD>` — today's date
- `<HHmm>` — current 24h time (e.g. `1430`)
- `<slug>` — 2–4 word kebab-case summary of what this session was about (e.g. `bulk-create-rules`, `auth-middleware-refactor`). Derive from the conversation; don't ask the user unless it's completely ambiguous.

Example: `handoff-2026-05-27-1430-bulk-create-rules.md`

Create the folder if it doesn't exist.

After writing, tell the user: *"Handoff saved to `kibana-knowledge/handoff/handoff-<date>.md`."*

## Document structure

Write the document in this order:

### Context
1–3 sentences on what this session was about. Who the user is, what repo/project, what problem was being solved.

### What happened
Bulleted list of the key decisions, findings, and actions taken this session — ordered chronologically. Focus on conclusions, not process. Skip dead ends unless they ruled out an important path.

### Current state
Where things stand right now. What's done, what's in progress, what's blocked. If there are open files, branches, or uncommitted changes relevant to continuing — name them.

### Next session focus
If the user passed an argument, use it to frame this section. Otherwise, derive it from the conversation: what's the most natural next step?

Be specific. "Continue implementing X" is worse than "Implement the `bulkCreate` preflight check in `x-pack/plugins/security_solution/server/lib/detection_engine/rule_management/api/`."

### Suggested skills
List 1–4 Claude Code skills (by slash-command name) the next agent should consider using, with a one-line reason each. Only list skills that are genuinely relevant — don't pad.

### Artifacts
Reference paths or URLs to existing artifacts that the next agent should load or be aware of — plans, reports, diffs, issues, PRDs, ADRs, commits. One line each. No duplication of content — just pointers.

## What to exclude

- API keys, passwords, tokens, PII
- Content already fully captured in a linked artifact
- Intermediate reasoning steps, failed attempts, or exploratory tangents (unless they blocked a path worth knowing)

## Tone

Write for an agent, not a human. Dense, precise, no filler. Bullet points over prose wherever possible. The goal is maximum continuity per token.
