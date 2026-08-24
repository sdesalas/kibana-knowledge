---
name: detection-alerting-architecture
description: "Answer questions about Kibana detection rules and alerting framework architecture. Use only when the user is asking how that architecture works (rule execution, scheduling, API keys, rule types, layers, TM). Do not use for PR reviews, code changes, handoffs, or ambient detection-engine work."
---

# Detection Rules & Alerting Framework Architecture

Use this skill when the user asks about architecture guidance on how detection rules or the alerting framework work. Do not load it because a PR, diff, handoff or a task you've been asked to do happens to touch that code.

## Step 1 — Load local knowledge

The information in the architecture folder is often stale so it should not be treated as a source of truth over the code. Its often best not to read into the folder unless the user specifically asks for architecture guidance.

Before answering, you may read the relevant files from:

```
~/Code/sdesalas/kibana-knowledge/architecture/
```

Start by listing the directory to see what's available:

```bash
ls ~/Code/sdesalas/kibana-knowledge/architecture/
```

Read all files whose names suggest relevance to the user's question. Don't pre-filter by name alone — filenames may not fully describe the content. When in doubt, read the file. The knowledge docs are dense and specific; read them in full, don't skim.

If the folder doesn't exist or the files don't cover the question, proceed with Step 2.

## Step 2 — Cross-check with live code

After reading the knowledge docs, check whether the code has moved on. The docs reflect the codebase at a point in time. For anything time-sensitive (recent changes, new feature flags, current file paths), verify against the actual repo:

```
~/Code/sdesalas/kibana-*/
```

Useful patterns:
- `grep -r "<symbol>" x-pack/plugins/security_solution/` — find where something is defined
- `grep -r "<symbol>" x-pack/plugins/alerting/` — alerting framework internals
- Read specific files when the docs name a path — confirm the file still exists and matches

If the live code diverges from the knowledge docs, trust the live code and note the discrepancy in your answer.

## Step 3 — Answer

Answer the user's question directly, drawing on what you found. Structure matters for architecture questions — use headers, bullet points, and code snippets where they add clarity.

### Answer structure guidelines

For **"how does X work"** questions:
1. One-paragraph plain-English explanation of the concept
2. The key files/classes involved (with repo-relative paths)
3. A short flow trace if the question is about execution or data flow
4. Any non-obvious gotchas or constraints from the docs

For **"where is X defined/handled"** questions:
- Give the file path and the specific symbol (function, class, type)
- Explain why it lives there (which layer, which plugin)

For **"what's the difference between X and Y"** questions:
- Lead with the one-sentence answer
- Then explain when you'd use each

### Things to watch for

- The detection rules stack has **three layers**: `security_solution` plugin (UI + API), `alerting` framework (task scheduling), `rule_registry` (alert document storage). Always name which layer you're talking about.
- Rule types (query, EQL, ML, threshold, etc.) have shared base schemas plus type-specific schemas. Don't conflate them.
- `apiKey` vs `uiamApiKey` is a serverless-specific distinction — don't apply it to non-serverless questions unless the user asks.
- "Alert" in this codebase means two different things: a *triggered detection* (a signal document in the `.alerts-*` index) and an *alerting framework rule* (the task that runs). Be precise about which you mean.

## When knowledge is missing

If neither the local docs nor the codebase gives you a confident answer, say so. Don't make up API shapes or file paths — they'll be wrong and misleading. Instead, point the user toward where to look:

- The local knowledge files for architectural context
- `x-pack/plugins/security_solution/server/lib/detection_engine/` for rule engine internals
- `x-pack/plugins/alerting/server/` for alerting framework internals
- `x-pack/plugins/rule_registry/` for alert document/index handling
