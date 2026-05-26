# `bulkCreateRules` — deferred, serial `backgroundWork`

> Hypothetical refactor where `backgroundWork` is **not** auto-started inside
> `bulkCreateRules`. The IIFE is replaced by a returned **thunk** the caller
> must invoke. The caller's pattern is: run **all foreground batches first**,
> then drain the thunks **one at a time** in series.

## Caller pattern

```ts
// 1. Foreground pass — collect deferred work, never start it.
const deferred: Array<() => Promise<BackgroundWorkResult>> = [];
for (const chunk of chunks(rules, 50)) {
  const r = await rulesClient.bulkCreateRules({ rules: chunk });
  deferred.push(r.backgroundWork); // thunk, NOT a running promise
}

// 2. Background pass — run sequentially, await each, surface errors.
const allBgErrors: BgError[] = [];
for (const run of deferred) {
  const { bgErrors } = await run();
  allBgErrors.push(...bgErrors);
}
```

Per-batch timing assumed (unchanged from the accumulating model):

- Foreground (`fg`) — Phases 1–5 awaited by caller: **~1s** per batch.
- Background (`bg`) — Phases A–D run by the caller: **~1–2s** per batch (`~1.5s` avg).

There is **no overlap** between `fg` and `bg` anywhere, and **no overlap**
between two `bg` runs. Steady-state in-flight `bg` promises = **1**.

---

## 1,000 rules → 20 batches of 50

```
        ───────────── FG pass (20 × 1s) ─────────────  ─────────── BG pass (20 × 1.5s) ───────────
        t=0   1   2   3   4         18  19  20      21      23      25            48      50 (s)
        │   │   │   │   │   │   │   │   │   │       │       │       │   │   │   │       │
batch  1[fg]                                        [═══ bg ═══]
batch  2    [fg]                                                [═══ bg ═══]
batch  3        [fg]                                                        [═══ bg ═══]
batch  4            [fg]                                                            [═══ bg ═══]
   ...                  ...                                                                 ...
batch 19                                        [fg]                                            [═══ bg ═══]
batch 20                                            [fg]                                                [═══ bg ═══]
                                                    ▲                                                           ▲
                                                    │                                                           │
                                          last fg returns at t≈20s                                              │
                                          (caller starts draining)                                              │
                                                                                                                │
                                                                                            true completion ~t=50s
in-flight bg promises (per second):
t (s):  0  1  2  …  19  20  21  22  23  24  25  …  48  49  50
count:  0  0  0  …   0   0   1   1   1   1   1  …   1   1   0
                                    └─── steady state = 1 (strict serial) ───┘

cumulative bg launched : 0 … 0 → 1 → 2 → 3 → … → 19 → 20    (one per ~1.5s)
cumulative bg resolved : 0 … 0 → 0 → 1 → 2 → … → 18 → 19 → 20

Wall clock summary
  foreground wall time      : 20 × 1s     = 20s
  background wall time      : 20 × 1.5s   = 30s
  total wall time           : 50s          (≈ +28s vs accumulating model)
  peak parallel bg          : 1
  floating promises         : 0
  bg errors observed        : 20 batches' bgErrors[] (all surfaced, in order)
```

Effect on shared services:

```
phase 1 (t ∈ [0, 20]):  ONLY foreground load
  ┌──────────────────────┐  per second:
  │ bulkCreateRulesSo    │    1× SO bulkCreate
  │ + CREATE/ENABLE audit│    1× CREATE audit batch + 1× ENABLE audit batch
  └──────────────────────┘    1× minted API keys (≤50)

phase 2 (t ∈ [20, 50]):  ONLY background load
  ┌──────────────────────┐  every ~1.5s:
  │ validateScheduleLimit│    1× scheduled-task count query
  │ taskManager.bulkSched│    1× bulkSchedule (≤50 tasks)
  │ bulkUpdateRuleSo     │    1× demotion bulkUpdate (only on failure)
  │ bulkMarkApiKeys…     │    1× API-key invalidation flush
  │ DISABLE audit (opt.) │    1× DISABLE audit batch (only on demotion)
  └──────────────────────┘
```

---

## 10,000 rules → 200 batches of 50

```
        ───────────── FG pass (200 × 1s = 200s) ─────────────  ──────── BG pass (200 × 1.5s = 300s) ────────
        t=0  1  2  …               198 199 200             201.5         …                            500 (s)
        │   │  │  …                │   │   │                 │                                          │
batch   1[fg]                                                [═ bg ═]
batch   2   [fg]                                                    [═ bg ═]
batch   3       [fg]                                                       [═ bg ═]
   …                                                                              …
batch 199                                                  [fg]                                       [═ bg ═]
batch 200                                                      [fg]                                       [═ bg ═]
                                                                ▲                                              ▲
                                                                │                                              │
                                                      last fg returns at t≈200s                                │
                                                      (caller starts draining)                                 │
                                                                                                               │
                                                                                            true completion ~t=500s

in-flight bg promises (per second):
t (s):  0   1   …  199 200  201  202   …  498  499  500
count:  0   0   …   0   0    1    1    …   1    1    0
                            └────── steady state = 1 ──────┘

Cumulative resource usage (entire run)

  foreground wall time             : 200 × 1s    = 200s
  background wall time             : 200 × 1.5s  = 300s
  TOTAL wall time                  : 500s        (≈ 2.5× the accumulating model's 202s)
  promises launched but never awaited : 0
  peak unresolved bg promises         : 1
  bg errors observed by caller        : 100%       (every batch's bgErrors[] is awaited)
  total ES write ops:
      bulkCreate          : 200       (concentrated in [0, 200])
      bulkSchedule        : 200       (concentrated in [200, 500])
      bulkUpdate (worst)  : up to 200 (concentrated in [200, 500], only on demotion paths)
      apiKey invalidation : up to 200 (concentrated in [200, 500], only on failure paths)
```

