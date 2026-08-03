# Local repro: late rule starts, catch-up, and Gaps

**Date:** 2026-08-03  
**Scope:** Security detection rules — scheduling delay vs in-run catch-up vs recorded Gaps  
**Audience:** Developers validating behaviour locally (manual steps, not Jest/FTR)  
**Architecture deep dive:** [../architecture/rule_gaps_and_catchup.md](../architecture/rule_gaps_and_catchup.md)

---

## Why this exists

When Task Manager starts a detection rule late, the execution log shows
**Scheduling delay**. That is not the same as a **Gap**. The security wrapper
may add catch-up search windows (up to 4 × `interval`) so recent missed time
is still queried; only leftover unqueried time becomes Gap duration / Gaps
table rows.

This report is a hands-on way to see both outcomes:

1. **Delay + no Gap** — catch-up covers the drift  
2. **Delay + Gap** — drift exceeds the catch-up cap  

---

## Prerequisites

- Local ES + Kibana running
- Repo helpers available:

```bash
cd "$(git rev-parse --show-toplevel)"
source scripts/kibana_api_common.sh
# sets KIBANA_URL, KIBANA_AUTH, kibana_curl
```

- Ability to pause the Kibana process (`kill -STOP` / `kill -CONT`) so Task
  Manager cannot run rule tasks for a controlled window

---

## Setup

### 1. Source index

```bash
curl -s -u "${KIBANA_AUTH}" -H 'Content-Type: application/json' \
  -X PUT 'http://localhost:9200/gap-demo' \
  -d '{
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date" },
        "marker": { "type": "keyword" },
        "msg": { "type": "keyword" }
      }
    }
  }'
```

### 2. Detection rule (fast schedule)

Use a **1m** interval so the repro finishes in minutes. The same math applies
to a 5m + 1m lookback rule; only the wall-clock waits change.

```bash
kibana_curl -X POST "$KIBANA_URL/api/detection_engine/rules" \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "gap-demo catchup",
    "description": "manual late-start / catch-up / gap repro",
    "risk_score": 21,
    "severity": "low",
    "type": "query",
    "query": "marker: catchup-test",
    "language": "kuery",
    "index": ["gap-demo"],
    "interval": "1m",
    "from": "now-2m",
    "to": "now",
    "enabled": true,
    "max_signals": 100
  }'
```

Save the returned Saved Object `id` as `RULE_ID`.

### 3. Baseline

Open **Rule details → Execution log**. Wait for **2–3 successful** runs.
Note the last execution start time (`T0`).

Optional customer-mirror schedule (slower):

```json
"interval": "5m",
"from": "now-6m",
"to": "now"
```

---

## Scenario A — scheduling delay, **no Gap**

With `interval=1m` and `from=now-2m` (2m search window):

| Approximate pause | Time between starts | Raw gap | Catch-up | Remaining gap |
|-------------------|---------------------|---------|----------|---------------|
| ~4 minutes after `T0` | ~4m | 4 − 2 = **2m** | `ceil(2/1) = 2` | **0** |

### Steps

1. Find the Kibana Node PID and freeze it so scheduled runs cannot start:

   ```bash
   kill -STOP <kibana_pid>
   ```

2. While frozen, index documents that should only be found if catch-up expands
   the search window:

   ```bash
   NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
   curl -s -u elastic:changeme -H 'Content-Type: application/json' \
     -X POST 'http://localhost:9200/gap-demo/_doc?refresh=true' \
     -d "{\"@timestamp\":\"$NOW\",\"marker\":\"catchup-test\",\"msg\":\"during-pause\"}"
   ```

   Optionally index additional docs with `@timestamp` ~1m and ~2m earlier so
   they land in distinct catch-up windows.

3. Wait until ~4 minutes have passed since `T0`, then resume:

   ```bash
   kill -CONT <kibana_pid>
   ```

4. Watch Rule details → Execution log (and Gaps tab).

### Expected

- Jump in execution start times (skipped schedule slots do **not** get their
  own execution-log rows)
- Next successful run shows **non-zero Scheduling delay**
- **Gap duration empty**; Gaps table has **no** new row for that run
- Alerts for `during-pause` docs appear on that delayed run (catch-up covered
  them), assuming the rule execution succeeded

---

## Scenario B — scheduling delay, **Gap recorded**

Same rule; freeze long enough to exceed `MAX_RULE_GAP_RATIO = 4`:

| Approximate pause | Time between starts | Raw gap | Catch-up | Remaining gap |
|-------------------|---------------------|---------|----------|---------------|
| ~7 minutes after `T0` | ~7m | 7 − 2 = **5m** | `min(5, 4) = 4` | **1m** |

### Steps

Same as Scenario A, but wait ~7 minutes before `kill -CONT`.

### Expected

- Non-zero Scheduling delay
- **Gap duration** ≈ 1 minute (small clock skew is fine)
- Gaps table shows a row
- Event Log contains `event.action: gap` for this rule

---

## Optional: 5m customer-style timings

For `interval: 5m`, `from: now-6m`:

| Outcome | Aim for time between consecutive starts |
|---------|-----------------------------------------|
| Delay, no Gap | ~14 minutes (`gap ≈ 8m`, catch-up `2`, remaining `0`) |
| Delay + Gap | ~35+ minutes (`gap ≈ 29m`, catch-up `4`, remaining > 0) |

---

## Confirmation lookups

Replace `<RULE_ID>` and time bounds as needed.
`kibana.task.schedule_delay` in the Event Log is in **nanoseconds**
(`ms = value / 1e6`).

