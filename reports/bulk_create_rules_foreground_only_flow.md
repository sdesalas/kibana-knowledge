# `bulkCreateRules` — foreground-only, no `backgroundWork`

> Hypothetical refactor where `bulkCreateRules` does **everything in the
> foreground**: Phases 1–5 **and** the work currently in Phases A–D
> (schedule-limit check, `taskManager.bulkSchedule`, demotion of failed rules,
> API-key invalidation flush) all run before the call resolves. There is no
> `backgroundWork` field on the return value.

## Caller pattern

```ts
// Plain serial loop. No thunks, no draining, no floating promises.
const allErrors: RuleError[] = [];
for (const chunk of chunks(rules, 50)) {
  const r = await rulesClient.bulkCreateRules({ rules: chunk });
  allErrors.push(...r.errors); // includes former bgErrors[]
}
```

Per-batch timing assumed:

- Foreground (`fg`) — Phases 1–5 + (formerly background) A–D, all awaited:
  **~2–3s** per batch (`~2.5s` avg).
- No background phase exists. There is no overlap of anything with anything.

The wall-clock model collapses to a single sequence of `fg` blocks.

---

## 1,000 rules → 20 batches of 50

```
        t=0       2.5      5       7.5     10              45      47.5    50 (s)
        │         │        │        │        │       │       │       │       │
batch  1[════ fg ════]
batch  2             [════ fg ════]
batch  3                          [════ fg ════]
batch  4                                       [════ fg ════]
   ...                                                       ...
batch 19                                                            [════ fg ════]
batch 20                                                                 [════ fg ════]
                                                                                  ▲
                                                                                  │
                                                            true completion ≈ 50s

in-flight bg promises (per second):
  always 0 — no detached work exists.

cumulative work resolved (per batch boundary):
  t≈2.5  → batch  1 fully done (rules created + tasks scheduled + keys flushed + demotions persisted)
  t≈5.0  → batch  2 fully done
  …
  t≈50   → batch 20 fully done; system fully quiescent

Wall clock summary
  foreground wall time   : 20 × 2.5s = 50s
  background wall time   : n/a
  total wall time        : 50s        (caller "blocked" the entire time)
  peak parallel bg       : 0
  floating promises      : 0
  errors observed        : 100%  (every batch surfaces fg + former-bg errors in order)
```

Effect on shared services (uniform throughout the run):

```
        ┌──────────────────────────────────────┐  every ~2.5s, exactly one of each:
fg ───▶ │ SO bulkCreate         (~50 rules)   │    1× CREATE audit batch
        │ + CREATE audit                       │    1× ENABLE audit batch
        │ + ENABLE audit                       │    1× scheduled-task count query
        │ + validateScheduleLimit              │    1× taskManager.bulkSchedule
        │ + taskManager.bulkSchedule           │    1× bulkUpdate (only on demotion paths)
        │ + bulkUpdateRuleSo (on demotion)     │    1× DISABLE audit batch (only on demotion)
        │ + DISABLE audit       (on demotion)  │    1× bulkMarkApiKeysForInvalidation
        │ + bulkMarkApiKeys…                   │
        └──────────────────────────────────────┘
```

There is no "phase 1 then phase 2" load shape — every batch hits every
service once before the next batch starts. Load is steady and predictable.

---

## 10,000 rules → 200 batches of 50

```
        ─────────────────── single phase (200 × 2.5s = 500s) ───────────────────
        t=0      2.5      5     …                                          500 (s)
        │         │        │      …                                          │
batch   1[════ fg ════]
batch   2             [════ fg ════]
batch   3                          [════ fg ════]
batch   4                                       [════ fg ════]
   …                                                          (200 lanes, not all shown)
batch 199                                                                [════ fg ════]
batch 200                                                                            [════ fg ════]
                                                                                              ▲
                                                                                              │
                                                                            true completion ≈ 500s

in-flight bg promises (per second):
  always 0.

Cumulative resource usage (entire run)

  foreground wall time             : 200 × 2.5s = 500s
  background wall time             : n/a
  TOTAL wall time                  : 500s        (same as deferred-serial)
  promises launched but never awaited : 0
  peak unresolved bg promises         : 0
  errors observed by caller            : 100%
  total ES write ops (uniformly spread over 500s):
      bulkCreate          : 200       (1 per 2.5s — ~24/min)
      bulkSchedule        : 200       (1 per 2.5s — ~24/min)
      bulkUpdate (worst)  : up to 200 (only on demotion paths)
      apiKey invalidation : up to 200 (only on failure paths)
```

---

## Rule-created → task-scheduled latency

