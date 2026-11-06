# Full bench (19 scenarios): PR #300213 (`b758fc70`, 9.7.0-SNAPSHOT)

Single run of **nineteen** detection-rule performance scenarios on Elastic Cloud Hosted (**PR-only** — same deploy as the morning 14-scenario run). Timed **Action** column only (seed steps not timed). Scenarios **#1–#14** keep the same seed → timed action as prior published runs; **#15–#19** are new audit paths for [#298304](https://github.com/elastic/kibana/issues/298304) / [#298305](https://github.com/elastic/kibana/issues/298305). This doc is self-contained.


## Targets

**2GB Kibana** (`sdesalas3_security_oom_testing`, `gcp-us-west2`).
Plan knobs: `xpack.siem.maxRuleImportPayloadBytes: 26214400` (25 MiB); `elastic.apm.transactionMaxSpans: 15000`; APM env = deployment name; APM intake → `monitoring-cluster-for-local-kibana-develop-d7b1ce`.

| Label | Deployment | Build |
|---|---|---|
| **PR #300213** | `sdesalas.pr.300213.import-apm` (`sdesalas-pr-300213-import-apm-3dfe03.kb.us-west2.gcp.elastic-cloud.com`) | Kibana `9.7.0` @ `b758fc7023fb1ca6337fa41082581d2c68c5b461` (`kibana-cloud-pr:9.7.0-SNAPSHOT-b758fc70…`) |

Wall-clock window: `2026-11-06T13:32:04Z` → `2026-11-06T13:49:27Z` (per-step UTC in `windows.tsv`).

Scripts: `.knowledge/scripts/bulk-primitives/` (`parallel_import_rules.sh`, `parallel_bulk_action.sh` with `SELECT=ids` / `IDS_LIMIT`, `parallel_seed_gaps.sh`, `parallel_seed_alerts.sh`, `parallel_delete_exception_lists.sh`). Fixtures: `.knowledge/data/rules-import/`. Guide: `guides/detection_rule_wall_bench.19scenarios.md`.

Import flags on every import: `overwrite=true&overwrite_exceptions=true&overwrite_action_connectors=true`.

Exception fixtures for C1/C2: each shared list has **50 items**. C2 is a strict list-superset of C1.


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
| 15 | Enable 1,000 rules (mix of disabled + already-enabled). | 🟤 #291560, 🟠 #290306 |
| 16 | Re-enable 1,000 rules that were enabled before (kept `scheduledTaskId`). | 🟤 #291560, 🟠 #290306 |
| 17 | Enable 1,000 rules with connectors. | 🟤 #291560, 🟠 #290306 |
| 18 | Delete 1,000 rules by `ids` (no gaps). | 🔵 #287065 |
| 19 | Delete 1,000 rules with active alerts. | 🔵 #287065 |

## PRs and impact

### `POST /api/detection_engine/rules/_import`

