# Detection rules telemetry

Companion to [detection-rules-architecture.md](./detection-rules-architecture.md).
For *support* investigations (event log, alerts index, stdout) see
[diagnostic-data-sources.md](./diagnostic-data-sources.md) — that is cluster-local
diagnostics, not phone-home telemetry.

This doc covers **product telemetry** for detection rules: what types exist, why,
how they are collected in code, and sample payloads.

Paths below are repo-relative under `x-pack/solutions/security/plugins/security_solution/`
unless noted.

---

## Map of telemetry types

| Type | Transport | Cadence | Typical question |
|---|---|---|---|
| **1. Usage collector (kibana snapshot)** | `usageCollection` → kibana snapshot phone-home | Periodic cluster stats | What is installed / enabled / customized *right now*? |
| **2. Server-side EBT** | Core `analytics.reportEvent` → `kibana-server` | On action or rule run | Did install / import / upgrade happen? Gap / suppression on a run? |
| **3. Browser-side EBT** | Core `analytics.reportEvent` (UI) → `kibana-browser` | On UI interaction | Did the user open the upgrade flyout / fill gaps / create a rule? |
| **4. UI metrics (`track`)** | `@kbn/analytics` metric counters | On UI action | Coarse enable/disable / bulk-edit counts |
| **5. Security telemetry tasks** | Task Manager → Security telemetry channels (`ITelemetryEventsSender`) | Hourly / daily tasks | Sampled prebuilt-rule *alerts* and exception-list contents for Elastic Security analytics |

---

## Terms

| Term | Meaning |
|---|---|
| **Usage collector / snapshot** | `usageCollection.makeUsageCollector` payload under `stack_stats.kibana.plugins.security_solution` (kibana snapshot phone-home). |
| **EBT (event-based telemetry)** | Discrete typed events via `analytics.reportEvent`. Server events → kibana-server channel; browser events → kibana-browser channel. |
| **`detection_rule_detail`** | Usage-collector array: one row per **Elastic/prebuilt (`immutable`)** rule. Custom rules only appear in aggregates. |
| **Security telemetry channel** | Separate pipeline from snapshot/EBT: scheduled tasks ship filtered documents (e.g. prebuilt alerts) to Elastic Security telemetry endpoints. |
| **Event log** | Cluster-local `.kibana-event-log-*` execution history. Not phone-home telemetry (though the usage collector *reads* it when building status aggregates). |

---
## 1. Usage collector (kibana snapshot)

### What it is

Kibana’s shared `usageCollection` plugin. Security Solution registers one collector:

- **type:** `security_solution`
- **registration:** `server/usage/collector.ts`
- **detection-rules fetch:** `server/usage/detections/rules/get_metrics.ts` (`getRuleMetrics`)
- **payload path:** `detectionMetrics.detection_rules`

Top-level collector keys also include `endpointMetrics`, `dashboardMetrics`,
`riskEngineMetrics`, `exceptionsMetrics`, `valueListsMetrics` — out of scope here
except as siblings on the same collector.

Local refresh:

```
POST kbn:/internal/telemetry/clusters/_stats?apiVersion=2
{ "unencrypted": true, "refreshCache": true }
```

Inspect `stack_stats.kibana.plugins.security_solution.detectionMetrics.detection_rules`.

### Why it exists

Fleet **adoption inventory**: enablement, customization, upgrade backlog, deprecated
counts, per-prebuilt-rule detail — questions that need a whole-cluster point-in-time
document, not a stream of individual actions.

### How it is collected

`getRuleMetrics`:

1. Load detection-rule alert SOs (`usage/queries/get_detection_rules.ts`).
2. Correlate alerts index counts, cases, legacy notifications, event-log status aggs.
3. Map SOs → `RuleMetric` (`transform_utils/get_rule_object_correlations.ts`):
   `elastic_rule` ← `params.immutable`; `is_customized` ← `ruleSource`.
