# Full bench: main only (`c4c560f2`, 9.6.0-SNAPSHOT)

Single run of the fourteen detection-rule performance scenarios on Elastic Cloud Hosted (**main-only** — no 9.5.4 side this run).
Timed **Action** column only (seed steps not timed). This doc is self-contained — you do not need `benchmark-scenarios.md`.


## Targets

**2GB Kibana** (`sdesalas3_security_oom_testing`, `gcp-us-west2`).
Plan knobs: `xpack.siem.maxRuleImportPayloadBytes: 26214400` (25 MiB); `elastic.apm.transactionMaxSpans: 10000`; APM env = deployment name.

| Label | Deployment | Build |
|---|---|---|
| **main** | `main-at-c4c560f2-cd6300` (`main-at-c4c560f2-cd6300.kb.us-west2.gcp.elastic-cloud.com`) | Kibana `9.6.0` @ `c4c560f29662a59a906824ae61e62ac4390b327d` (unified `9.6.0-SNAPSHOT`) |

Wall-clock window: `2026-10-27T10:48:15Z` → `2026-10-27T10:59:39Z` (per-step UTC in `windows.tsv`).

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

All steps HTTP **200**. Optional reference: published dual-stack **0833** main column (same methodology; different deploy/`ffa1cb22`).

| Step | # | Scenario | main (`c4c560f2`) | 0833 main (ref) |
|---|---|---|---:|---:|
| A1 | 1 | Create 1,000 disabled rules | **14.2s** | 13.7s |
| A2 | 3 | Enable 1,000 disabled rules | **12.2s** | 12.7s |
| A3 | 2 | Create 1,000 enabled rules | **17.4s** | 16.0s |
| A4 | 4 | Edit 1,000 rules (add tag) | **20.7s** | 22.4s |
| A5 | 5 | Fully update 1,000 enabled rules | **33.4s** | 33.8s |
| A6 | 6 | Update 1 of 1,000 (999 unchanged) | **8.1s** | 8.2s |
| A7 | 7 | Disable 1,000 enabled rules | **12.8s** | 14.3s |
| A8 | 8 | Delete 1,000 rules (no gaps) | **18.0s** | 16.2s |
| B1 | 9 | Create 1,000 enabled + 1 connector | **23.4s** | 25.1s |
| B2 | 12 | Update 1,000 rules (+ extra connector) | **46.7s** | 49.0s |
| C1 | 10 | Create 1,000 rules + 20 shared lists (50 items each) | **23.7s** | 24.9s |
| C2 | 11 | Update +1 shared list (to 21; 50 items) | **94.3s** | 82.6s |
| C3 | 13 | Delete 1,000 rules (with gaps) | **22.5s** | 19.8s |
| C4 | 14 | Delete 21 shared exception lists (bulk) | **6.8s** | 6.1s |

### Notes on wall-clock

