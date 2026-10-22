# Handoff: full dual-stack bench (30/31 exception lists)

## Context

Steven / Kibana checkout `kibana-7th` (`.knowledge` → `kibana-knowledge`). Next agent must run a **clean full wall-clock bench** of the 14 detection-rule scenarios on ECH **9.5.4 vs main** (2GB Kibana), using the **new** Branch C fixtures (**30 then 31** shared exception lists × **50 items** each), then write a self-contained `SUMMARY.md`. **No APM** unless the user later asks.

## Original dialog

User modified scenarios: drop old rule-default C3/C6; keep 14 scenarios; Branch C = C1–C4.

*Insight: Scenario # ≠ step letter. Run order Branch A→B→C. Timed Action only.*

User: expand exception fixtures so each shared list has **50 items** (was 1).

*Insight: Done earlier; keep 50 items/list when scaling list counts.*

User: run full bench like before; notify at end **and between branches**; SUMMARY before APM; APM main-only B2/C2/C4 — then later **APM not needed**.

*Insight: For this next run: wall-clock + SUMMARY only. Still notify between A/B/C and at end. Skip APM unless asked.*

User: re-run after noticing dirty env — 9.5.4 leftover lists; bulk delete **404** on 9.5.4.

*Insight: Always wipe rules **and** exception lists before starting. `parallel_delete_exception_lists.sh` now falls back to timed single-`DELETE` loop on 404 — use that for pre-wipe and for **C4 compare**.*

User: C4 on 9.5.4 = loop single delete; **compare** to main bulk.

*Insight: C4 timings: `http=single` (9.5.4) vs `http=200` (main). SUMMARY must show both and speedup — not “404 / n/a”.*

User: change C1/C2 fixtures from 5/6 lists → **30/31** lists (same items/list = 50). Update `benchmark-scenarios.md` too.

*Insight: Files renamed to `+30exceptionlists` / `+31exceptionlists` (enabled + disabled). Old `+5`/`+6` removed. C4 deletes **31** lists.*

User: `/handoff` to another agent to do **another full run**.

*Insight: Execute; don’t re-litigate methodology. Follow current `benchmark-scenarios.md`.*

## Conclusions

- Methodology SoT: `.knowledge/demos/benchmark-scenarios.md` (14 scenarios; A1–A8 → B1–B2 → wipe → C1–C4).
- Branch C fixtures (enabled):
  - C1 (#10): `1000enabled.rules+30exceptionlists.ndjson` — **30 lists × 50 items**
  - C2 (#11): `1000enabled.rules+31exceptionlists.ndjson` — **31 lists × 50 items** (`DELETE=0` overwrite)
  - C4 (#14): delete **31** `detection` lists — main bulk vs 9.5.4 single-DELETE loop
- Disabled twins exist (`1000disabled.rules+30/31…`) but Branch C uses enabled.
- Targets: `.knowledge/scripts/bulk-primitives/.env.sh` — ECH **9.5.4** + **main**, both **2GB**. Refresh via QAF if `check_instances` fails; never commit secrets.
- Delete script: `.knowledge/scripts/bulk-primitives/parallel_delete_exception_lists.sh` — on bulk 404 → `mode=single`, summary `http=single`, wall = sum of single DELETE times.
- Driver pattern: copy/adapt prior `run_bench.sh` into **new** `.knowledge/benchmarks/<stamp>.full-bench-954-vs-main/`; ensure IMPORT paths use **+30 / +31** (not +5/+6); C4 note says 31 lists; notify via `/Users/sdesalas/.claude/skills/notify-when-done/scripts/notify.sh` after Branch A, Branch B, and wall-clock DONE.
- Abort gate historically 180s (C1/C2 360s). With 30/31×50 items, C1/C2 will be heavier — keep higher limits or raise further if needed; if a step hangs ≫ expected, stop and ask.
- Launch: Cursor background shell (`block_until_ms: 0`) that stays attached; avoid short nohup wrappers on macOS.
- Last completed wall-clock (old 5/6 fixtures): `benchmarks/2026-10-21T0800.full-bench-954-vs-main/` — **do not cite in new SUMMARY**; self-contained only. Abort/partial: `0757` marked `ABORTED.txt`.
- SUMMARY shape: like 0800/0700 front matter — Targets (2GB), Scenarios (current 30/31 wording), PRs, Endpoints, Methodology, wall table 9.5.4 vs main (Δ, speedup), notes (esp. C4 single vs bulk), References. **No APM section** unless user asks (or leave “APM: not requested”).
- Never mention A2/A3 rename story. Never reference prior run folders in SUMMARY.

## Current state

- Fixtures **ready**: `+30` / `+31` enabled+disabled; verified 30/31 lists, 50 items/list, rules ref all lists.
- Scenarios doc **updated** for 30/31 and C4 single-vs-bulk.
- Delete script **updated** with single-DELETE fallback.
- Instances may still have leftover rules/lists from 0800 C4 leftovers or testing — **wipe both** before next run (rules delete + exception lists; 9.5.4 uses single path automatically now).
- No new bench folder for 30/31 yet — next agent creates stamp and runs.
- APM not required for this handoff task.

## Next session focus

1. `./check_instances.sh` from `bulk-primitives/`; QAF refresh if down.
2. Wipe **rules + exception lists** on both TARGETS (confirm 9.5.4 ends at `lists=0`, not stuck on bulk 404).
3. New results dir `.knowledge/benchmarks/<UTC-stamp>.full-bench-954-vs-main/`; `run_bench.sh` with **+30 / +31** fixtures, C4 = 31 lists, branch notifies, DONE.txt.
4. Run A→B→C to completion. Watch C1/C2 wall on both stacks (heavier than 5/6).
5. Write self-contained `SUMMARY.md` (2GB; 30/31×50 noted; C4 single vs bulk compare with speedup). **No APM** unless user says go.
6. Notify when wall-clock finishes.

## Suggested skills

- `/qaf` — refresh ECH creds if instances down.
- `/notify-when-done` — audible ping between branches and at end (driver already calls `notify.sh`; use skill if notifying from chat).
- `/handoff` — if interrupted mid-bench.

## Artifacts

- Methodology: `.knowledge/demos/benchmark-scenarios.md`
- Scripts: `.knowledge/scripts/bulk-primitives/` (`.env.sh`, `check_instances.sh`, `parallel_*.sh` — note single-delete fallback in `parallel_delete_exception_lists.sh`)
- Fixtures: `.knowledge/data/rules-import/1000enabled.rules+30exceptionlists.ndjson`, `…+31exceptionlists.ndjson` (+ disabled twins)
- Driver template: any recent `benchmarks/*/run_bench.sh` — **must** point at +30/+31 before launch
- SUMMARY shape reference (do **not** cite in new SUMMARY): `.knowledge/benchmarks/2026-10-21T0800.full-bench-954-vs-main/SUMMARY.md`
- Prior handoffs: `.knowledge/handoff/handoff-2026-10-20-2247-rerun-954-main-bench.md`