4. Prebuilt assets client: `fetchLatestVersions()` (upgradeability),
   `fetchDeprecatedRules()` (deprecated count).
5. Live SO lookup for base-version presence
   (`usage/queries/get_installed_prebuilt_rule_assets.ts`) — not the persisted
   `rule_source.hasBaseVersion` flag (stale after package changes; clearing base also
   zeroes `customizedFields`).
6. Aggregates + **Elastic-only** `detection_rule_detail`.

On throw: debug log + **zeroed** initial usage (looks like “no rules” in analytics).

### Schema fields (`RuleAdoption`)

| Field | Grain |
|---|---|
| `detection_rule_usage` | Aggregates by type × origin (`query`, `eql`, … + `elastic_total` / `elastic_customized_total` / `elastic_noncustomized_total` / `custom_total`) |
| `detection_rule_detail` | Array of Elastic prebuilt rules only |
| `detection_rule_status` | Event-log derived failure/success/duration/gap metrics |
| `elastic_detection_rule_upgrade_status` | Upgradeable prebuilt counts |
| `elastic_detection_rule_customization_status` | Per-field customization counters (allowlisted fields) |
| `elastic_detection_rule_deprecated_status` | Installed + deprecated asset count |
| `elastic_detection_rule_base_version_status` | Cross-tab customized × has-base-version |
| `elastic_detection_rule_customization_status_missing_base_version` | Per-field customization for rules missing base |
| `ai_created_rules` | `meta.creationSource === 'ai'` |
| `spaces_usage` | Spaces with detection rules |
| `changes_history_usage` | Change-history feature counters |

### Sample shapes

Aggregate (excerpt):

```json
{
  "detection_rule_usage": {
    "elastic_total": { "enabled": 120, "disabled": 40, "alerts": 900, "cases": 12 },
    "elastic_customized_total": { "enabled": 15, "disabled": 3 },
    "custom_total": { "enabled": 8, "disabled": 2 },
    "query": { "enabled": 50, "disabled": 10 },
    "query_custom": { "enabled": 5, "disabled": 1 }
  },
  "elastic_detection_rule_upgrade_status": {
    "total": 12,
    "customized": 4,
    "enabled": 9,
    "disabled": 3
  },
  "elastic_detection_rule_customization_status": {
    "query": 6,
    "severity": 2,
    "index": 3,
    "name": 1
  },
  "elastic_detection_rule_base_version_status": {
    "customized_with_base_version": 10,
    "customized_without_base_version": 2,
    "noncustomized_with_base_version": 100,
    "noncustomized_without_base_version": 1
  }
}
```

Per-rule detail item (excerpt):

```json
{
  "rule_name": "Suspicious Login",
  "rule_id": "some-rule-id",
  "rule_type": "query",
  "rule_version": 42,
  "enabled": true,
  "elastic_rule": true,
  "is_customized": true,
  "has_base_version": true,
  "alert_count_daily": 3,
  "cases_count_total": 0,
  "has_exceptions": false,
  "ai_created": false
}
```

### Schema tooling (`telemetry_check`)

Collector TS `schema` must match `fetch` return type and the stored mapping JSON:

`x-pack/platform/plugins/private/telemetry_collection_xpack/schema/xpack_security.json`
(from `x-pack/.telemetryrc.json`, root `solutions/security`).

```
node scripts/telemetry_check          # validate
node scripts/telemetry_check --fix     # regenerate JSON mappings
```


---
## 2. Server-side EBT

### What it is

Typed events registered in `server/lib/telemetry/event_based/events.ts`, emitted with
`analytics.reportEvent(eventType, payload)` (or helpers that wrap it). Shipped on the
**kibana-server** EBT channel.

Two families for detection rules:

1. **Lifecycle** — install, import, upgrade, duplicate, revert, restore.
2. **Execution** — gap detected, alert suppression on a run.

### Why it exists

