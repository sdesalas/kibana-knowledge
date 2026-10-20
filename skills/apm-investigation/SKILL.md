---
name: apm-investigation
description: >-
  Hypothesis-driven APM investigation after a heavy HTTP/API operation: account
  for wall-clock time, dig into surprises with ad-hoc queries, and rank
  optimization candidates by union wall-clock impact — single deployment or
  compare the same endpoint across two environments. Use when the user invokes
  /apm-investigation, asks to investigate or compare APM hotspots, or wants
  impact-sorted candidates from a monitoring traces-apm* cluster after they
  already ran the operation(s).
disable-model-invocation: true
---

# APM Investigation

Investigate APM **after** the user has already run the target operation(s).
Deliver optimization candidates ranked by **union wall-clock impact** on total
request duration — one deployment, or the same transaction across two
environments (baseline vs PR, old vs new, local vs cloud).

## Stance: you are investigating, not checklisting

Scripts and the pattern catalog are **accelerators and vocabulary**, not the
investigation. Unexpected problems will not match a pre-written label. Your job
is to explain where the wall-clock went and why — including surprises.

**Do:**
- Form hypotheses from gaps, odd span names, phase timing, parent trees, compare deltas
- Run ad-hoc ES|QL / `_search` / small Python when scripts don’t answer the question
- Dig into the top few mysteries (parents, siblings, start offsets, sampling of docs)
- Invent a new Pattern label when the catalog doesn’t fit; say what you saw
- Read application code **only** to attribute a high-impact hotspot (name the
  function/path). Do not start fixing unless the user asks

**Don’t:**
- Stop after pasting script output
- Only report rows that match the catalog
- Treat low-% noise as equal to critical-path cost
- Ignore unexplained time (“txn 30s but top spans only account for 12s”)

## Investigative loop

Repeat until the ranked list is honest and the biggest costs are explained:

1. **Frame** — endpoint, scenario (create / skip / update / …), single vs compare,
   time window, env identity fields.
2. **Observe** — find txn(s); note duration, started/dropped; run a first-pass
   union ranking (script or equivalent).
3. **Account for time** — does the sum of major phase unions roughly cover the
   txn? If a large slice is unexplained, that gap **is** a finding — dig
   (unnamed work, dropped spans, work outside named spans, mis-windowed query).
4. **Hypothesize** — for each top cost or anomaly: N+1? serial? skip-path waste?
   something new? Write the guess in one line.
5. **Probe** — parent.id walk, filter by span name prefix, sample timestamps
   along the txn, compare A vs B for the same name, check whether high **sum**
   is parallel (low union) or truly hot. Use custom queries freely.
6. **Revise** — promote/demote candidates; merge related spans; drop red herrings
   (side-effect spam with tiny union).
7. **Deliver** — impact-sorted list + short “why” per top item. Catalog labels
   when they fit; free-text Pattern when they don’t.

## When this skill triggers

- `/apm-investigation`
- `/apm-investigation <endpoint> <time window>`
- `/apm-investigation compare …`
- “investigate APM for …”, “compare APM between …”, “rank APM hotspots”

## Session bootstrap (always first)

Hard path: **`~/config/apm.creds`** (chmod 600, never commit).

On the **first** use of this skill in the conversation:

1. If `~/config/apm.creds` is **missing**, create it with this sample, then **stop**:

```bash
mkdir -p ~/config
cat > ~/config/apm.creds <<'EOF'
# Monitoring Elasticsearch for APM traces (edit me)
APM_ES_URL=https://YOUR-MONITORING-ES.example.com
APM_ES_USER=agent
APM_ES_PASSWORD=change-me
APM_INDEX=traces-apm*
EOF
chmod 600 ~/config/apm.creds
```

2. **Tell the user** (add a link if possible so they can click to the file):
   “Please edit `~/config/apm.creds` with your monitoring ES URL, username, and
   password, then say when I should continue. I recommend you create a new user
   that can be disabled in that cluster while this skill is not used.”

3. If the file exists, check for leftover placeholders (`YOUR-MONITORING-ES`,
   `change-me`). If still sample → same stop + ask them to edit.

4. Validate with a cheap curl health check (source the file first):

```bash
set -a && source ~/config/apm.creds && set +a
curl -sS -u "$APM_ES_USER:$APM_ES_PASSWORD" "${APM_ES_URL%/}/_cluster/health"
```

5. If auth/network fails → **tell the user** the check failed and ask them to
   fix `~/config/apm.creds` (stale password / wrong URL are common). Re-validate
   after they say it’s updated.