| PR | Impact |
|---|---|
| 🔴 [#275695](https://github.com/elastic/kibana/pull/275695) | Routes new rule imports through `bulkCreateRules()` instead of per-rule creation. |
| 🟤 [#291560](https://github.com/elastic/kibana/pull/291560) | Routes overwrite imports through `bulkUpdateRules()` and batches enable/disable transitions. |
| 🟠 [#290306](https://github.com/elastic/kibana/pull/290306) | Uses `refresh=false` for bulk API-key grants. |
| 🟡 [#293948](https://github.com/elastic/kibana/pull/293948) | Skips unchanged rules during overwrite imports. |

### `POST /api/detection_engine/rules/_bulk_action`

| PR | Impact |
|---|---|
| 🔵 [#287065](https://github.com/elastic/kibana/pull/287065) | Batches gap cleanup during rule deletion using `_update_by_query`. |

### Exception-list delete

| PR | Impact |
|---|---|
| 🟢 [#285608](https://github.com/elastic/kibana/pull/285608) | Adds `POST /internal/api/exception_lists/_bulk_action` (C4). |


## Endpoints

| Endpoint | Scenarios |
|---|---|
| `POST /api/detection_engine/rules/_import` | 1–2, 5–6, 9–12 |
| `POST /api/detection_engine/rules/_bulk_action` | 3–4, 7–8, 13, 15–19 |
| `POST /internal/api/exception_lists/_bulk_action` | 14 |


## Methodology (how this run was executed)

Scenario **#** is the scenario id. Rows below are **execution order**. Time only the **Action** column. Single repetition (n=1).

### Branch A — baseline + new enable paths

| Step | # | Seed | Action (timed) | Fixture / body |
|---|---|---|---|---|
| A1 | 1 | clean | Import | `1000disabled-rules.ndjson` |
| A2 | 3 | after A1 | `_bulk_action` enable | `{"action":"enable","query":""}` |
| A2b | 15 | disable 500 by `ids` | enable (mix) | seed: `SELECT=ids IDS_LIMIT=500`; timed enable |
| A2d | 16 | disable all | enable (re-enable) | hits `scheduledTaskId` / `taskManager.get` path |
| A3 | 2 | clean (`DELETE=1`) | Import | `1000enabled-rules.ndjson` |
| A4 | 4 | after A3 | edit `add_tags: ["bench"]` | |
| A5 | 5 | reseed #2 | Import overwrite | `…all-updated.ndjson` |
| A6 | 6 | reseed #2 | Import overwrite | `…1-updated.ndjson` |
| A7 | 7 | reseed #2 | disable | |
| A8 | 8 | after A7 | delete (no gaps, `query`) | |

### Branch B — connectors + enable/delete-by-ids

| Step | # | Seed | Action (timed) | Fixture / notes |
|---|---|---|---|---|
| B1 | 9 | clean | Import | `…+connector-email-smtp.ndjson` |
| B2 | 12 | after B1 | Import overwrite | `…+2connectors-email-smtp-cases.ndjson` |
| B2c | 17 | disable all | enable (with connectors) | |
| B3 | 18 | after B2c | delete by `ids` | `SELECT=ids` (`_find` not timed; `bulkGetRules` path) |

### Branch C — exceptions → delete lists

| Step | # | Seed | Action (timed) | Fixture / notes |
|---|---|---|---|---|
| C1 | 10 | clean | Import | `…+20exceptionlists.ndjson` |
| C2 | 11 | after C1 | Import overwrite | `…+21exceptionlists.ndjson` |
| C3 | 13 | C2 + gaps | delete | `GAPS_PER_RULE=3` seed not timed |
| C4 | 14 | after C3 | delete 21 lists | `TYPE=detection` |

### Branch D — delete with active alerts

| Step | # | Seed | Action (timed) | Notes |
|---|---|---|---|---|
| D1c | 19 | import 1000 enabled + `ALERTS_PER_RULE=3` | delete (`query`) | 3000 active AAD docs indexed; `untrackRuleAlerts` path |


## Wall-clock results (curl `time_total`)

All steps HTTP **200**. Reference: widely published `9.5.4` → `9.5.6` improvement results on **main** ([`2026-10-21T0833…`](../published/2026-10-21T0833.full-bench-954-vs-main/SUMMARY.md) / [epic comment](https://github.com/elastic/kibana/issues/264906#issuecomment-6313484568)) — same methodology for #1–#14; different stack/SHA. #15–#19 are new (no 0833 number).

| # | Scenario | This PR #300213 (`b758fc70`) | `9.5.4` → `9.5.6` (0833 main) |
|---|---|---:|---:|
| 1 | Create 1,000 disabled rules | **18.6s** | 13.7s |
| 2 | Create 1,000 enabled rules | **19.1s** | 16.0s |
| 3 | Enable 1,000 disabled rules | **15.5s** | 12.7s |
| 4 | Edit 1,000 rules (add tag) | **23.7s** | 22.4s |
| 5 | Fully update 1,000 enabled rules | **39.1s** | 33.8s |
| 6 | Update 1 of 1,000 (999 unchanged) | **9.6s** | 8.2s |
| 7 | Disable 1,000 enabled rules | **13.7s** | 14.3s |
| 8 | Delete 1,000 rules (no gaps, `query`) | **17.5s** | 16.2s |
| 9 | Create 1,000 enabled + 1 connector | **28.9s** | 25.1s |
| 10 | Create 1,000 + 20 shared lists | **29.2s** | 24.9s |
| 11 | Update +1 shared list (to 21) | **91.6s** | 82.6s |
| 12 | Update 1,000 rules (+ extra connector) | **54.8s** | 49.0s |
| 13 | Delete 1,000 rules (with gaps) | **31.3s** | 19.8s |
| 14 | Delete 21 shared exception lists | **6.3s** | 6.1s |
| 15 | Enable mix (~500 disabled + ~500 enabled) | **18.9s** | — |
| 16 | Re-enable (kept `scheduledTaskId`) | **17.0s** | — |
| 17 | Enable 1,000 with connectors | **20.5s** | — |
| 18 | Delete 1,000 by `ids` (no gaps) | **26.6s** | — |
| 19 | Delete 1,000 with active alerts | **18.7s** | — |

### Notes on wall-clock

- **#6:** `rules_summary` `updated=1, skipped=999` — skip-unchanged path live.
- Creates: `created=1000`. Other timed overwrites: `updated=1000` (#5, #11, #12).
- **Alert seed (#19):** 1000 rules × 3 = **3000** active docs in `.alerts-security.alerts-default` (`delta=3000`).
- **Enable paths (#3 / #15 / #16 / #17):** all ~15–21s on this n=1. Mix (#15) and re-enable (#16) are in the same ballpark as cold enable (#3). Enable with connectors (#17) ~20.5s.
- **Delete paths (#8 / #13 / #18 / #19):**
  - #8 `query`, disabled, no gaps: **17.5s** (≈ 0833 16.2s)
  - #18 `ids`, enabled (post-connectors), no gaps: **26.6s** (slower than #8; `bulkGetRules` vs `findRules`)
  - #19 `query`, enabled, 3000 active alerts: **18.7s** (close to #8; untrack cost not huge on this n=1)
  - #13 `query` + gaps: **31.3s** vs 0833 **19.8s** — hottest delete outlier; treat as n=1 until repeated
- **Slowest overall:** **#11** 91.6s, then #12 54.8s, #5 39.1s, #13 31.3s.
- Most #1–#14 steps are a bit slower than 0833 main (same methodology, newer SHA / PR image). #7 is slightly faster (13.7s vs 14.3s). #14 matches (6.3s vs 6.1s).

Raw: `timings.tsv`, `windows.tsv`, `logs/`, `driver.log`, `apm/trace-ids.json`.

## APM transactions

Longest matching HTTP transaction per exclusive UTC window (`service.environment` / `labels.deploymentName` = `sdesalas.pr.300213.import-apm`). Each `trace.id` links to the waterfall in the [monitoring Kibana](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com) (`rangeFrom`/`rangeTo` padded around the bench window). `dropped` not available via ES|QL on this cluster mapping (`transaction.span_count.dropped` unknown); `spans` = `transaction.span_count.started` (plan cap 15000; max observed **11577** on #12). 🔍 links to static waterfalls under [`docs/benchmarks/published/…/apm/`](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/index.html). Some traces are incomplete (indexed &lt; started) — see waterfall banners.

| # | Scenario | APM dur | spans | dropped | `trace.id` | |
|---|---|---:|---:|---:|---|---|
| 1 | Import → Create 1,000 disabled rules. | 18.0s | 1243 | — | [`54c13ef0dd0f3231a127118e686a4a18`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-06T13%3A31%3A00.000Z&rangeTo=2026-11-06T13%3A51%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_import&traceId=54c13ef0dd0f3231a127118e686a4a18&transactionId=ebc43f93b62484b7) | [🔍](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/apm/01-import-1000-disabled.html) |
| 2 | Import → Create 1,000 enabled rules. | 18.4s | 3275 | — | [`3cee075e7fd71afdf56bc638cb4acb55`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-06T13%3A31%3A00.000Z&rangeTo=2026-11-06T13%3A51%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_import&traceId=3cee075e7fd71afdf56bc638cb4acb55&transactionId=5ab7225f4cc93ad8) | [🔍](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/apm/02-import-1000-enabled.html) |
| 3 | Enable 1,000 existing disabled rules. | 14.9s | 3103 | — | [`7794fd465c54dbd4436266454c340d3f`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-06T13%3A31%3A00.000Z&rangeTo=2026-11-06T13%3A51%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_bulk_action&traceId=7794fd465c54dbd4436266454c340d3f&transactionId=f74a026a83604505) | [🔍](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/apm/03-enable-1000-disabled.html) |
| 4 | Edit 1,000 enabled rules by adding a tag. | 23.0s | 3184 | — | [`c330e9634b6eea4d126e82508e3d717b`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-06T13%3A31%3A00.000Z&rangeTo=2026-11-06T13%3A51%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_bulk_action&traceId=c330e9634b6eea4d126e82508e3d717b&transactionId=483d29a71053aece) | [🔍](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/apm/04-edit-1000-add-tag.html) |
| 5 | Import → Fully update 1,000 enabled rules. | 38.4s | 3758 | — | [`54849a31e7eb097105a183376973a825`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-06T13%3A31%3A00.000Z&rangeTo=2026-11-06T13%3A51%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_import&traceId=54849a31e7eb097105a183376973a825&transactionId=b107b4cf7e7ca564) | [🔍](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/apm/05-import-full-update-1000-enabled.html) |
| 6 | Import → Update 1 of 1,000 (999 unchanged). | 8.9s | 221 | — | [`977d676dfedd132b83bd6f693b4cec58`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-06T13%3A31%3A00.000Z&rangeTo=2026-11-06T13%3A51%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_import&traceId=977d676dfedd132b83bd6f693b4cec58&transactionId=3c4338a49360ecf3) | [🔍](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/apm/06-import-update-1-of-1000.html) |
| 7 | Disable 1,000 existing enabled rules. | 12.7s | 114 | — | [`3df77179f3f438116ac3566c12c45394`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-06T13%3A31%3A00.000Z&rangeTo=2026-11-06T13%3A51%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_bulk_action&traceId=3df77179f3f438116ac3566c12c45394&transactionId=01f6b2cd4e1e4383) | [🔍](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/apm/07-disable-1000-enabled.html) |
| 8 | Delete 1,000 rules (no gaps). | 16.4s | 3094 | — | [`c1c5957ba5e9ad7451a663f6564e5452`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-06T13%3A31%3A00.000Z&rangeTo=2026-11-06T13%3A51%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_bulk_action&traceId=c1c5957ba5e9ad7451a663f6564e5452&transactionId=addfec47fac3b760) | [🔍](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/apm/08-delete-1000-no-gaps.html) |
| 9 | Import → Create 1,000 enabled + 1 connector. | 28.3s | 9282 | — | [`cd4ece27e1385333841cfd12f9783d39`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-06T13%3A31%3A00.000Z&rangeTo=2026-11-06T13%3A51%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_import&traceId=cd4ece27e1385333841cfd12f9783d39&transactionId=889ad8d5ca57671d) | [🔍](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/apm/09-import-1000-enabled-single-connector.html) |
| 10 | Import → Create 1,000 + 20 shared exception lists. | 28.5s | 3297 | — | [`1cd00efcaa34762e3b3b29f9a54a7924`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-06T13%3A31%3A00.000Z&rangeTo=2026-11-06T13%3A51%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_import&traceId=1cd00efcaa34762e3b3b29f9a54a7924&transactionId=d87c26a076124e86) | [🔍](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/apm/10-import-1000-with-20-exception-lists.html) |
| 11 | Import → Update +1 shared list (to 21). | 90.9s | 8838 | — | [`d0d45ae444121d12350c15f736677c32`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-06T13%3A31%3A00.000Z&rangeTo=2026-11-06T13%3A51%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_import&traceId=d0d45ae444121d12350c15f736677c32&transactionId=2b82d144983a5b3d) | [🔍](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/apm/11-import-update-add-21st-exception-list.html) |
| 12 | Import → Update +1 connector. | 54.2s | 11577 | — | [`e51feafb5875f2acf748ca0b573b3b29`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-06T13%3A31%3A00.000Z&rangeTo=2026-11-06T13%3A51%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_import&traceId=e51feafb5875f2acf748ca0b573b3b29&transactionId=4f86fe82116d8dbe) | [🔍](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/apm/12-import-update-add-extra-connector.html) |
| 13 | Delete 1,000 rules with gaps. | 25.8s | 3093 | — | [`20a96faaff1c8e24e40f5ba03ef33b96`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-06T13%3A31%3A00.000Z&rangeTo=2026-11-06T13%3A51%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_bulk_action&traceId=20a96faaff1c8e24e40f5ba03ef33b96&transactionId=36cb7496ff76cbf2) | [🔍](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/apm/13-delete-1000-with-gaps.html) |
| 14 | Delete 21 shared exception lists. | 5.7s | 1380 | — | [`b711cb9ac0c70e1238d326d7c9dd6b3b`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-06T13%3A31%3A00.000Z&rangeTo=2026-11-06T13%3A51%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/internal/api/exception_lists/_bulk_action&traceId=b711cb9ac0c70e1238d326d7c9dd6b3b&transactionId=e3f412dd6cdbb52a) | [🔍](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/apm/14-delete-21-exception-lists.html) |
| 15 | Enable mix (~500 disabled + ~500 enabled). | 17.5s | 3144 | — | [`aad688a6ceefd6d543c76b2e345aafe3`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-06T13%3A31%3A00.000Z&rangeTo=2026-11-06T13%3A51%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_bulk_action&traceId=aad688a6ceefd6d543c76b2e345aafe3&transactionId=90ffb76d6dcf6d70) | [🔍](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/apm/15-enable-mix-500-disabled-500-enabled.html) |
| 16 | Re-enable (kept scheduledTaskId). | 16.5s | 3102 | — | [`ee6fba95654bdd490832ffe8591a7a77`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-06T13%3A31%3A00.000Z&rangeTo=2026-11-06T13%3A51%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_bulk_action&traceId=ee6fba95654bdd490832ffe8591a7a77&transactionId=549200e35e81bfea) | [🔍](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/apm/16-re-enable-kept-scheduled-task-id.html) |
| 17 | Enable 1,000 with connectors. | 18.9s | 4102 | — | [`92f0e8892cb52feac093d497e47e8b4e`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-06T13%3A31%3A00.000Z&rangeTo=2026-11-06T13%3A51%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_bulk_action&traceId=92f0e8892cb52feac093d497e47e8b4e&transactionId=08d4977abadd9ab9) | [🔍](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/apm/17-enable-1000-with-connectors.html) |
| 18 | Delete 1,000 by ids (no gaps). | 24.6s | 4107 | — | [`9f1b4e7b0f5aae83e134567bf1f41280`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-06T13%3A31%3A00.000Z&rangeTo=2026-11-06T13%3A51%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_bulk_action&traceId=9f1b4e7b0f5aae83e134567bf1f41280&transactionId=0b0f17864e5c7770) | [🔍](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/apm/18-delete-1000-by-ids-no-gaps.html) |
| 19 | Delete 1,000 with active alerts. | 17.4s | 3093 | — | [`3bde137ba694753b7ea64c1ab2cf99b5`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-06T13%3A31%3A00.000Z&rangeTo=2026-11-06T13%3A51%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST%20/api/detection_engine/rules/_bulk_action&traceId=3bde137ba694753b7ea64c1ab2cf99b5&transactionId=d1fa323c5b512ee6) | [🔍](../../../docs/benchmarks/published/2026-11-06T1331.full-bench-pr-300213-b758fc70/apm/19-delete-1000-with-active-alerts.html) |