Action / run **funnels** and outcomes with small payloads. Complements the usage
collector: an install event is not an inventory; upgrade EBT’s `hasBaseVersion` is
only true at upgrade time, which is why the collector also snapshots base-version
presence.

### How it is collected

| Concern | Code |
|---|---|
| Event type + schema defs | `server/lib/telemetry/event_based/events.ts` |
| Install / import / duplicate | `…/detection_rules_client/rule_lifecycle_telemetry.ts` |
| Upgrade (per-rule + bulk) | `…/prebuilt_rules/api/perform_rule_upgrade/update_rule_telemetry.ts` |
| Restore | changes-history restore path → `DETECTION_RULE_RESTORE_*` |
| Gap | `…/rule_types/utils/telemetry/send_gap_detected_telemetry_event.ts` from `create_security_rule_type_wrapper.ts` |
| Suppression | `…/rule_types/utils/telemetry/send_alert_suppression_telemetry_event.ts` from the same wrapper |

### Lifecycle event types and sample payloads

Shared lifecycle fields (`detection_rule_install` / `_import` / `_revert`):

```json
{
  "ruleId": "alert-so-id-or-rule-uuid",
  "ruleType": "query",
  "isPrebuilt": true,
  "isCustomized": false
}
```

| Event type | When |
|---|---|
| `detection_rule_install` | Prebuilt rules bulk-created from package (`sendRuleInstallTelemetryEvents`) |
| `detection_rule_import` | Rules imported via import API (`sendRuleImportTelemetryEvents`) |
| `detection_rule_revert` | Prebuilt customization reverted |
| `detection_rule_duplicate` | Rule duplicated |

`detection_rule_duplicate` sample:

```json
{
  "ruleId": "new-rule-id",
  "sourceRuleId": "source-rule-id",
  "ruleType": "eql",
  "isPrebuiltSource": true,
  "isCustomizedSource": true
}
```

`detection_rule_upgrade` (one event per upgraded rule):

```json
{
  "ruleId": "some-rule-id",
  "ruleName": "Suspicious Process",
  "hasBaseVersion": true,
  "hasRuleTypeChange": false,
  "finalResult": "SUCCESS",
  "updatedFieldsSummary": {
    "count": 3,
    "nonSolvableConflictsCount": 0,
    "solvableConflictsCount": 1,
    "noConflictsCount": 2
  },
  "updatedFieldsTotal": ["query", "severity", "tags"],
  "updatedFieldsWithNonSolvableConflicts": [],
  "updatedFieldsWithSolvableConflicts": ["query"],
  "updatedFieldsWithNoConflicts": ["severity", "tags"]
}
```

`detection_rule_bulk_upgrade` (one summary per bulk request):

```json
{
  "successfulUpdates": {
    "totalNumberOfRules": 10,
    "numOfCustomizedRules": 2,
    "numOfNonCustomizedRules": 8,
    "numOfNonSolvableConflicts": 0,
    "numOfSolvableConflicts": 1,
    "numOfNoConflicts": 9,
    "numOfRulesWithRuleTypeChange": 0
  },
  "errorUpdates": {
    "totalNumberOfRules": 1,
    "numOfCustomizedRules": 1,
    "numOfNonCustomizedRules": 0,
    "numOfNonSolvableConflicts": 1,
    "numOfSolvableConflicts": 0,
    "numOfNoConflicts": 0,
    "numOfRulesWithRuleTypeChange": 0
  },
  "skippedUpdates": {
    "totalNumberOfRules": 0,
    "numOfCustomizedRules": 0,
    "numOfNonCustomizedRules": 0,
    "numOfNonSolvableConflicts": 0,
    "numOfSolvableConflicts": 0,
    "numOfNoConflicts": 0,
    "numOfRulesWithRuleTypeChange": 0
  }
}
```

`detection_rule_restore` / `detection_rule_restore_error`:

```json
{
  "ruleId": "…",
  "ruleType": "query",
  "isPrebuilt": true,
  "isCustomized": true,
  "restoredRevisionTimestamp": "2026-10-01T12:00:00.000Z"
}
```