Because every batch is fully resolved before the next starts, the gap between
"rule appears as enabled in SO store" and "task is scheduled in task manager"
is bounded by **a single batch's duration**:

```
gap per rule  : ≤ 2.5s   (whatever portion of fg follows the SO bulkCreate)
gap per batch : ≤ 2.5s
gap across run: 0 — no batch ever waits on a later batch to schedule its tasks
```

Operational consequences:

- **No coverage gap.** A rule that's been reported as created has its task
  scheduled within at most one batch duration.
- **Demotions are immediately persistent.** Rules that fail
  `validateScheduleLimit` or `bulkSchedule` are demoted and the DISABLE audit
  is written before the call returns.
- **Crash blast radius is the smallest of all patterns:** only the in-flight
  batch's work is at risk. Batches already returned are fully durable; future
  batches simply never start.
- **No API-key invalidation backlog.** Soft-fail keys are flushed per batch.

---

## Comparison: four caller patterns

| Dimension                              | Accumulating (current default) | Await-per-batch     | Deferred-serial           | **Foreground-only (this report)** |
|----------------------------------------|--------------------------------|---------------------|---------------------------|-----------------------------------|
| `bulkCreateRules` shape                | returns `backgroundWork` IIFE  | same                | returns `backgroundWork` thunk | no `backgroundWork`, all inline   |
| Total wall (1,000 rules, 20 batches)   | ~22s                           | ~50s                | ~50s                      | **~50s**                          |
| Total wall (10,000 rules, 200 batches) | ~202s                          | ~500s               | ~500s                     | **~500s**                         |
| Peak in-flight `bg`                    | ~2                             | 1                   | 1                         | **0**                             |
| Floating (unawaited) promises          | up to `n`                      | 0                   | 0                         | **0**                             |
| Errors observed by caller              | none (lost)                    | 100%                | 100%                      | **100%**                          |
| Rule-create → task-schedule latency    | ~1–2s                          | ~1–2s               | up to ~300s (10k case)    | **≤ 2.5s (one batch)**            |
| Crash blast radius (worst case)        | ~1–2 batches' bg               | ~1 batch's bg       | up to `n` batches' bg     | **in-flight batch only**          |
| ES load shape                          | bursty 2× during steady state  | strict serial       | bimodal: all-fg, then all-bg | **uniform single-phase**          |
| Return-type complexity                 | `{ …, backgroundWork }`        | same                | same (thunk)              | **flat `{ rules, errors, total }`** |

---

## Why the wall-clock equals deferred-serial but the rest doesn't

`fg-only` and `deferred-serial` both serialize every unit of work. They share
the same `n × (fg + bg) ≈ n × 2.5s` total wall-clock because the same work
runs, one batch at a time. The differences are entirely structural:

- **Deferred-serial** splits the run into two macro-phases (`all-fg`, then
  `all-bg`). This creates the latency gap and the catastrophic crash window
  in between, because every batch's BG depends on the caller reaching the
  drain phase.
- **Foreground-only** keeps each batch's BG glued to its FG. Every batch is a
  self-contained unit of durable progress: when the call returns, every
  rule in that batch is fully scheduled and every error is reported.

If the goal is **strict bounded concurrency + full observability**, this
pattern dominates `deferred-serial` on every dimension except return-type
backwards-compatibility (callers that read `result.backgroundWork` need to
be updated). It also dominates `await-per-batch` slightly by eliminating the
caller-side `await r.backgroundWork` step and the thunk plumbing.

---

## Key takeaways

- **Simplest possible contract** — the call returns when the work is done.
  No thunks, no IIFEs, no detached promises, no caller discipline required.
- **Smallest crash blast radius** of any pattern — only the in-flight batch
  is at risk. Every prior batch is durable.
- **Smallest rule-create → task-schedule latency** — bounded by a single
  batch (≤ 2.5s), not by the size of the import (~300s under deferred-serial
  for 10k rules).
- **Uniform load** on Elasticsearch, task manager, and the audit logger
  throughout the run — no bursty 2× steady state, no bimodal phase shift.
- **Cost:** wall-clock is `n × (fg + bg)`, the same as both serial patterns
  (~500s for 10k rules vs. ~202s today). Worth it whenever the caller is
  going to await the work anyway and doesn't need the current parallelism
  speed-up.
- **Migration shape** is a refactor of `bulkCreateRules` itself, not a
  caller-side change: fold the IIFE body back into the awaited sequence and
  drop `backgroundWork` from the return type. Existing callers that float
  the promise become correct by construction; existing callers that await
  the promise can drop the extra `await`.
