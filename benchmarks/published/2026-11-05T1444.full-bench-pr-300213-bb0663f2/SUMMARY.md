# Full bench: PR #300213 (`bb0663f2`, 9.7.0-SNAPSHOT)

Single run of the fourteen detection-rule performance scenarios on Elastic Cloud Hosted (**PR-only** — APM-instrumented import/enable/disable/delete spans from [#300213](https://github.com/elastic/kibana/pull/300213)).
Timed **Action** column only (seed steps not timed). This doc is self-contained — you do not need `benchmark-scenarios.md`.


## Targets

**2GB Kibana** (`sdesalas3_security_oom_testing`, `gcp-us-west2`).
Plan knobs: `xpack.siem.maxRuleImportPayloadBytes: 26214400` (25 MiB); `elastic.apm.transactionMaxSpans: 15000`; APM env = deployment name; APM intake → `monitoring-cluster-for-local-kibana-develop-d7b1ce`.

| Label | Deployment | Build |
|---|---|---|
| **PR #300213** | `sdesalas.pr.300213.import-apm` (`sdesalas-pr-300213-import-apm-7a8474.kb.us-west2.gcp.elastic-cloud.com`) | Kibana `9.7.0` @ `bb0663f23163454f8fabe0f09d63a205b13d23e2` (`kibana-cloud-pr:9.7.0-SNAPSHOT-bb0663f2…`) |

Wall-clock window: `2026-11-05T14:45:14Z` → `2026-11-05T14:56:58Z` (per-step UTC in `windows.tsv`).

Scripts: `.knowledge/scripts/bulk-primitives/` (`parallel_import_rules.sh`, `parallel_bulk_action.sh`, `parallel_seed_gaps.sh`, `parallel_delete_exception_lists.sh`). Fixtures: `.knowledge/data/rules-import/`.

Import flags on every import: `overwrite=true&overwrite_exceptions=true&overwrite_action_connectors=true`.

Exception fixtures for C1/C2: each shared list has **50 items** (1000 items across 20 lists; 1050 across 21). Item IPs use `10.{list}.0.{item}`.


## Scenarios

| # | Scenario | Related PRs |
|---|---|---|
| 1 | Import → Create 1,000 disabled rules. | 🔴 #275695 |
| 2 | Import → Create 1,000 enabled rules. | 🔴 #275695, 🟠 #290306 |
| 3 | Enable 1,000 existing disabled rules, with no other changes. | 🟤 #291560, 🟠 #290306 |
| 4 | Edit 1,000 enabled rules by adding a tag. | 🟤 #291560, 🟠 #290306 |
| 5 | Import → Fully update 1,000 rules while they remain enabled. | 🟤 #291560, 🟠 #290306 |
| 6 | Import → Update 1,000 rules where only one has a real update and the other 999 are unchanged. | 🟤 #291560, 🟠 #290306, 🟡 #293948 |
| 7 | Disable 1,000 existing enabled rules, with no other changes. | 🟤 #291560, 🟠 #290306 |
| 8 | Delete 1,000 rules with no gaps. | 🔵 #287065 |
| 9 | Import → Create 1,000 enabled rules with a single connector. | 🔴 #275695, 🟠 #290306 |
| 10 | Import → Create 1,000 rules with 20 shared exception lists (50 items each). | 🔴 #275695, 🟠 #290306 |
| 11 | Import → Update 1,000 rules by adding one more shared exception list (to 21; 50 items each), with no other changes. | 🟤 #291560, 🟠 #290306 |
| 12 | Import → Update 1,000 rules by adding an extra connector, with no other changes. | 🟤 #291560, 🟠 #290306 |
| 13 | Delete 1,000 rules with existing gaps. | 🔵 #287065 |
| 14 | Delete 21 shared exception lists after deleting the rules that used them. | 🟢 #285608 |

## PRs and impact

### `POST /api/detection_engine/rules/_import`

| PR | Impact |
|---|---|
| 🔴 [#275695](https://github.com/elastic/kibana/pull/275695) `9.5.5` | Routes new rule imports through `bulkCreateRules()` instead of per-rule creation. |
| 🟤 [#291560](https://github.com/elastic/kibana/pull/291560) `9.5.6` | Routes overwrite imports through `bulkUpdateRules()` and batches enable/disable transitions. |
| 🟠 [#290306](https://github.com/elastic/kibana/pull/290306) `9.5.5` | Uses `refresh=false` for bulk API-key grants, removing refresh waits. Applies when new keys are minted: enabled creates, updates and enables, including the update step before disabling. For scenarios 6 and 9–12, the benefit depends on enabled state and key creation. |
| 🟡 [#293948](https://github.com/elastic/kibana/pull/293948) `9.5.6` | Skips unchanged rules during overwrite imports, avoiding writes and API-key rotation for the 999 unchanged rules in scenario 6. |
| 🟣 [#300213](https://github.com/elastic/kibana/pull/300213) (this build) | Adds APM spans for detection rule import / enable / disable / delete. |

### `POST /api/detection_engine/rules/_bulk_action`

| PR | Impact |
|---|---|
| 🔵 [#287065](https://github.com/elastic/kibana/pull/287065) `9.5.6` | Batches gap cleanup during rule deletion using `_update_by_query`, reducing requests both with and without existing gaps. |

### Exception-list delete

| PR | Impact |
|---|---|
| 🟢 [#285608](https://github.com/elastic/kibana/pull/285608) `9.6.0` | Adds `POST /internal/api/exception_lists/_bulk_action` (used for C4 on this build). |


## Endpoints

| Endpoint | Scenarios | Usage |
|---|---|---|
| `POST /api/detection_engine/rules/_import` | 1–2, 5–6, 9–12 | Create rules, or import updates with `overwrite=true`. |
| `POST /api/detection_engine/rules/_bulk_action` | 3–4, 7–8, 13 | `enable` (3), `edit`/`add_tags` (4), `disable` (7), `delete` (8, 13). #13 also leaves exception lists for #14. |
| `POST /internal/api/exception_lists/_bulk_action` | 14 | Delete 21 unreferenced `detection` lists (bulk). |


## Methodology (how this run was executed)

Scenario **#** is the scenario id. Rows below are **execution order** — not 1…14 in sequence. Each timed step needs the seed on its left. Time only the **Action** column. This run was a **single repetition** (no 3× means).

### Branch A — baseline rules (then wipe)

| Step | # | Seed | Action (timed) | Fixture / body |
|---|---|---|---|---|
| A1 | 1 | clean space | Import | `1000disabled-rules.ndjson` |
| A2 | 3 | after A1 (disabled) | `_bulk_action` enable | `{"action":"enable","query":""}` |
| A3 | 2 | clean space | Import | `1000enabled-rules.ndjson` |
| A4 | 4 | after A3 (enabled) | `_bulk_action` edit add_tags | `add_tags: ["bench"]` |
| A5 | 5 | reseed #2 | Import overwrite | `1000enabled-rules.all-updated.ndjson` |
| A6 | 6 | reseed #2 | Import overwrite | `1000enabled-rules.1-updated.ndjson` |
| A7 | 7 | reseed #2 | `_bulk_action` disable | `{"action":"disable","query":""}` |
| A8 | 8 | after A7 | `_bulk_action` delete (no gaps) | `{"action":"delete","query":""}` → space empty |

Run **A1 → A8** in table order. Reseed `#2` before each of A5, A6, A7.

### Branch B — connectors

Portable SMTP fixtures (`bench-email-connector`). Clean space after A8.

| Step | # | Seed | Action (timed) | Fixture |
|---|---|---|---|---|
| B1 | 9 | clean space | Import | `1000enabled.rules+connector-email-smtp.ndjson` |
| B2 | 12 | B1 (#9) | Import overwrite | `1000enabled.rules+2connectors-email-smtp-cases.ndjson` (actions only; empty `exceptions_list` both sides) |

### Branch C — exceptions → delete lists

Clean space before C1 (rules + lists wiped after B2). Shared lists carry **50 items each**. C2 is a strict superset of C1 (lists 1–20 unchanged; list 21 added).

| Step | # | Seed | Action (timed) | Fixture / notes |
|---|---|---|---|---|
| C1 | 10 | clean space | Import | `1000enabled.rules+20exceptionlists.ndjson` (20 lists × 50 items) |
| C2 | 11 | C1 (#10) | Import overwrite | `1000enabled.rules+21exceptionlists.ndjson` (21 lists × 50 items) |
| C3 | 13 | C2 + gaps | `_bulk_action` delete | `GAPS_PER_RULE=3 ./parallel_seed_gaps.sh` (not timed) then delete; lists remain |
| C4 | 14 | after C3 | Delete 21 shared lists | `TYPE=detection` via `./parallel_delete_exception_lists.sh` — bulk (`#285608`) |


## Wall-clock results (curl `time_total`)

All steps HTTP **200**. Reference: published main-only **2026-10-27T1043** (`c4c560f2`, 9.6.0-SNAPSHOT) — same methodology; different stack/SHA.

| Step | # | Scenario | PR #300213 (`bb0663f2`) | main `c4c560f2` (ref) |
|---|---|---|---:|---:|
| A1 | 1 | Create 1,000 disabled rules | **14.7s** | 14.2s |
| A2 | 3 | Enable 1,000 disabled rules | **14.4s** | 12.2s |
| A3 | 2 | Create 1,000 enabled rules | **18.8s** | 17.4s |
| A4 | 4 | Edit 1,000 rules (add tag) | **23.0s** | 20.7s |
| A5 | 5 | Fully update 1,000 enabled rules | **30.5s** | 33.4s |
| A6 | 6 | Update 1 of 1,000 (999 unchanged) | **8.0s** | 8.1s |
| A7 | 7 | Disable 1,000 enabled rules | **14.2s** | 12.8s |
| A8 | 8 | Delete 1,000 rules (no gaps) | **15.3s** | 18.0s |
| B1 | 9 | Create 1,000 enabled + 1 connector | **25.7s** | 23.4s |
| B2 | 12 | Update 1,000 rules (+ extra connector) | **47.8s** | 46.7s |
| C1 | 10 | Create 1,000 rules + 20 shared lists (50 items each) | **22.2s** | 23.7s |
| C2 | 11 | Update +1 shared list (to 21; 50 items) | **85.4s** | 94.3s |
| C3 | 13 | Delete 1,000 rules (with gaps) | **20.1s** | 22.5s |
| C4 | 14 | Delete 21 shared exception lists (bulk) | **5.9s** | 6.8s |

### Notes on wall-clock

- **#6 (A6):** `rules_summary` `updated=1, skipped=999` — skip-unchanged path live.
- Other timed overwrites: `updated=1000` (A5, B2, C2); creates: `created=1000`.
- **Slowest:** **C2 (#11)** 85.4s (faster than main ref 94.3s on this n=1).
- **Next:** B2 47.8s, A5 30.5s, B1 25.7s.
- **C4:** bulk delete 21 `detection` lists in **5.9s** (one batch).

Raw: `timings.tsv`, `windows.tsv`, `logs/`, `driver.log`, `apm/trace-ids.json`.


## APM transactions

Longest matching HTTP transaction per exclusive UTC window (`service.environment` / `labels.deploymentName` = `sdesalas.pr.300213.import-apm`). Each `trace.id` links to the waterfall in the [monitoring Kibana](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com) (`rangeFrom`/`rangeTo` padded around the bench window). `dropped` not available via ES|QL on this cluster mapping (`transaction.span_count.dropped` unknown); `spans` = `transaction.span_count.started` (plan cap 15000; max observed 11544 on #12).

| # | Scenario | APM dur | spans | dropped | `trace.id` | |
|---|---|---:|---:|---:|---|---|
| 1 | Import → Create 1,000 disabled rules. | 14.1s | 1245 | — | [`b64855dfc053c6bd1a133001548c7e42`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-05T14%3A44%3A00.000Z&rangeTo=2026-11-05T14%3A58%3A00.000Z&serviceGroup=&showCriticalPath=&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&transactionType=request&traceId=b64855dfc053c6bd1a133001548c7e42&transactionId=be7e56846480c145) | |
| 2 | Import → Create 1,000 enabled rules. | 18.1s | 3273 | — | [`8c512cb3586c27a3e247b022fe14823e`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-05T14%3A44%3A00.000Z&rangeTo=2026-11-05T14%3A58%3A00.000Z&serviceGroup=&showCriticalPath=&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&transactionType=request&traceId=8c512cb3586c27a3e247b022fe14823e&transactionId=e064caa9e6771586) | |
| 3 | Enable 1,000 existing disabled rules, with no other changes. | 13.1s | 3076 | — | [`3c281a8da47aca96c9c947dc6620fc8e`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-05T14%3A44%3A00.000Z&rangeTo=2026-11-05T14%3A58%3A00.000Z&serviceGroup=&showCriticalPath=&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&transactionType=request&traceId=3c281a8da47aca96c9c947dc6620fc8e&transactionId=9436f0636957a674) | |
| 4 | Edit 1,000 enabled rules by adding a tag. | 22.1s | 3210 | — | [`7ab3848a88de25b037fc6aa1b551f84c`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-05T14%3A44%3A00.000Z&rangeTo=2026-11-05T14%3A58%3A00.000Z&serviceGroup=&showCriticalPath=&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&transactionType=request&traceId=7ab3848a88de25b037fc6aa1b551f84c&transactionId=03b39472fd0cfc61) | |
| 5 | Import → Fully update 1,000 rules while they remain enabled. | 29.9s | 3704 | — | [`b583503a0469b9430852071e3e7a40ec`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-05T14%3A44%3A00.000Z&rangeTo=2026-11-05T14%3A58%3A00.000Z&serviceGroup=&showCriticalPath=&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&transactionType=request&traceId=b583503a0469b9430852071e3e7a40ec&transactionId=b961f64796d8d32a) | |
| 6 | Import → Update 1,000 rules where only one has a real update and the other 999 are unchanged. | 7.3s | 221 | — | [`bb0e05fb29eec2bc1d1fc4177c8fc0bc`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-05T14%3A44%3A00.000Z&rangeTo=2026-11-05T14%3A58%3A00.000Z&serviceGroup=&showCriticalPath=&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&transactionType=request&traceId=bb0e05fb29eec2bc1d1fc4177c8fc0bc&transactionId=63bf939c3cdbaf83) | |
| 7 | Disable 1,000 existing enabled rules, with no other changes. | 12.4s | 114 | — | [`7a836021e35840eba90bc80265560405`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-05T14%3A44%3A00.000Z&rangeTo=2026-11-05T14%3A58%3A00.000Z&serviceGroup=&showCriticalPath=&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&transactionType=request&traceId=7a836021e35840eba90bc80265560405&transactionId=71154a5077dc36a8) | |
| 8 | Delete 1,000 rules with no gaps. | 13.7s | 3094 | — | [`f75f281fbb85d8dd07a4a609fa400f63`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-05T14%3A44%3A00.000Z&rangeTo=2026-11-05T14%3A58%3A00.000Z&serviceGroup=&showCriticalPath=&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&transactionType=request&traceId=f75f281fbb85d8dd07a4a609fa400f63&transactionId=cba0eb2f1271b1e9) | |
| 9 | Import → Create 1,000 enabled rules with a single connector. | 24.9s | 9284 | — | [`b8fd97efd0a18515f868f59f1fce7975`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-05T14%3A44%3A00.000Z&rangeTo=2026-11-05T14%3A58%3A00.000Z&serviceGroup=&showCriticalPath=&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&transactionType=request&traceId=b8fd97efd0a18515f868f59f1fce7975&transactionId=fad8b3eaa75df7f1) | |
| 10 | Import → Create 1,000 rules with 20 shared exception lists (50 items each). | 21.5s | 3298 | — | [`5b3b0bf48c8a15e6267a3719863ef78e`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-05T14%3A44%3A00.000Z&rangeTo=2026-11-05T14%3A58%3A00.000Z&serviceGroup=&showCriticalPath=&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&transactionType=request&traceId=5b3b0bf48c8a15e6267a3719863ef78e&transactionId=69c701f8b61961bf) | |
| 11 | Import → Update 1,000 rules by adding one more shared exception list (to 21; 50 items each), with no other changes. | 84.7s | 8824 | — | [`8db82989fd52a975e860f31ade74a503`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-05T14%3A44%3A00.000Z&rangeTo=2026-11-05T14%3A58%3A00.000Z&serviceGroup=&showCriticalPath=&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&transactionType=request&traceId=8db82989fd52a975e860f31ade74a503&transactionId=c9239c7c0139c05f) | |
| 12 | Import → Update 1,000 rules by adding an extra connector, with no other changes. | 47.1s | 11544 | — | [`393df8ec59e9c8a7e1c3000fb05435a6`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-05T14%3A44%3A00.000Z&rangeTo=2026-11-05T14%3A58%3A00.000Z&serviceGroup=&showCriticalPath=&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&transactionType=request&traceId=393df8ec59e9c8a7e1c3000fb05435a6&transactionId=36ca1fcf811a6f62) | |
| 13 | Delete 1,000 rules with existing gaps. | 18.8s | 3093 | — | [`5209d0488854f532d886729b67ed24c8`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-05T14%3A44%3A00.000Z&rangeTo=2026-11-05T14%3A58%3A00.000Z&serviceGroup=&showCriticalPath=&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&transactionType=request&traceId=5209d0488854f532d886729b67ed24c8&transactionId=3a5f0dff9bac0f09) | |
| 14 | Delete 21 shared exception lists after deleting the rules that used them. | 5.3s | 1336 | — | [`ee5a40046fbe683a88b4cf64a070dd6f`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-05T14%3A44%3A00.000Z&rangeTo=2026-11-05T14%3A58%3A00.000Z&serviceGroup=&showCriticalPath=&transactionName=POST+%2Finternal%2Fapi%2Fexception_lists%2F_bulk_action&transactionType=request&traceId=ee5a40046fbe683a88b4cf64a070dd6f&transactionId=6d6aeca34a0384aa) | |

C4 also issued a short `GET /api/exception_lists/_find` in the same window: [`f5c6ee78e2088061573ef3f701d8d1c6`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-05T14:44:00.000Z&rangeTo=2026-11-05T14:58:00.000Z&serviceGroup=&showCriticalPath=&transactionName=GET%20%2Fapi%2Fexception_lists%2F_find&transactionType=request&traceId=f5c6ee78e2088061573ef3f701d8d1c6&transactionId=d6528da8985c21b7) (~39ms) — list discovery before bulk delete.
