# PR #275695 closeout — what's left to merge

Context: [PR #275695](https://github.com/elastic/kibana/pull/275695) reworks
`POST /api/detection_engine/rules/_import` create path onto
`rulesClient.bulkCreateRules()`. Feature flag and legacy path are gone; the
rewrite is the only path. Review is still `CHANGES_REQUESTED` from banderror.

This note is the priority list for closing the PR — not a full review triage.
Secondary review leftovers (telemetry, dead `RuleSourceImporter`, thread
hygiene) can wait if needed.

---

## Priority 1 — Add FTR coverage ([#280531](https://github.com/elastic/kibana/issues/280531))

- [#280553](https://github.com/elastic/kibana/pull/280553) adds the missing FTR coverage for `rules/_import` against `main`
- Can land independently of the perf matrix — run both in parallel
- #275695 cannot merge until this one has landed
- Once it does, re-run the critical cases against this branch to confirm the rewrite doesn't regress the contract

---

## Priority 2 — Re-run the perf matrix (ECH + local)

Need both environments: local alone understates network/upload cost; ECH alone can't raise the 10MB payload cap cleanly (breaks Kibana start), so 2000-rule runs may need a local override or leaner fixture

### Dimensions

| Dimension | Values |
|---|---|
| Environment | ECH (1GB Kibana) · Local |
| Rule count | 1000 · **2000** |
| Enabled state | disabled · enabled |
| Batch size | **100 · 200 · 250 · 300 · 500** |

- Enabled and disabled are separate runs — they stress different code (API keys + task scheduling vs create-only)

### Full matrix (fill cells: wall time / heap range / container peak)

#### Disabled rules

| Batch | Local 1000 | Local 2000 | ECH 1000 | ECH 2000 |
|------:|:----------:|:----------:|:--------:|:--------:|
| 100 | | | | |
| 200 | | | | |
| **250** | | | | |
| **300** | | | | |
| 500 | | | | |

#### Enabled rules

| Batch | Local 1000 | Local 2000 | ECH 1000 | ECH 2000 |
|------:|:----------:|:----------:|:--------:|:--------:|
| 100 | | | | |
| 200 | | | | |
| **250** | | | | |
| **300** | | | | |
| 500 | | | | |

That's **40 runs** (2 envs × 2 counts × 2 states × 5 batch sizes). If time is
tight, cut order:

1. ECH × 1000 × enabled/disabled × {100, 250, 300, 500} — decide the constant
2. Local × 2000 × enabled/disabled × {250, 300} — confirm the pick scales
3. Fill the rest for the record

### How to run (reminder)

```yml
# kibana.dev.yml — local only; do not set payload overrides on ECH
xpack.alerting.ruleChangeTracking.enabled: true
# bump past 10MB only locally when testing 2000 rules:
# xpack.securitySolution.maxRuleImportPayloadBytes: <bytes>
```

Flip `RULE_IMPORT_BULK_CREATE_BATCH_SIZE` between runs (or temporarily wire a
config override if you add one). Capture:

- Wall time from the import UI / request
- Heap range + container peak from Stack Monitoring (ECH) or process metrics (local)
- Correctness spot-check via `check-tasks.sh` (rule/task/api_key counts)

- banderror explicitly asked for **2000 enabled + 2000 disabled** and a range up to 500 (CHANGES_REQUESTED review on the PR, 2026-07-13) — still outstanding

---

## Priority 3 — Nail the batch size

- Current constant: `RULE_IMPORT_BULK_CREATE_BATCH_SIZE = 100` (`rule_management/api/constants.ts` on the PR branch)
- Earlier ECH runs (1000 rules, 1GB Kibana) showed little wall-time difference across 200 / 350 / 500, with heap starting to climb at 500 on the enabled path
- Gut feel: **sweet spot is ~250–300**, but never measured directly — jumped 200 → 350 → 500 then dropped to 100 without re-running the matrix
- Leave the constant alone until there's evidence; treat batch size as **not decided**

---

## Secondary (nice-to-have before merge, not blockers)

These came up in review triage. Do them if cheap; don't hold the batch-size /
description work for them.

| Item | Why secondary |
|---|---|
| Emit `DETECTION_RULE_IMPORT_EVENT` from bulk `importRules` | Real telemetry gap, but not what reviewers are waiting on for the rewrite itself |
| Resolve outdated GitHub review threads | Hygiene — banderror still needs to re-review either way |
| changeTracking "other parameters?" thread | Route already passes `action` + `bulkCount`; waiting on reviewer clarification |

---

## Suggested close order

1. Run the perf matrix (at least cut #1 + #2 above)
2. Set `RULE_IMPORT_BULK_CREATE_BATCH_SIZE` to the winner, paste table into PR
3. Re-request review from banderror (Georgii)
4. Land / verify #280553, then merge #275695
5. Sweep secondary items if still open
