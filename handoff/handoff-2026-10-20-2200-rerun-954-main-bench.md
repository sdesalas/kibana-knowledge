# Handoff: re-run import-rules bench (9.5.4 vs main) + APM B2/C2/C5

## Context

Steven / Kibana repo `kibana-7th`. Re-run the 15 detection-rule wall-clock scenarios on ECH **9.5.4** vs **main**, then APM-dig **B2 (#13)**, **C2 (#11)**, **C5 (#15)** (user said “B3” — there is no B3; that is **B2** add-connector). Methodology is in `.knowledge/demos/benchmark-scenarios.md` (updated this session).

## Decision / Current state

- Methodology: Branches A→B→C; **run order = table order**. Branch A steps renumbered: **A2=#3 enable**, **A3=#2 create enabled** (scenario # ≠ step letter).
- Scripts/fixtures: `.knowledge/scripts/bulk-primitives/` + `.knowledge/data/rules-import/`. `.env.sh` already has both ECH TARGETS (refresh via QAF if stale). Do not commit secrets.
- Prior dual-stack run: `benchmarks/2026-10-20T1752.full-bench-performance-optimizations/`. Main-only 15k-span re-run + APM: `benchmarks/2026-10-20T1855.full-bench-main-15kspans/` (complete SUMMARY with B2/C2/C5 tips).
- Main `transactionMaxSpans` was raised **5k→15k**; B2 then `started≈11431 dropped=0`. Prefer complete traces for ranking.
- **Heads-up — expect APM shape similar to 1855 SUMMARY**, not a blank slate:
  - **B2:** authz `_has_privileges` N+1, `_mget` / `prepareUpdate`, API-key invalidate+grant on connector add; skip-unchanged N/A (all 1000 change). Wall ~45–50s both stacks last dual run (flat).
  - **C2:** `_bulk` + authz + `resolve capabilities` + space GET N+1 + key churn on exception-only update; keys shouldn’t rotate if actions/enabled unchanged.
  - **C5:** ~20s/batch × ~11; 🚨 per-list `DELETE …/exception-list` (~1s×100) — bulk SO delete is the tip; 9.5.4 may **404** the bulk API.
  - Run-to-run wall Δ vs prior main often = span-cap/completeness + variance; don’t over-read n-counts from incomplete traces.

## Next session focus

1. `./check_instances.sh`; wipe rules (+ lists) on both; run A→B→C per methodology on **both** TARGETS (parallel scripts). Single run OK. Record under new `.knowledge/benchmarks/<stamp>.…/` (`timings.tsv`, UTC windows, logs).
2. Wait ~2–3 min after timed ops; `/apm-investigation` on B2/C2/C5 (and biggest wall deltas). Raise/confirm `transactionMaxSpans` (≥15k) if drops appear.
3. Write findings into that results folder SUMMARY (self-contained; light emoji OK). Reuse 1855 tips as hypotheses to confirm/deny — don’t paste blindly if shape differs.

## Artifacts

- `.knowledge/demos/benchmark-scenarios.md`
- `.knowledge/scripts/bulk-primitives/` (`.env.sh`, `parallel_*.sh`, `check_instances.sh`)
- `.knowledge/benchmarks/2026-10-20T1752.full-bench-performance-optimizations/SUMMARY.md`
- `.knowledge/benchmarks/2026-10-20T1855.full-bench-main-15kspans/SUMMARY.md` ← prior B2/C2/C5 APM
- `.knowledge/skills/apm-investigation/SKILL.md` · `~/config/apm.creds`
- `.knowledge/skills/qaf/SKILL.md`