```json
{
  "ruleId": "…",
  "changeId": "…",
  "status": "conflict",
  "errorMessage": "…"
}
```

### Execution event types and sample payloads

`gap_detected_event` (remaining gap after catch-up — see [rule_gaps_and_catchup.md](./rule_gaps_and_catchup.md)):

```json
{
  "gapDuration": 300000,
  "intervalDuration": 300000,
  "intervalAndLookbackDuration": 360000,
  "ruleType": "query",
  "ruleSource": "external",
  "isCustomized": false,
  "gapReasonType": "…"
}
```

`alert_suppression_on_rule_execution` (only if suppression configured and
created+suppressed &gt; 0; custom rule names redacted to `"Custom rule"`):

```json
{
  "suppressionAlertsCreated": 2,
  "suppressionAlertsSuppressed": 15,
  "suppressionRuleName": "Elastic rule name or Custom rule",
  "suppressionDuration": 3600,
  "suppressionGroupByFieldsNumber": 2,
  "suppressionGroupByFields": ["host.name", "user.name"],
  "suppressionRuleType": "query",
  "suppressionMissingFields": true,
  "suppressionRuleId": "rule-id"
}
```

(`suppressionDuration` is seconds; `-1` means per-rule-execution suppression.)


---
## 3. Browser-side EBT

### What it is

UI events registered under `public/common/lib/telemetry/events/`, reported via the
Security Solution telemetry service (`telemetry.reportEvent`). Same Core analytics
pipeline as server EBT; source stream is **kibana-browser**.

### Why it exists

Product analytics on **user intent in the UI** (opened flyout, clicked upgrade,
started fill-gaps, AI rule creation session) — including actions that never hit a
server lifecycle event (dismissed callout, abandoned creation).

### How it is collected

Events are declared as `{ eventType, schema }` objects and registered with the UI
telemetry plugin. Call sites use `useKibana().services.telemetry.reportEvent(...)`.

### Detection-rule-related event types and sample payloads

#### Rule upgrade UI (`events/rule_upgrade/`)

| Event type string | Sample payload |
|---|---|
| `Click Rule Upgrade Flyout Button` | `{ "type": "update", "hasBaseVersion": true, "eventVersion": 1 }` |
| `Click Rule Upgrade Single Button` | `{ "hasBaseVersion": false }` |
| `Open Rule Upgrade Flyout` | `{ "hasBaseVersion": true, "eventVersion": 1 }` |

#### Rule creation / edit UI (`events/rule_creation/`)

| Event type string | Sample payload |
|---|---|
| `Rule Creation Initialized` | `{ "creationSource": "ai", "sessionId": "…" }` |
| `AI Rule Applied to Form` | `{ "ruleType": "esql", "sessionId": "…", "durationSinceSessionStartMs": 1200 }` |
| `Rule Created` | `{ "creationSource": "manual", "sessionId": "…", "ruleType": "query", "enabled": true, "numberOfAiEdits": 0, "threatTechniques": ["T1059"], "durationSinceSessionStartMs": 5000 }` |
| `Rule Edited` | `{ "creationSource": "ai", "sessionId": "…", "ruleType": "query", "enabled": true, "numberOfAiEdits": 2, "durationSinceSessionStartMs": 8000 }` |
| `Rule Creation Error` | `{ "creationSource": "ai", "sessionId": "…", "ruleType": "esql", "errorMessage": "…", "numberOfAiEdits": 1, "durationSinceSessionStartMs": 3000 }` |
| `Rule Creation Abandoned` | `{ "creationSource": "ai", "sessionId": "…", "ruleType": "query", "numberOfAiEdits": 1, "durationSinceSessionStartMs": 2000 }` |

#### Manual run / gaps UI (`events/manual_rule_run/`, `events/bulk_fill_rule_gaps/`)