`APM_INDEX` defaults to `traces-apm*` when unset. Analysis scripts read
`~/config/apm.creds` (or `APM_*` already in the environment).

**Identity fields:** cloud deployments often use `labels.deploymentName` and/or
`service.environment`; local may only have `service.environment` / `host.hostname`.
Ask which filter fits if discovery returns nothing.

## Entry modes

User already ran the op(s). Then pick one:

### A. Discover (single or multi-env)

Inputs: endpoint / path fragment, rough time window, optional env/hostname filters.

Run `scripts/find_transactions.py`. Present candidates: time, name, duration,
`trace.id`, started/dropped, **environment / deployment**. Ask which to analyze
(default: longest).

For compare prep, pass two envs as CLI flags (`--env-a` / `--env-b`) so the list
is grouped per side.

### B. Direct (single)

Inputs: one `trace.id` (and/or exact txn name + window). Analyze that trace.

### C. Compare (two environments) — first-class

Same endpoint / scenario run on **two** deployments (or two windows). Goal: what
changed in wall-clock shape, and where the win/loss is.

1. Discover (or accept) **one representative txn per side** — same route, comparable
   scenario (e.g. both create, or both 1-change re-import). Note durations +
   started/dropped for each.
2. Run `scripts/compare_traces.py --trace-a … --trace-b …` (labels optional).
3. Deliver:
   - Header: duration A vs B, speedup, dropped-span warnings per side
   - Table of span candidates sorted by **|Δ union wall|** or **Δ % of txn**
     (biggest absolute impact first), with n/union/% for A and B
   - What got better / worse / new / gone
   - 3–5 top actions on the **slower** side (or on the regression if B is worse)

Do **not** treat compare as “run single analysis twice and paste both.” Merge and
rank by cross-env impact.

## Dropped spans — stop and warn

After selecting each transaction, read `transaction.span_count.dropped`.

If dropped is high (rough guide: **>100** or **dropped >> started**):

1. Surface a clear warning with emojis, e.g.
   `🚨 APM dropped N spans (started=X, dropped=Y) — this trace is incomplete.`
2. Prefer raising `elastic.apm.transactionMaxSpans` in `kibana.dev.yml` (or
   equivalent), restart, **re-run the operation**, then re-invoke this skill.
3. Only continue on incomplete data if they explicitly cannot reproduce. Say so.

In **compare** mode, warn **per side**. If only one side is capped, say so —
cross-env call-count comparisons are misleading when dropped differs a lot.

## First-pass analysis

Start with (scripts help; equivalent queries are fine):

1. Page spans for the trace / window.
2. Rank by **union wall** of `[start, start+duration]` per `span.name`
   (group related names when that tells a clearer story).
3. Use **sum** and **count** as secondary signals (parallelism / N+1 shape).
4. Attribute top rows with `parent.id`; don’t double-count parent+child.
5. Label Pattern from the catalog **or** a better name you invent from evidence.

`analyze_transaction.py` / `compare_traces.py` are a strong first pass — not the
finish line. After they run, spend effort on: unexplained duration, weird top
names, compare-only-on-one-side spans, and anything whose count or timing
doesn’t match the user’s scenario (e.g. “skipped 1000 rules” but still huge writes).

If the HTTP txn doc is missing but a long `route handler` matches curl wall time,
analyze that window. Keep this fallback brief.

### Useful probes

- **Phase split:** time from txn start → first domain span vs rest (e.g. exceptions
  before rules).
- **Name families:** prefix/`LIKE` groups (`Elasticsearch: POST /_bulk`, `*.prepare*`).
- **Parent histogram** for a hot span name — who calls it?
- **Start-offset histogram** under one parent — ordered stages vs pure parallel.
- **Presence vs absence** in compare mode — span only on slow side is often the story.
- **Max/p95 single span** — one outlier bulk vs many steady calls.
- **Correlation with API outcome** — created/updated/skipped counts vs what APM did.

Write new probes if the data and investigation results ask for them.

## Candidate pattern catalog

Known shapes worth recognizing. Not a closed list but some patterns to be aware of.
Prefer the most specific label that fits; otherwise describe the shape in Pattern.
Cost should scale predictably with input size; hot-path work should be deliberate.

### Call shape / N+1

| Pattern | What it looks like in APM |
| --- | --- |
| **N+1 ES/HTTP** | Same call × hundreds/thousands (`_has_privileges`, per-item `_update_by_query`, per-doc get) |
| **Missing bulk** | Loop of singles where `_bulk` / `mget` / `msearch` / `bulkSchedule` should exist |
| **Unbounded fan-out** | Huge parallel `pMap` / many siblings with no obvious concurrency cap |

