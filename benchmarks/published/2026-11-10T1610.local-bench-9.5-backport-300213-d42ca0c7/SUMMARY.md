# Local wall bench (14 scenarios): 9.5 backport of #300213 (`d42ca0c7`)

Local-only smoke of [backport PR #304446](https://github.com/elastic/kibana/pull/304446) ([source #300213](https://github.com/elastic/kibana/pull/300213)) on `backport/9.5/pr-300213`. Timed **Action** column only. **Not published for product comparison** — local Mac vs prior ECH #300213 run; absolute seconds are not comparable, ratios are for anomaly spotting.

## Targets

| Label | Target | Build |
|---|---|---|
| **Local 9.5 backport** | `http://localhost:5609/kbn` (`elastic:changeme`) | Kibana `9.5.7` @ `d42ca0c7` (`backport/9.5/pr-300213`) |

APM: `elastic.apm.environment: localhost-kibana-9.5`; intake → `monitoring-cluster-for-local-kibana-develop-d7b1ce`; `transactionMaxSpans: 10000`; `xpack.securitySolution.maxRuleImportPayloadBytes: 26214400`.

Wall-clock window: `2026-11-10T16:10:50Z` → `2026-11-10T16:18:21Z` (`windows.tsv`).

Scripts: `.knowledge/scripts/bulk-primitives/`. Fixtures: `.knowledge/data/rules-import/`. Guide: `guides/detection_rule_wall_bench.md`.

Import flags: `overwrite=true&overwrite_exceptions=true&overwrite_action_connectors=true`.

## Scenarios

| # | Scenario | Related PRs |
|---|---|---|
| 1 | Import → Create 1,000 disabled rules. | 🔴 #275695 |
| 2 | Import → Create 1,000 enabled rules. | 🔴 #275695, 🟠 #290306 |
| 3 | Enable 1,000 existing disabled rules. | 🟤 #291560, 🟠 #290306 |
| 4 | Edit 1,000 enabled rules (add tag). | 🟤 #291560, 🟠 #290306 |
| 5 | Import → Fully update 1,000 enabled rules. | 🟤 #291560, 🟠 #290306 |
| 6 | Import → Update 1 of 1,000 (999 unchanged). | 🟤 #291560, 🟠 #290306, 🟡 #293948 |
| 7 | Disable 1,000 enabled rules. | 🟤 #291560, 🟠 #290306 |
| 8 | Delete 1,000 rules (no gaps). | 🔵 #287065 |
| 9 | Import → Create 1,000 enabled + 1 connector. | 🔴 #275695, 🟠 #290306 |
| 10 | Import → Create 1,000 + 20 shared exception lists (50 items each). | 🔴 #275695, 🟠 #290306 |
| 11 | Import → Update +1 shared list (to 21; 50 items each). | 🟤 #291560, 🟠 #290306 |
| 12 | Import → Update +1 connector (actions only). | 🟤 #291560, 🟠 #290306 |
| 13 | Delete 1,000 rules with gaps. | 🔵 #287065 |
| 14 | Delete 21 shared exception lists (`TYPE=detection`). | 🟢 #285608 |

## Wall-clock results (curl `time_total`)

Compared to ECH PR #300213 run [`2026-11-06T1331…b758fc70`](../published/2026-11-06T1331.full-bench-pr-300213-b758fc70/SUMMARY.md) (local ÷ ECH).

| # | Scenario | Local 9.5 | ECH #300213 | ratio | `rules_summary` / notes |
|---|---|---|---|---|---|
| 1 | Create 1,000 disabled rules | **11.8s** | 18.6s | 0.64x | `created=1000` |
| 2 | Create 1,000 enabled rules | **6.9s** | 19.1s | 0.36x | `created=1000` |
| 3 | Enable 1,000 disabled rules | **6.9s** | 15.5s | 0.45x | `success`, `rules_count=1000` |
| 4 | Edit 1,000 rules (add tag) | **7.5s** | 23.7s | 0.32x | HTTP 200 |
| 5 | Fully update 1,000 enabled rules | **15.6s** | 39.1s | 0.40x | `updated=1000` |
| 6 | Update 1 of 1,000 (999 unchanged) | **2.3s** | 9.6s | 0.24x | `updated=1,skipped=999` |
| 7 | Disable 1,000 enabled rules | **4.7s** | 13.7s | 0.34x | `success`, `rules_count=1000` |
| 8 | Delete 1,000 rules (no gaps) | **3.6s** | 17.5s | 0.21x | `rules_count=1000`; `_find` total → 0 |
| 9 | Create 1,000 enabled + 1 connector | **8.9s** | 28.9s | 0.31x | `created=1000` |
| 10 | Create 1,000 + 20 shared lists | **8.7s** | 29.2s | 0.30x | `created=1000` |
| 11 | Update +1 shared list (to 21) | **48.1s** | 91.6s | 0.53x | `updated=1000` |
| 12 | Update +1 connector | **25.0s** | 54.8s | 0.46x | `updated=1000` |
| 13 | Delete 1,000 rules (with gaps) | **5.3s** | 31.3s | 0.17x | `success`, `rules_count=1000` |
| 14 | Delete 21 shared exception lists | **41.2s** | 6.3s | **6.52x** | bulk API **404** → 21× single DELETE |

## Notes

- API outcomes OK for #1–#13 (create/update/skip and enable/disable/delete counts as above).
- **#14**: `POST /internal/api/exception_lists/_bulk_action` → **404** (`POST unknown route` in APM). Driver fell back to single-list DELETE loop (`succeeded=21`). Matches missing `bulk_delete_exception_list.ts` on 9.5 vs main — bulk exception-list delete orchestrator spans from #300213 are **not** exercised here.
- Console: expected race `SO not found` / `ran after it was disabled` after disable/delete; DEBUG `validateRuleResponseActions` spam from `plugins.securitySolution: debug`. No FATAL after config fix.
- Local APM quirk: `POST …/rules/_import` parent transactions often missing/mis-associated with boot/UI traffic; **child `ruleManagement.*` spans still indexed**. Ignore for import txn links.

## APM transactions

Filter: `service.environment = localhost-kibana-9.5`. Monitoring Kibana: [monitoring-cluster-for-local-kibana-develop-d7b1ce](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com). Range padded `2026-11-10T16:10:00Z` → `2026-11-10T16:19:00Z`. `dropped` field unavailable on this cluster mapping; `spans` = `transaction.span_count.started`.

Import scenarios (#1–2, #5–6, #9–12): no reliable HTTP `_import` txn link (local quirk). Spans observed in-window include `ruleManagement.createPromiseFromRuleImportStream`, `fetchPrebuiltImportContext`, `validateRulesToImport`, `importRuleExceptions`, `importRuleActionConnectors`, etc.

| # | Scenario | APM dur | spans | `trace.id` |
|---|---|---|---|---|
| 3 | Enable 1,000 disabled rules | 6.9s | 3101 | [`bd7df074…`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=localhost-kibana-9.5&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-10T16%3A10%3A00.000Z&rangeTo=2026-11-10T16%3A19%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_bulk_action&traceId=bd7df0747e75f7fe79910764a2c7359b&transactionId=413ab067a0535b54) |
| 4 | Edit 1,000 (add tag) | 7.5s | 3125 | [`7d1ef263…`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=localhost-kibana-9.5&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-10T16%3A10%3A00.000Z&rangeTo=2026-11-10T16%3A19%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_bulk_action&traceId=7d1ef26305161f269944eb1d5b2f5bc6&transactionId=eb379e4f75815b0e) |
| 7 | Disable 1,000 enabled rules | 4.7s | 115 | [`acbccc2f…`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=localhost-kibana-9.5&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-10T16%3A10%3A00.000Z&rangeTo=2026-11-10T16%3A19%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_bulk_action&traceId=acbccc2fd3ac0366d5b2c858f826e48b&transactionId=1cad2c4c82ba2993) |
| 8 | Delete 1,000 (no gaps) | 3.6s | 3093 | [`9f4a1cd7…`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=localhost-kibana-9.5&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-10T16%3A10%3A00.000Z&rangeTo=2026-11-10T16%3A19%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_bulk_action&traceId=9f4a1cd725163d5669f42650388a74e7&transactionId=578158f67ed972ac) |
| 13 | Delete 1,000 (with gaps) | 5.3s | 3093 | [`e36fd87b…`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=localhost-kibana-9.5&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-10T16%3A10%3A00.000Z&rangeTo=2026-11-10T16%3A19%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_bulk_action&traceId=e36fd87bdc74bdabae1f7f2d67af2650&transactionId=2e8a6e6ad0fad97f) |
| 14 | Exception-list bulk (404) then single DELETE | ~0s / ~2s | 2 / 72 | bulk 404 [`df378f66…`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=localhost-kibana-9.5&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-10T16%3A10%3A00.000Z&rangeTo=2026-11-10T16%3A19%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20unknown%20route&traceId=df378f66bf8e07f7f2fcab0cd772b2b1&transactionId=64e047e3d57aa92b); first DELETE [`36bdc6a9…`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=localhost-kibana-9.5&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-10T16%3A10%3A00.000Z&rangeTo=2026-11-10T16%3A19%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=DELETE%20/api/exception_lists&traceId=36bdc6a9ec5df5df866beeb28a51367f&transactionId=380b71e556938f07) |

### Span smoke (enable #3)

On trace `bd7df074…`: `ruleManagement.fetchRulesByQueryOrIds`, `ruleManagement.bulkEnableDisableRules`, `RulesClient.bulkEnableRules`, `bulkEnableRules.toRuleDomain` — present.