| Event type string | Sample payload |
|---|---|
| `Manual Rule Run Open Modal` | `{ "type": "single" }` |
| `Manual Rule Run Execute` | `{ "rangeInMs": 86400000, "rulesCount": 1, "status": "success" }` |
| `Manual Rule Run Cancel Job` | `{ "totalTasks": 10, "completedTasks": 3, "errorTasks": 0 }` |
| `Fill Gap` | `{ "rangeInMs": 3600000 }` |
| `Fill Remaining Gap` | `{ "rangeInMs": 7200000 }` |
| `Filter Gaps` | `{ "status": "unfilled" }` |
| `Show Only Rules With Gaps` | `{ "dateRange": "…" }` |
| `Bulk fill rule gaps Open Modal` | `{ "type": "bulk" }` |
| `Bulk fill rule gaps Execute` | `{ "rangeInMs": 86400000, "rulesCount": 5, "status": "error" }` |

#### Deprecation UI (`events/rule_deprecation/`)

All take `{ "count": N }`:

- `Deprecated Rules Callout Shown`
- `Deprecated Rules Callout Dismissed`
- `Deprecated Rules Modal Opened`
- `Deprecated Rules Modal Rule Link Clicked`
- `Deprecated Rules Delete All Clicked`
- `Deprecated Rule Delete Clicked`
- `Deprecated Rule Duplicate And Delete Clicked`

#### Changes history UI (`events/rule_changes_history/`)

| Event type string | Sample payload |
|---|---|
| `Open Rule Changes History` | `{}` |
| `Open Rule Changes History Diff` | `{ "isPrebuiltRule": true }` |
| `Restore Rule From Changes History` | `{ "status": "success", "ruleType": "query", "isPrebuilt": true, "isCustomized": true, "isConflictRetry": false }` |

#### Preview (`events/preview_rule/`)

| Event type string | Sample payload |
|---|---|
| `Preview rule` | `{ "ruleType": "eql", "loggedRequestsEnabled": false }` |

#### Event log UI (`events/event_log/`)

| Event type string | Sample payload |
|---|---|
| `Event Log Filter By Run Type` | `{ "runType": ["scheduled", "manual"] }` |
| `Event Log -> Show Source -> Event Date Range` | `{ "isVisible": true }` |

(Other browser EBT under `public/common/lib/telemetry/events/` covers Attack Discovery,
SIEM migrations, entity analytics, etc. — related products, not core detection-rule CRUD.)


---
## 4. UI metrics (`track` / `TELEMETRY_EVENT`)

### What it is

Lightweight counters via `track(METRIC_TYPE.*, TELEMETRY_EVENT.*, count?)` in
`public/common/lib/telemetry/` (`constants.ts`, `track.ts`). Older / coarser than
typed EBT schemas.

### Why it exists

Historical UI instrumentation (enable/disable, bulk edit suppression, value lists).
Still fired from rule management bulk actions and similar.

### Detection-rule-related constants

From `TELEMETRY_EVENT`:

- `siem_rule_enabled` / `siem_rule_disabled`
- `custom_rule_enabled` / `custom_rule_disabled`
- `set_alert_suppression` / `set_alert_suppression_for_threshold` / `delete_alert_suppression`
- `add_investigation_fields` / `set_investigation_fields` / `delete_investigation_fields`
- `open_assistant_on_rule_query_error`

(Also ML job enable/disable siblings in the same enum.)

### Sample

No rich payload — metric name + type + optional count:

```ts
track(METRIC_TYPE.COUNT, TELEMETRY_EVENT.SIEM_RULE_ENABLED);
track(METRIC_TYPE.COUNT, TELEMETRY_EVENT.CUSTOM_RULE_DISABLED);
```


---
## 5. Security telemetry tasks (alert / list channels)

### What it is

Task Manager jobs under `server/lib/telemetry/tasks/` that pull data via
`ITelemetryReceiver` and ship batches through `ITelemetryEventsSender` onto **Security
Solution telemetry channels** (not kibana snapshot, not Core EBT).