### Wall time vs parallel work

| Pattern | What it looks like |
| --- | --- |
| **Serial / critical path** | Few spans, union ≈ sum, large % of txn (e.g. sequential `_bulk`s) |
| **Parallel fan-out** | High **sum**, much lower **union** — already parallel; optimize **count/payload**, not single-call latency |
| **Double-counted work** | Parent+child are the same work (`createAPIKey` + `api_key/grant`) — don’t add unions |

### Skip / noop / overwrite waste

| Pattern | What it looks like |
| --- | --- |
| **Skip-path waste** | API says skipped/unchanged but heavy spans still run (exceptions overwrite, connectors, asset fetches) |
| **Missing noop short-circuit** | Full rewrite of unchanged entities (no equality / hash bailout) |

### Batching & payload

| Pattern | What it looks like |
| --- | --- |
| **Batch too small** | Many medium round-trips that could be fewer larger bulks |
| **Batch too large** | One giant `_bulk` dominating; possible payload/mapping pain |
| **Fat write payload** | Slow bulks with oversized docs / change-history bloat |

### Authz / security / keys

| Pattern | What it looks like |
| --- | --- |
| **Authz N+1** | Repeat per/item authentication, such as `_has_privileges` / Fleet / Endpoint authz |
| **Cache opportunity** | Identical privilege/authz bursts; request-scoped cache would collapse them |
| **API-key churn** | Mass `createAPIKey` / `grant` / invalidate on paths that don’t need new keys |

### Scheduling & side effects

| Pattern | What it looks like |
| --- | --- |
| **Per-item schedule** | `taskManager.schedule` × N instead of `bulkSchedule` |
| **Side-effect noise** | EBT / usage-counters / telemetry `_bulk` spam — often low wall, high span count |
| **Irrelevant subsystem** | Cases/connector/search traffic when the fixture has none |

### Read amplification

| Pattern | What it looks like |
| --- | --- |
| **Repeated fetches** | Same prebuilt/asset/config fetch per batch instead of once per request |
| **Search amplification** | Repeated `_search` / `_mget` for the same lookups |

### Code-shaped (APM hints; confirm in code if top-ranked)

| Pattern | What it looks like |
| --- | --- |
| **Nested loops / linear scan** | Wall grows worse than linear with input; APM alone can’t prove O(n²) — flag if suspected |
| **Sequential await** | Independent work chained (union of phase A then B with no overlap) |
| **Missing bounds** | Huge result sets / imports with no cap (often config: payload bytes, max import size) |

### Instrumentation caveats (not product wins)

| Pattern | What it looks like |
| --- | --- |
| **Dropped spans** | High `span_count.dropped` — incomplete; prefer higher `transactionMaxSpans` + re-run |
| **Asymmetric completeness** | Compare where one side dropped far more — don’t trust call-count deltas |

**Usually out of scope on a single request txn:** lifecycle leaks (subs/intervals).

## Output contract

Lead with what you concluded, not raw script dumps.

### Single

1. Txn identity + duration + started/dropped (+ 🚨 if incomplete)
2. Time accounting in 1–3 sentences (where the seconds went / what’s unexplained)
3. Table sorted by union wall / % of txn
4. 3–5 top actions — evidence-backed, biggest first

| Rank | Candidate | Union wall | % of txn | n | Pattern | Why |
| --- | --- | --- | --- | --- | --- | --- |

### Compare

1. Duration A→B + speedup + per-side dropped warnings
2. What changed in the shape (better / worse / new / gone)
3. Delta table sorted by `|Δ union|`
4. Top remaining costs on the slower side (or regression drivers)

| Candidate | A union (% / n) | B union (% / n) | Δ union | Pattern | Note |
| --- | --- | --- | --- | --- | --- |

## Non-goals

- Orchestrating fixtures / delete / import / load generation
- Storing secrets in the repo or skill tree
- Implementing code fixes (unless user asks after the ranked list)
- Browser APM UI as the *only* tool (ES API preferred; UI ok for sanity)

## Scripts (optional accelerators)

Use when helpful; replace or extend with custom queries anytime.

| Script | Purpose |
| --- | --- |
| `find_transactions.py` | List candidate txns (optional `--env-a` / `--env-b`) |
| `analyze_transaction.py` | First-pass union-wall ranking for one `trace.id` |
| `compare_traces.py` | First-pass side-by-side delta for two `trace.id`s |

Creds: only `~/config/apm.creds` (no helper scripts).
