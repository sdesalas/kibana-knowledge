---
name: handoff
description: Compacts the current conversation into a handoff document so another agent (or a future session) can pick up where this one left off. Use when the user says "handoff", "hand off", "create a handoff", "handoff to next agent", or similar. Accepts an optional argument describing the next session's focus, and an optional "quick" modifier for a short-form handoff.
---

# Handoff

Produce a handoff document that lets a fresh agent continue this conversation without re-reading the full history.

## When this skill triggers

The user says something like:
- `/handoff`
- `/handoff quick`
- `create a handoff`
- `handoff to next agent`
- `handoff — focus on X`
- `quick handoff for X`

## Two modes

### Quick handoff

Triggered by: `/handoff quick`, `quick handoff`, or the user says "under N words" / "brief handoff".

**Target size: ~300 words.** Write only:

1. **Context** — 1–2 sentences: who, what repo, what problem.
2. **Decision / Current state** — bullet points only. What was decided or confirmed. What's done, in progress, blocked.
3. **Next session focus** — specific and actionable. Name files, PRs, or functions. No vague "continue X".
4. **Artifacts** — links and paths only, one line each.

No "Original dialog", no "Conclusions", no "Suggested skills" sections.

---

### Full handoff

Triggered by: `/handoff`, `/handoff full`, or any handoff without "quick".

**Target size: 1000–2500 words** (can be ~800 for narrow sub-tasks). Write in this order:

#### Context
1–3 sentences on what this session was about. Who the user is, what repo/project, what problem was being solved.

#### Original dialog
Include original dialog focusing on questions posed and prompts entered by the user. These are important because they add instructions that are often expected to be followed by the next agent, like how to format a document, handle certain code changes, or how to interact with the user. Add key insights and short reflections as a sub-commentary after each dialog point, where it makes sense.

#### Conclusions
Bulleted list of the key decisions, findings, and actions taken this session — ordered chronologically. Focus on conclusions, not process. Skip dead ends unless they ruled out an important path.

#### Current state
Where things stand right now. What's done, what's in progress, what's blocked. If there are open files, branches, or uncommitted changes relevant to continuing — name them.

#### Next session focus
If the user passed an argument, use it to frame this section. Otherwise, derive it from the conversation: what's the most natural next step?

Be specific. "Continue implementing X" is worse than "Implement the `bulkCreate` preflight check in `x-pack/plugins/security_solution/server/lib/detection_engine/rule_management/api/`."

#### Suggested skills
List 1–4 Claude Code skills (by slash-command name) the next agent should consider using, with a one-line reason each. Only list skills that are genuinely relevant — don't pad.

#### Artifacts
Reference paths or URLs to existing artifacts that the next agent should load or be aware of — plans, reports, diffs, issues, PRDs, ADRs, commits. One line each. No duplication of content — just pointers.

---

## Output file

Save to:

```
/Users/sdesalas/Code/sdesalas/kibana-knowledge/handoff/handoff-<YYYY-MM-DD>-<HHmm>-<slug>.md
```

- `<YYYY-MM-DD>` — today's date
- `<HHmm>` — current 24h time (e.g. `1430`)
- `<slug>` — 2–4 word kebab-case summary of what this session was about. Derive from the conversation; don't ask unless completely ambiguous.

Example: `handoff-2026-05-27-1430-bulk-create-rules.md`

Create the folder if it doesn't exist.

After writing, tell the user: *"Handoff saved to `kibana-knowledge/handoff/handoff-<date>.md`."*

## What to exclude

- API keys, passwords, tokens, PII
- Content already fully captured in a linked artifact
- Intermediate reasoning steps, failed attempts, or exploratory tangents (unless they blocked a path worth knowing)

## Tone

Write for an agent, not a human. Dense, precise, no filler. Bullet points over prose wherever possible. The goal is maximum continuity per token.