Detection-rule-related tasks:

| Task type | Interval | What it sends |
|---|---|---|
| `security:telemetry-prebuilt-rule-alerts` | ~1h | Allowlisted fields from **prebuilt / Elastic ML alert** documents (`createTelemetryPrebuiltRuleAlertsTaskConfig`) |
| `security:telemetry-detection-rules` | ~24h | Exception-list items attached to detection rules (`createTelemetryDetectionRuleListsTaskConfig`) |

### Why it exists

Elastic Security analytics on **alert contents** and **exception usage** for prebuilt
detections — richer document samples than snapshot counters, with field allowlists /
filterlists for privacy.

### How it is collected

- Task configs: `server/lib/telemetry/tasks/prebuilt_rule_alerts.ts`,
  `server/lib/telemetry/tasks/detection_rule.ts`
- Filterlists: `server/lib/telemetry/filterlists/prebuilt_rules_alerts.ts`
- Sender / receiver: `server/lib/telemetry/sender.ts`, `receiver.ts`

### Sample

Not a fixed small EBT schema — batched alert (or list) documents with allowlisted
fields, plus cluster/license context from the receiver. Shape follows the allowlist
and channel contract more than a single `EventTypeOpts`.


---

## Choosing a type (quick)

| Question | Prefer |
|---|---|
| How many clusters have prebuilt rules enabled? | Usage collector |
| Which fields are customized fleet-wide? | Usage collector customization aggregates |
| How many installs / imports this week? | Server EBT `detection_rule_install` / `_import` |
| Upgrade conflict rates? | Server EBT `detection_rule_upgrade` / `_bulk_upgrade` |
| Did users open the upgrade flyout? | Browser EBT rule-upgrade events |
| Gap volume after catch-up? | Server EBT `gap_detected_event` (+ [rule_gaps_and_catchup.md](./rule_gaps_and_catchup.md)) |
| Suppression effectiveness on runs? | Server EBT `alert_suppression_on_rule_execution` |
| Sample of alert documents from Elastic rules? | Security telemetry task `telemetry-prebuilt-rule-alerts` |
| Why did *this* rule miss a document on *this* cluster? | Not phone-home — [diagnostic-data-sources.md](./diagnostic-data-sources.md) |

---

## Key files

| Path | Role |
|---|---|
| `server/usage/collector.ts` | Registers `security_solution` usage collector |
| `server/usage/detections/rules/get_metrics.ts` | Detection-rules snapshot |
| `server/usage/detections/rules/schema.ts` | Collector schema for `telemetry_check` |
| `server/usage/queries/get_installed_prebuilt_rule_assets.ts` | Live base-version lookup |
| `server/lib/telemetry/event_based/events.ts` | Server EBT type defs |
| `…/rule_lifecycle_telemetry.ts` | Install / import / duplicate sends |
| `…/update_rule_telemetry.ts` | Upgrade sends |
| `…/send_gap_detected_telemetry_event.ts` | Gap EBT |
| `…/send_alert_suppression_telemetry_event.ts` | Suppression EBT |
| `public/common/lib/telemetry/events/**` | Browser EBT for rules UI |
| `public/common/lib/telemetry/constants.ts` | `TELEMETRY_EVENT` metric names |
| `server/lib/telemetry/tasks/prebuilt_rule_alerts.ts` | Prebuilt alerts channel task |
| `server/lib/telemetry/tasks/detection_rule.ts` | Detection-rule lists channel task |
| `x-pack/.telemetryrc.json` | → `xpack_security.json` |
| `scripts/telemetry_check.js` | Validate / `--fix` snapshot schemas |

---

## Related

- [detection-rules-architecture.md](./detection-rules-architecture.md)
- [diagnostic-data-sources.md](./diagnostic-data-sources.md)
- [rule_gaps_and_catchup.md](./rule_gaps_and_catchup.md)