- **#6 (A6):** `rules_summary` `updated=1, skipped=999` — skip-unchanged path live.
- Other timed overwrites: `updated=1000` (A5, B2, C2); creates: `created=1000`.
- **Slowest:** **C2 (#11)** 94.3s — ~12s above 0833 main (82.6s); n=1, treat as variance until dig.
- **Next:** B2 46.7s, A5 33.4s, C1/B1 ~23–24s.
- **C4:** bulk delete 21 `detection` lists in **6.8s** (one batch).
- Steps &gt;20s (dig candidates if requested): A4, A5, A8, B1, B2, C1, C2, C3.
- Import-path APM breakdowns (&gt;20s `_import` only): [`APM-IMPORT-PATHS.md`](./APM-IMPORT-PATHS.md).

Raw: `timings.tsv`, `windows.tsv`, `logs/`, `driver.log`, `apm/trace-ids.json`.


## APM transactions

Longest matching HTTP transaction per exclusive UTC window (`service.environment` / `labels.deploymentName` = `main-at-c4c560f2`). Each `trace.id` links to the waterfall in the [monitoring Kibana](https://monitoring-cluster-for-local-kibana-develop-00f6f1.kb.us-west2.gcp.elastic-cloud.com) (`rangeFrom`/`rangeTo` padded around the bench window). 🔍 links to a local APM UI screenshot under `./images/` when available.

| # | Scenario | APM dur | spans | dropped | `trace.id` | |
|---|---|---:|---:|---:|---|---|
| 1 | Import → Create 1,000 disabled rules. | 13.5s | 1211 | 0 | [`775142b7165c41178aebf90fc5ecbd6a`](https://monitoring-cluster-for-local-kibana-develop-00f6f1.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-10-27T10:34:04.447Z&rangeTo=2026-10-27T11:16:14.826Z&serviceGroup=&showCriticalPath=&transactionName=POST%20%2Fapi%2Fdetection_engine%2Frules%2F_import&transactionType=request&traceId=775142b7165c41178aebf90fc5ecbd6a&transactionId=52359ee0f138bba1) | [🔍](./images/scenario-01-create-1000-disabled.png) |
| 2 | Import → Create 1,000 enabled rules. | 16.7s | 3235 | 0 | [`13fc93a4de163491d445067ec15049ad`](https://monitoring-cluster-for-local-kibana-develop-00f6f1.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-10-27T10:34:04.447Z&rangeTo=2026-10-27T11:16:14.826Z&serviceGroup=&showCriticalPath=&transactionName=POST%20%2Fapi%2Fdetection_engine%2Frules%2F_import&transactionType=request&traceId=13fc93a4de163491d445067ec15049ad&transactionId=00916ddc1992532d) | [🔍](./images/scenario-02-create-1000-enabled.png) |
| 3 | Enable 1,000 existing disabled rules, with no other changes. | 10.8s | 2071 | 0 | [`dd4c88dd702cb8f2ca2be66c1927c986`](https://monitoring-cluster-for-local-kibana-develop-00f6f1.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-10-27T10:34:04.447Z&rangeTo=2026-10-27T11:16:14.826Z&serviceGroup=&showCriticalPath=&transactionName=POST%20%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&transactionType=request&traceId=dd4c88dd702cb8f2ca2be66c1927c986&transactionId=6e799de3bf1f79a6) | |
| 4 | Edit 1,000 enabled rules by adding a tag. | 19.3s | 3197 | 0 | [`f72de523d162cf166474190f4610d97a`](https://monitoring-cluster-for-local-kibana-develop-00f6f1.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-10-27T10:34:04.447Z&rangeTo=2026-10-27T11:16:14.826Z&serviceGroup=&showCriticalPath=&transactionName=POST%20%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&transactionType=request&traceId=f72de523d162cf166474190f4610d97a&transactionId=bca8e8a2d5e2ba64) | |
| 5 | Import → Fully update 1,000 rules while they remain enabled. | 32.6s | 3670 | 0 | [`4bfcab69f5f04b60d4da7acc94bf8df6`](https://monitoring-cluster-for-local-kibana-develop-00f6f1.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-10-27T10:34:04.447Z&rangeTo=2026-10-27T11:16:14.826Z&serviceGroup=&showCriticalPath=&transactionName=POST%20%2Fapi%2Fdetection_engine%2Frules%2F_import&transactionType=request&traceId=4bfcab69f5f04b60d4da7acc94bf8df6&transactionId=b8d8aea972ebb64b) | [🔍](./images/scenario-05-fully-update-1000-enabled.png) |
| 6 | Import → Update 1,000 rules where only one has a real update and the other 999 are unchanged. | 7.4s | 189 | 0 | [`7032f1b2f9bced70480df71dff1a4a9e`](https://monitoring-cluster-for-local-kibana-develop-00f6f1.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-10-27T10:34:04.447Z&rangeTo=2026-10-27T11:16:14.826Z&serviceGroup=&showCriticalPath=&transactionName=POST%20%2Fapi%2Fdetection_engine%2Frules%2F_import&transactionType=request&traceId=7032f1b2f9bced70480df71dff1a4a9e&transactionId=4893367068b20a7a) | [🔍](./images/scenario-06-update-1-of-1000.png) |
| 7 | Disable 1,000 existing enabled rules, with no other changes. | 11.3s | 110 | 0 | [`3a256c19f778a4d1ed4fbb51cd6cd9ed`](https://monitoring-cluster-for-local-kibana-develop-00f6f1.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-10-27T10:34:04.447Z&rangeTo=2026-10-27T11:16:14.826Z&serviceGroup=&showCriticalPath=&transactionName=POST%20%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&transactionType=request&traceId=3a256c19f778a4d1ed4fbb51cd6cd9ed&transactionId=e4612a1081b2006f) | |
| 8 | Delete 1,000 rules with no gaps. | 13.2s | 3089 | 0 | [`04ae851d64e95b1efc1da7976ad148ef`](https://monitoring-cluster-for-local-kibana-develop-00f6f1.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-10-27T10:34:04.447Z&rangeTo=2026-10-27T11:16:14.826Z&serviceGroup=&showCriticalPath=&transactionName=POST%20%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&transactionType=request&traceId=04ae851d64e95b1efc1da7976ad148ef&transactionId=8b7237a21dc9ccfb) | |
| 9 | Import → Create 1,000 enabled rules with a single connector. | 22.7s | 9245 | 0 | [`4384668d81f4f57824a142dabd9fb170`](https://monitoring-cluster-for-local-kibana-develop-00f6f1.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-10-27T10:34:04.447Z&rangeTo=2026-10-27T11:16:14.826Z&serviceGroup=&showCriticalPath=&transactionName=POST%20%2Fapi%2Fdetection_engine%2Frules%2F_import&transactionType=request&traceId=4384668d81f4f57824a142dabd9fb170&transactionId=9068a7aeda021885) | [🔍](./images/scenario-09-create-1000-enabled-connector.png) |
| 10 | Import → Create 1,000 rules with 20 shared exception lists (50 items each). | 23.0s | 3254 | 0 | [`dd4a7381f51ad7a760645cf314cd00d4`](https://monitoring-cluster-for-local-kibana-develop-00f6f1.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-10-27T10:34:04.447Z&rangeTo=2026-10-27T11:16:14.826Z&serviceGroup=&showCriticalPath=&transactionName=POST%20%2Fapi%2Fdetection_engine%2Frules%2F_import&transactionType=request&traceId=dd4a7381f51ad7a760645cf314cd00d4&transactionId=fef8c12d4672f37a) | [🔍](./images/scenario-10-create-1000-plus-20-exception-lists.png) |
| 11 | Import → Update 1,000 rules by adding one more shared exception list (to 21; 50 items each), with no other changes. | 93.6s | 8727 | 0 | [`57ad676ae0655a7d5de98629faf61d7d`](https://monitoring-cluster-for-local-kibana-develop-00f6f1.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-10-27T10:34:04.447Z&rangeTo=2026-10-27T11:16:14.826Z&serviceGroup=&showCriticalPath=&transactionName=POST%20%2Fapi%2Fdetection_engine%2Frules%2F_import&transactionType=request&traceId=57ad676ae0655a7d5de98629faf61d7d&transactionId=269d8d1cbd0cb3d5) | |
| 12 | Import → Update 1,000 rules by adding an extra connector, with no other changes. | 46.0s | 10000 | **1533** 🚨 | [`6fe628511b8003e7ceb700b6e7c1e3c8`](https://monitoring-cluster-for-local-kibana-develop-00f6f1.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-10-27T10:34:04.447Z&rangeTo=2026-10-27T11:16:14.826Z&serviceGroup=&showCriticalPath=&transactionName=POST%20%2Fapi%2Fdetection_engine%2Frules%2F_import&transactionType=request&traceId=6fe628511b8003e7ceb700b6e7c1e3c8&transactionId=4d297e53a9d9963c) | |
| 13 | Delete 1,000 rules with existing gaps. | 20.5s | 3088 | 0 | [`054a4652a86ff3fcc5b19810f25d7395`](https://monitoring-cluster-for-local-kibana-develop-00f6f1.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-10-27T10:34:04.447Z&rangeTo=2026-10-27T11:16:14.826Z&serviceGroup=&showCriticalPath=&transactionName=POST%20%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&transactionType=request&traceId=054a4652a86ff3fcc5b19810f25d7395&transactionId=2171745df908a7d1) | |
| 14 | Delete 21 shared exception lists after deleting the rules that used them. | 6.2s | 1336 | 0 | [`d2f27a284a85eb303d961fb7e542a3e3`](https://monitoring-cluster-for-local-kibana-develop-00f6f1.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-10-27T10:34:04.447Z&rangeTo=2026-10-27T11:16:14.826Z&serviceGroup=&showCriticalPath=&transactionName=POST%20%2Finternal%2Fapi%2Fexception_lists%2F_bulk_action&transactionType=request&traceId=d2f27a284a85eb303d961fb7e542a3e3&transactionId=7e4c75944fb84b78) | |

C4 also issued a short `GET /api/exception_lists/_find` in the same window: [`b8c3e8560474c4d3e193243d82bc38ba`](https://monitoring-cluster-for-local-kibana-develop-00f6f1.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-10-27T10:34:04.447Z&rangeTo=2026-10-27T11:16:14.826Z&serviceGroup=&showCriticalPath=&transactionName=GET%20%2Fapi%2Fexception_lists%2F_find&transactionType=request&traceId=b8c3e8560474c4d3e193243d82bc38ba&transactionId=e7466af0aa971a0f) (29ms) — list discovery before bulk delete.
