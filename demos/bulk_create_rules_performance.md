# `rulesClient.bulkCreate()` — Performance Journey
### [elastic/kibana#264893](https://github.com/elastic/kibana/issues/264893)

---

## Slide 1 — Stakes: Why This Mattered

- OOM during prebuilt rule installation was a recurring incident pre-9.4
- 9.4 BC: crashes on ~1600 rules in smaller ECH instances
- Prebuilt rule installation became the **canary in the coalmine** for Kibana memory health at scale

---

## Slide 2 — First Attempt: The POC

- [PR #264371](https://github.com/elastic/kibana/pull/264371) — built quickly (LLM-assisted) as a proof-of-concept for "native" bulk install
- Only supported **disabled** rules — simpler, no API key minting or task scheduling needed
- Did not meaningfully improve memory footprint
- **Rejected by ResponseOps:** a proper `bulkCreate()` had to handle both enabled and disabled rules
- That constraint is where the real complexity lives

---

## Slide 3 — Baseline & The Problem Shape

- 1800 disabled rules (install): ~95s
- 1000 enabled rules (import): ~65s local / ~110s ECH
- Root cause: ~1500 individual `rulesClient.create()` calls → O(n) ES writes, API key mints, task schedules

---

## Slide 4 — Attempts #1 & #2: Batching Helps (Partly)

- **[#1 — PR #266713](https://github.com/elastic/kibana/pull/266713):** Batch SO writes + task schedules, 50 rules per batch
  - Disabled: 95s → 22s ✅ (4-5x)
  - Enabled: no gain ❌ — 50x concurrent individual creates was faster
- **[#2 — PR #268133](https://github.com/elastic/kibana/pull/268133):** Prefetch all connector actions up-front (1 call vs 2-3 per rule)
  - Enabled: ~2x improvement ✅
  - Bottleneck shifting: API key generation (CPU) + connector validation (TCP latency)

---

## Slide 5 — Attempt #3: The Wrong Turn That Taught Us Something

- Hypothesis: move task scheduling to a **background promise** so HTTP response returns faster
- Foreground: create rule SOs → return to caller
- Background: mint API keys, schedule tasks, flip failures to disabled
- Problem: rules returned as "enabled" before tasks exist — state inconsistency window
- Did not significantly help wall-clock time; complexity cost was high
- **Worth noting:** this detour shows what happens when you optimise without constraints

---

## Slide 6 — Attempt #4: The Breakthrough

- **Observation:** log noise — while inserting enabled tasks, TM output was flooding the console, making rule creation logs hard to read
- **Insight:** enabling tasks mid-batch triggers immediate execution — running tasks contend on `.kibana_alerting_cases*` / `.kibana_task_manager` during subsequent batches → progressive slowdown
- **Fix:** move `taskManager.bulkEnable` to **once, at the end** of the full request

`[screenshot: Kibana console with TM task noise interleaved during batch creation]`

- TM scheduling time: from **30s (ECH) / 60s (local) cumulative across batches → ~1s total**
- Disabled: 95s → 21s ✅ | Enabled: 65s → 21s local / 110s → 42s ECH ✅

---

## Slide 7 — Attempts #5 & #6: API Shape Matters

- **[#5 — PR #269043](https://github.com/elastic/kibana/pull/269043):** Standalone `bulkCreate()` with `skipTaskEnabling` flag — caller collects task IDs, calls `bulkEnableTasks()` once at the end. Flexible but easy to misuse.
- **[#6 — PR #269340](https://github.com/elastic/kibana/pull/269340):** ResponseOps feedback forced the API cleaner:
  - Batching moved **inside** the method (not the caller's problem)
  - Validation-first: fail fast before any ES writes
  - Return only rule `id` — not full rule objects (eliminates large per-batch allocations)
  - Exit-early on error; best-effort cleanup
  - **The complexity detour of #3–#5 shows the value of external review as a forcing function**

---

## Slide 8 — Results

| | Baseline | After | Gain |
|---|---|---|---|
| 1800 disabled rules (install) | ~95s | ~21s | **4-5x** |
| 1000 enabled rules (import, local) | ~65s | ~21s | **3x** |
| 1000 enabled rules (import, ECH) | ~110s | ~42s | **2.5x** |
| TM enable step (accumulated across batches) | 30–60s | ~1s | **~30-60x** |

---

## Slide 9 — What I Got Wrong

*(ordered by impact)*

---

### Miss #1 — Best-effort: demote-to-disabled on failure

The assumption was that a rule that can't be scheduled should still be inserted as `disabled` — better something than nothing.

It was wrong. Demotion logic bled into every layer: API key cleanup, task removal, SO update on failure. It was the single largest source of complexity across all 6 attempts. And it bought nothing — the public rule import API contract can't surface a "partially enabled" state, and the UI has no concept for it. The user would never have seen the benefit. I should have checked that constraint first.

---

### Miss #2 — Cross-team: composing disabled bulk create + bulk enable as two calls

The assumption was that splitting `bulkCreate` (disabled only) from `bulkEnable` into two methods would be clean and save significant effort. Enabling rules is roughly 3× the complexity of creating disabled ones.

This wasn't a design mistake — it was a cross-team constraint I didn't surface early enough. ResponseOps correctly rejected it: they're responsible for Observability and Stack rules, not just Security Solution, and a `bulkCreate` that doesn't handle enabled rules isn't one. If that conversation had happened before attempt #1, the attempt count would probably have been 1–2, not 6.

---

### Miss #3 — Returning the full rule object

The assumption was to mirror what single `create()` returns — the full rule. That's the existing contract; callers use it.

At batch scale it's a GC problem. Five attempts carried this forward before ResponseOps flagged it in attempt #6. The rule `id` is all that's needed — it maps back to the input, and the caller already knows everything else. I was pattern-matching to the wrong API.

---

### Miss #4 — Interleaving validation with per-rule processing

The assumption was to validate each rule inline as part of its processing — fail as you go, same as single `create()` does.

It made partial failure cleanup much harder. Doing a clean up-front validation pass first — before any ES writes — is strictly better. ResponseOps recommended it. It costs one extra cheap pass (UUID generation + action transform repeated), but eliminates the need to unwind half-written state. I should have structured it that way from the start.

---

### Miss #5 — Trusting local performance numbers

The breakthrough numbers looked strong locally. ECH told a different story — greater latency on uploads, less available memory, and because ES and Kibana run on separate machines in ECH (not shared like locally), the TM contention pattern showed up differently. The local win looked bigger than it was.

The lesson: run in ECH earlier. Local is good for fast iteration; conclusions need ECH to hold up.

---

## Slide 10 — Takeaways

1. **Batching alone isn't the lever — ordering is.** When you enable tasks determines how much they compete with the work still in flight. Moving `bulkEnable` to the end cut TM scheduling time from 30–60s to ~1s.
2. **A necessary detour:** background scheduling (attempt #3) looked like the answer. It wasn't. The ordering fix made it unnecessary.
3. **Surface cross-team constraints before writing code.** The 2-call composition question should have been a 30-minute conversation before attempt #1, not a rejection at attempt #3.
4. **It took 6 attempts because the problem is genuinely hard.** Distributed system tradeoffs — concurrency vs batching, foreground vs background, API surface vs caller flexibility — don't have obvious answers.
5. **External review (ResponseOps) produced a better API** than pure performance chasing would have. The complexity detour of attempts #3–#5 ended cleanly only because someone else enforced a constraint.