### 1. Execution results API (same shape as the UI table)

```bash
RULE_ID='<so-id>'

# macOS date; on Linux use: date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%S.000Z
FROM=$(date -u -v-2H +%Y-%m-%dT%H:%M:%S.000Z)
TO=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

kibana_curl -X POST \
  "$KIBANA_URL/internal/detection_engine/rules/${RULE_ID}/execution/results" \
  -H 'Content-Type: application/json' \
  -d "{
    \"filter\": { \"from\": \"${FROM}\", \"to\": \"${TO}\" },
    \"sort\": { \"field\": \"execution_start\", \"order\": \"desc\" },
    \"page\": 1,
    \"per_page\": 20
  }" | jq '.events[] | {
    execution_start,
    schedule_delay_ms,
    gap_s: .metrics.execution_gap_duration_s,
    status: .outcome.status,
    message: .outcome.message,
    alerts: .metrics.alert_counts.new
  }'
```

**Pass criteria:** Scenario A → large `schedule_delay_ms`, `gap_s` null/absent.  
Scenario B → both delay and `gap_s` populated.

### 2. Event Log — execute events

```json
GET .kibana-event-log-*/_search
{
  "size": 20,
  "sort": [{ "@timestamp": "desc" }],
  "query": {
    "bool": {
      "filter": [
        { "term": { "event.provider": "alerting" } },
        { "term": { "event.action": "execute" } },
        { "term": { "rule.id": "<RULE_ID>" } }
      ]
    }
  },
  "_source": [
    "@timestamp",
    "event.start",
    "event.duration",
    "kibana.task.schedule_delay",
    "kibana.alert.rule.execution.metrics.execution_gap_duration_s",
    "kibana.alerting.outcome",
    "message"
  ]
}
```

Discover KQL:

```text
event.provider: alerting and event.action: execute and rule.id: "<RULE_ID>"
```

Useful columns: `kibana.task.schedule_delay`,
`kibana.alert.rule.execution.metrics.execution_gap_duration_s`.

### 3. Event Log — Gap documents (Gaps table source)

```json
GET .kibana-event-log-*/_search
{
  "size": 20,
  "sort": [{ "@timestamp": "desc" }],
  "query": {
    "bool": {
      "filter": [
        { "term": { "event.provider": "alerting" } },
        { "term": { "event.action": "gap" } },
        { "term": { "rule.id": "<RULE_ID>" } },
        {
          "bool": {
            "must_not": [{ "term": { "kibana.alert.rule.gap.deleted": true } }]
          }
        }
      ]
    }
  },
  "_source": [
    "@timestamp",
    "kibana.alert.rule.gap.range",
    "kibana.alert.rule.gap.total_gap_duration_ms",
    "kibana.alert.rule.gap.status",
    "kibana.alert.rule.gap.reason"
  ]
}
```

**Pass criteria:** Scenario A → **0 hits**. Scenario B → ≥1 hit with
`total_gap_duration_ms > 0`.

### 4. Rule SO last-run metrics

```json
GET .kibana_alerting_cases/_search
{
  "size": 1,
  "query": { "term": { "_id": "alert:<RULE_ID>" } },
  "_source": [
    "alert.name",
    "alert.schedule",
    "alert.params.from",
    "alert.params.to",
    "alert.monitoring.run.last_run"
  ]
}
```

After the delayed run, inspect
`monitoring.run.last_run.metrics.gap_duration_s` / `gap_range`.

### 5. Source docs vs alerts (catch-up coverage)

```json
GET gap-demo/_search
{
  "size": 50,
  "sort": [{ "@timestamp": "asc" }],
  "query": { "term": { "marker": "catchup-test" } }
}

GET .alerts-security.alerts-default/_search
{
  "size": 20,
  "sort": [{ "@timestamp": "desc" }],
  "query": {
    "bool": {
      "filter": [
        { "term": { "kibana.alert.rule.uuid": "<RULE_ID>" } },
        { "term": { "marker": "catchup-test" } }
      ]
    }
  },
  "_source": [
    "@timestamp",
    "kibana.alert.original_time",
    "marker",
    "msg",
    "kibana.alert.rule.execution.uuid"
  ]
}
```

**Pass criteria (Scenario A):** pause-window source docs produce alerts on the
**delayed** execution uuid, even though Gap duration is empty.

---

## Mental-math check

From two consecutive execute events (`previousStartedAt`, `startedAt`) and the
rule’s parsed `from`/`to` / `interval`:

```text
gap_s        = (startedAt − previousStartedAt) − (to − from)
catchup      = min(ceil(gap_s / interval_s), 4)
remaining_s  = max(gap_s − catchup × interval_s, 0)
```

- `remaining_s == 0` + large schedule delay → Scenario A (expected, not a Gaps UI bug)
- `remaining_s > 0` → Scenario B (Gap should appear in UI + Event Log)

Code: `getRuleRangeTuples` /
`getGapBetweenRuns` /
`getNumCatchupIntervals` /
`getCatchupTuples` in

`x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/utils/utils.ts`

---

## Cleanup

```bash
kibana_curl -X DELETE "$KIBANA_URL/api/detection_engine/rules?id=${RULE_ID}"
curl -s -u elastic:changeme -X DELETE 'http://localhost:9200/gap-demo'
```

---

## Related

- Primer + wrapper summary: [../architecture/detection-rules-architecture.md](../architecture/detection-rules-architecture.md) §N, §8.1  
- Full algorithm and FAQ: [../architecture/rule_gaps_and_catchup.md](../architecture/rule_gaps_and_catchup.md)