---

## The hidden cost: rule-created → task-scheduled latency

Because `bg` is deferred until **after all** foreground batches finish, every
rule sits in the SO store as **enabled but unscheduled** for the entire gap.
The task is only created when its batch's thunk runs in the drain phase.

```
batch i created at  : t = (i − 1) × 1s    .. i × 1s
batch i scheduled at: t = 200 + (i − 1) × 1.5s .. 200 + i × 1.5s     (10k case)

Latency batch i → task scheduled (10,000 rules / 200 batches):

  batch   1:  ~200s gap   (created t≈1,    scheduled t≈201)
  batch  50:  ~225s gap   (created t≈50,   scheduled t≈275)
  batch 100:  ~250s gap   (created t≈100,  scheduled t≈350)
  batch 150:  ~275s gap   (created t≈150,  scheduled t≈425)
  batch 200:  ~300s gap   (created t≈200,  scheduled t≈500)

  → mean ~250s, max ~300s per rule (vs. ~1–2s today)
```

Operational consequences during the gap:

- **Detection coverage gap** — rules are visible in the UI/API as enabled, but
  no task is running, so they do not execute on their configured interval
  until much later. Users may believe their rules are live when they are not.
- **No demotion has happened yet** — rules that would fail
  `validateScheduleLimit` are still listed as enabled. They will be silently
  demoted minutes later, after they appear to have been "live" for the gap.
- **Crash semantics worsen** — if the process dies between phase 1 and the end
  of phase 2:
  - **Accumulating model (today):** worst case loses ~1–2 batches' bg work
    (the in-flight tail).
  - **Deferred-serial model:** can lose **all** queued bg work — up to 200
    batches → 10,000 rules with no tasks and no demotions persisted, no API
    keys cleaned up.
- **API key inventory grows** — invalidation flushes are deferred for up to
  ~5 minutes (10k case), so any keys minted then immediately abandoned (e.g.
  bulkCreate 409 conflicts) stay in the to-invalidate queue that long.

---

## Comparison: three caller patterns

| Dimension                             | Accumulating (current default, no await) | Deferred-serial (this report)   | Await-per-batch                  |
|---------------------------------------|------------------------------------------|---------------------------------|----------------------------------|
| Caller code                            | `await bulkCreateRules(...)`             | collect thunks, drain serially  | `await r.backgroundWork`         |
| Total wall (1,000 rules, 20 batches)   | ~22s                                     | ~50s                            | ~50s                             |
| Total wall (10,000 rules, 200 batches) | ~202s                                    | **~500s**                       | ~500s                            |
| Peak in-flight `bg`                    | ~2                                       | **1**                           | 1                                |
| Floating (unawaited) promises          | up to `n`                                | **0**                           | 0                                |
| Errors observed by caller              | none (lost)                              | **100%**                        | 100%                             |
| Rule-create → task-schedule latency    | ~1–2s                                    | up to **~300s** (10k case)      | ~1–2s                            |
| Crash blast radius (worst case)        | ~1–2 batches' bg                         | **up to `n` batches' bg**       | ~1 batch's bg                    |
| Steady-state ES write rate             | 2× (fg + 2× bg overlap)                  | 1× (one phase at a time)        | 1× (strict serial)               |

---

## Key takeaways

- **Bounded resource use** is the win: peak `bg` concurrency is exactly **1**,
  zero floating promises, every `bgErrors[]` is observable in order.
- **Wall-clock cost** is `n × (fg + bg)` instead of `≈ n × fg + bg`, i.e. the
  10k run takes ~500s instead of ~202s — **2.5× longer**.
- **Correctness cost** is the dangerous one: rules live in the store
  unscheduled for up to ~300s (10k case). For detection-rules workflows this
  is a coverage gap users won't see, and a crash during the drain phase loses
  every still-queued task schedule + demotion + API-key invalidation.
- This pattern is functionally equivalent to `await-per-batch` on wall time
  and `bg` concurrency, but **strictly worse** on crash blast radius and the
  rule-created → task-scheduled latency. Prefer await-per-batch (or
  `Promise.all(pending)` every N batches) if the goal is just to bound `bg`.
- Deferred-serial only makes sense if the caller's contract requires
  **strict phase separation** — for example, when a downstream system must
  observe all SO writes before any task is scheduled (e.g. a freeze/replay
  window, or a bulk-import flow that wants to validate the imported set
  before any rule starts running). In that case, the latency is the feature,
  not the bug.
