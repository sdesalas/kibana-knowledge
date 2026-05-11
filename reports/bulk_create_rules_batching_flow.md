# `bulkCreateRules` — accumulating `backgroundWork` across batches

Caller pattern (worst case for accumulation):

```ts
for (const chunk of chunks(rules, 50)) {
  const r = await rulesClient.bulkCreateRules({ rules: chunk });
  // r.backgroundWork is NEVER awaited → promise floats
}
```

Per-batch timing assumed:

- Foreground (`fg`) — Phases 1–5 awaited by caller: **~1s** per batch.
- Background (`bg`) — Phases A–D detached: **~1–2s** per batch.

Because `fg < bg`, a new batch's `bg` starts before the previous batch's `bg`
has resolved. In-flight `bg` promises accumulate up to the steady-state
concurrency `ceil(bg / fg) ≈ 2`.

---

## 1,000 rules → 20 batches of 50

```
            t=0   1   2   3   4   5   6   7   8        18  19  20  21  22 (s)
            │   │   │   │   │   │   │   │   │   │   │   │   │   │   │
batch  1    [fg][═════ bg ═════]
batch  2        [fg][═════ bg ═════]
batch  3            [fg][═════ bg ═════]
batch  4                [fg][═════ bg ═════]
batch  5                    [fg][═════ bg ═════]
batch  6                        [fg][═════ bg ═════]
   ...                              ...
batch 19                                                [fg][═════ bg ═════]
batch 20                                                    [fg][═════ bg ═════]
                                                                ▲                 ▲
                                                                │                 │
                                                  caller's last await returns      │
                                                  (perceived "done" at t≈20s)      │
                                                                                   │
                                                            true completion ~t≈22s ┘

in-flight bg promises (per second):
t (s):     0  1  2  3  4  5  6  7  8  …  18  19  20  21  22
count:     0  0  1  2  2  2  2  2  2  …   2   2   2   1   0
                  └──────────── steady state ≈ 2 ────────────┘

cumulative bg launched: 0 → 1 → 2 → 3 → 4 → … → 18 → 19 → 20
cumulative bg resolved: 0 → 0 → 0 → 1 → 2 → … → 16 → 17 → 18 → 19 → 20

Wall clock summary
  total foreground time     : 20 × 1s   = 20s   (caller "blocked")
  total background workload : 20 × 1.5s = 30s   (work done)
  peak parallel bg          : 2
  pending bg at fg-finish   : 1–2 promises (total ~1–2s of work left)
  perceived speed-up        : 30s of work compressed into ~22s wall clock
```

Effect on shared services during the steady state (t ∈ [2, 20]):

```
        ┌──────────────────────┐         per second, 2× concurrent bg means 2×:
fg ───▶ │ bulkCreateRulesSo    │           - validateScheduleLimit ES queries
        │ + CREATE/ENABLE audit│           - taskManager.bulkSchedule writes
        └──────────────────────┘           - bulkUpdateRuleSo demotions (if any)
                                           - bulkMarkApiKeysForInvalidation
bg ───▶ A → B → C → D                      - DISABLE audits (if any)
```

---

## 10,000 rules → 200 batches of 50

```
                        ── warmup ──   ── steady state, ~2 bg in flight ──   ── drain ──
            t=0  1  2  3        …                  …                 200  201  202 (s)
            │   │  │  │                                                │    │    │
batch   1   [fg][═══ bg ═══]
batch   2       [fg][═══ bg ═══]
batch   3           [fg][═══ bg ═══]
batch   4               [fg][═══ bg ═══]
   …                              (200 lanes, only first 4 + last 2 shown)
batch 199                                                              [fg][═══ bg ═══]
batch 200                                                                  [fg][═══ bg ═══]
                                                                               ▲             ▲
                                                                               │             │
                                                                 caller "done" at t≈200s     │
                                                                                             │
                                                                       true completion ~t≈202s

in-flight bg promises (per second):
t (s):    0    1    2    3    4   …   198  199  200  201  202
count:    0    0    1    2    2   …    2    2    2    1    0

Cumulative resource usage if NOTHING is awaited

  foreground wall time            : 200 × 1s   = 200s
  total background workload       : 200 × 1.5s = 300s of work done
                                    (executes in parallel with itself, ~2×)
  promises launched but never awaited : 200
  peak unresolved bg promises at any time : ~2
  worst-case extra wall time after caller returns : ~1–2s
  total ES write ops (rough, 2× concurrent):
      bulkCreate          : 200
      bulkSchedule        : 200
      bulkUpdate (worst)  : up to 200      ← only on demotion paths
      apiKey invalidation : up to 200      ← only on failure paths
```

---

## Key takeaways

- `bg` does **not grow unboundedly** — each promise self-resolves in ~1–2s, so steady-state in-flight count is bounded at `≈ ceil(bg / fg) = 2`.
- What **does** "accumulate":
  1. **Floating promise references** — 200 unawaited `backgroundWork` promises for the 10k case. If any throws inside a `try` not covered by the IIFE's catch-all, you get an `unhandledRejection`. The current code prevents that by wrapping the IIFE.
  2. **Errors** — every batch's `bgErrors[]` is dropped on the floor unless you awaited it. Demotions (`schedule_limit_exceeded`, `task_schedule_failed`, `task_schedule_entry_failed`) are silently lost from the caller's perspective.
  3. **Audit + ES load** — `~2× concurrent` writes to SO store, task manager, and audit logger throughout the run.
  4. **Time-to-true-completion** — caller perceives `n × fg` (e.g. 200s) but the system isn't quiescent until `n × fg + bg` (e.g. ~202s). For long-running scripts this gap is small in absolute terms; for short scripts that exit immediately after the loop it can drop the last 1–2 batches' background work entirely if the process tears down.
- To bound load: either await `backgroundWork` per batch (turns `fg+bg` serial — ~50s/200×2.5s = 500s total), or batch-await every N iterations (e.g. `await Promise.all(pending)` every 10 batches) to cap unresolved promises.
