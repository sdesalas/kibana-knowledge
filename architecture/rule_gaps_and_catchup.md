# Rule gaps, catch-up, and late starts

Companion to [detection-rules-architecture.md](./detection-rules-architecture.md)
§N (primer) and §8.1 (wrapper summary).

This doc answers: *when a detection rule starts late, does it still cover the
missed period, and when does the Gaps UI show something?*

Investigation context: SDH / support questions where Hot-node CPU delay
produces a large **scheduling delay** in the execution log but **empty Gap
duration** and an empty Gaps table (e.g. elastic/sdh-security-team#1770).

---

## Vocabulary (do not conflate these)

| Term | Layer | What it is | Where you see it |
|------|-------|------------|------------------|
| **Scheduling delay** | Alerting / Task Manager | How late TM started this run vs the schedule | Execution log "Scheduling delay" |
| **Lookback / `from`→`to`** | Rule schedule params | Normal search window for one on-time run (`from` is usually `interval + lookback`) | Rule Schedule step; defaults e.g. `interval: 5m`, `from: now-6m`, `to: now` |
| **Drift / raw gap** | Security wrapper | `(startedAt − previousStartedAt) − (to − from)` | Internal (`getGapBetweenRuns`) |
| **Catch-up** | Security wrapper | Extra search windows stepped back by `interval`, up to 4 | Extra range tuples in one run (`getCatchupTuples`) |
| **Remaining gap** | Security wrapper | Drift left *after* catch-up | Execution log Gap duration; Gaps table; Event Log `gap_duration_s` / `gap_range` |
| **Backfill / fill_gaps** | Alerting ad-hoc runs | Separate historical re-execution via `ad_hoc_run_params` + TM task | Bulk action `fill_gaps`, gap fill UI |

**One-liner:** scheduling delay explains *when* the task ran; catch-up decides
*how much extra history this run queries*; remaining gap is *what still was
not queried*.

---

## Where it lives in code

Primary file:

`x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/utils/utils.ts`

| Symbol | Role |
|--------|------|
| `MAX_RULE_GAP_RATIO` | Cap on catch-up intervals (`4`) |
| `getGapBetweenRuns` | Raw drift duration |
| `getNumCatchupIntervals` | How many extra windows to add |
| `getCatchupTuples` | Build the stepped-back `{from,to}` windows |
| `getRuleRangeTuples` | Orchestrates the above; returns `tuples`, `remainingGap`, `gap`, `gapReason` |
| `getGapReason` | Classifies remaining gap as `rule_disabled` vs `rule_did_not_run` |
| `calculateFromValue` | Maps UI `interval` + `lookback` → rule `from` string |

Called from:

`.../rule_types/create_security_rule_type_wrapper.ts`

- Pre-execution: `getRuleRangeTuples(...)`
- If `remainingGap > 0`: log error ("signals may have been missed…"), send
  gap telemetry, later write `gap_duration_s` / `gap_range` / `gap_reason`
  via `ruleExecutionLogger.logMetrics`

Unit coverage: `utils.test.ts` (`getGapBetweenRuns`, `getNumCatchupIntervals`,
`getRuleRangeTuples`, `getGapReason`).

---

## Algorithm

Inputs for a run:

- `startedAt` — this execution's start (from the alerting framework)
- `previousStartedAt` — previous successful/attempted start (framework)
- `from` / `to` — rule date-math strings, parsed with `forceNow: startedAt`
- `interval` — schedule interval (e.g. `5m`)
- `lastEnabledAt` — used only for gap *reason* classification

### 1. Normal window

```
originalFrom = dateMath(from, forceNow = startedAt)
originalTo   = dateMath(to,   forceNow = startedAt)
```

Default schedule with 5m interval + 1m lookback → `from: now-6m`, `to: now`,
so `originalTo − originalFrom = 6m`. That 6m is also the **drift tolerance**
used below (the lookback overlap means a slightly late start can still have
zero raw gap).

### 2. Raw gap (drift)

```ts
// getGapBetweenRuns
driftTolerance = originalTo − originalFrom          // e.g. 6m
currentDuration = startedAt − previousStartedAt     // e.g. 14m
gap = currentDuration − driftTolerance              // e.g. 8m
```

- `previousStartedAt == null` → gap `0` (first run / no baseline).
- Negative gap (ran early or lookback overlaps enough) → no catch-up, no
  remaining gap.

### 3. Catch-up count

```ts
// getNumCatchupIntervals
if (gap <= 0 || interval <= 0) return 0
ratio = ceil(gap / interval)
return min(ratio, MAX_RULE_GAP_RATIO)   // MAX = 4
```

So at most **four** consecutive missed intervals are folded into this run as
extra search windows. Anything beyond that becomes remaining gap.

### 4. Catch-up windows

`getCatchupTuples` clones the normal `{from,to}` window and subtracts
`interval` repeatedly:

```
tuple[0] = [originalFrom, originalTo]                 // current window
tuple[1] = [originalFrom − 1×interval, originalTo − 1×interval]
tuple[2] = [originalFrom − 2×interval, originalTo − 2×interval]
…
```

Tuples keep the same lookback **overlap** as normal runs on purpose (EQL /
threshold-style rules need overlapping windows). The executor runs once per
tuple (wrapper "per-tuple" phase). Returned list is reversed so oldest
windows run first.

### 5. Remaining gap (what the product calls Gap)

```ts
remainingGapMs = max(gap − catchup × interval, 0)
```

Only when `remainingGapMs > 0` and `previousStartedAt` is set:

```ts
gap_range = {
  gte: previousStartedAt,
  lte: previousStartedAt + remainingGapMs,
}
```

That range (and `remainingGap`) is what feeds:

- Execution log **Gap duration**
- Gaps table / gap fill UX
- Event Log metrics `gap_duration_s`, `gap_range`, optional `gap_reason`

If catch-up fully covers the drift → `remainingGap = 0` → **empty Gap
duration**, even when scheduling delay was large.

### 6. Gap reason (classification only)

`getGapReason` does not change coverage. It labels a remaining gap:

- `rule_disabled` — rule was re-enabled inside the gap window and then fired
  promptly (within the lookback/drift-tolerance window)
- `rule_did_not_run` — default (TM backlog, outage, overload, etc.)

Gated in the wrapper by `experimentalFeatures.gapReasonDetectionEnabled`.
Known limitation: a brief disable/enable during an unrelated outage can be
misclassified as `rule_disabled`.

---

## Worked example (matches typical support screenshots)

Rule: interval `5m`, lookback `1m` → `from: now-6m`, `to: now`.

Execution log: successful runs at 11:20, 11:25, 11:31, then 11:45 (no
separate 11:35 / 11:40 rows). The 11:45 run shows ~9 minutes scheduling
delay and **empty Gap duration**.

Using `previousStartedAt ≈ 11:31`, `startedAt ≈ 11:45`:

| Step | Value |
|------|-------|
| Time between starts | 14m |
| Drift tolerance (`to − from`) | 6m |
| Raw `gap` | 14 − 6 = **8m** |
| `catchup` | `ceil(8 / 5) = 2` (under the cap of 4) |
| Coverage added by catch-up | 2 × 5m = 10m |
| `remainingGap` | `max(8 − 10, 0) = **0**` |

So this run:

1. Searches the normal last ~6 minutes **plus** two catch-up windows stepped
   back by 5 minutes each (with lookback overlap).
2. Reports scheduling delay (TM was late).
3. Records **no Gap** — catch-up ate the drift.

Missing rows for 11:35 / 11:40 are expected: those schedule slots never got
their own task executions; coverage was merged into the delayed 11:45 run
via catch-up, not as separate execution-log entries.

If the same rule had been delayed much longer — e.g. raw gap of 30m —

| Step | Value |
|------|-------|
| Raw `gap` | 30m |
| `catchup` | `min(ceil(30/5), 4) = 4` |
| Covered by catch-up | 20m |
| `remainingGap` | 10m → **Gap recorded** |

---

## Support / debug checklist

When a customer reports delay without gaps:

1. Confirm rule `interval`, `from`, `to` (or interval + lookback).
2. From Event Log / execution details for the delayed run, note
   `startedAt` and prior run's start (`previousStartedAt`).
3. Compute raw gap and `remainingGap` with the formulas above.
4. If `remainingGap == 0`: explain catch-up vs scheduling delay; expected.
5. If `remainingGap > 0` but Gaps UI empty: check version / feature flags /
   `storeGapsInEventLogEnabled`, space, and time range on the Gaps table —
   that would be a product bug worth filing, not the normal catch-up case.
6. Remind: high ES CPU can still cause **query** failures or partial
   results even when the time window was correct — that shows up as rule
   errors/warnings, not as Gap duration.

---

## Related docs and flags

- Primer + wrapper summary:
  [detection-rules-architecture.md](./detection-rules-architecture.md) §N, §8, §8.1, §17
- Event Log as audit backbone: same doc §O / §2.21
- Experimental: `gapReasonDetectionEnabled` (reason classification);
  gap persistence via alerting `storeGapsInEventLogEnabled`
- Bulk action: `fill_gaps` on
  `POST /api/detection_engine/rules/_bulk_action`
