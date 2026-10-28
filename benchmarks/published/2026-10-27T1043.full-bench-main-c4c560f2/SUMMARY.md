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
- **Slowest:** **C2 (#11)** 94.3s — ~12s above 0833 main (82.6s); n=1, treat as variance until investigation.
- **Next:** B2 46.7s, A5 33.4s, C1/B1 ~23–24s.
- **C4:** bulk delete 21 `detection` lists in **6.8s** (one batch).
- Steps &gt;20s (investigation candidates if requested): A4, A5, A8, B1, B2, C1, C2, C3.

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


## Performance investigation

Used APM to investigate **`POST /api/detection_engine/rules/_import` only** on this main deploy (`c4c560f2` / `main-at-c4c560f2`): scenarios **#1, #2, #5, #6, #9, #10, #11, #12**. Bulk_action / delete scenarios are out of scope here.

Unions are overlapping wall-clock for that `span.name` — **do not sum nested parents+children**. `createAPIKey` + `api_key/grant` are the same work (double-count if added). Parent envelopes (`route handler`, `DetectionRulesClient.importRules`) wrap the candidates below — optimize children, not the parent name.

### Span inventory (`_import`)

**Spans** = APM `started + dropped`. 🚨 = span cap (trace incomplete). **ES calls** = recorded spans whose name starts with `Elasticsearch:` (undercounts when dropped). C2 analyze paged **6204 / 8727** span docs — rankings may miss some late/low names; top unions still useful.

| Step | # | APM dur | spans | ES calls | dropped | `trace.id` |
|---|---|---:|---:|---:|---:|---|
| A1 | 1 | 13.5s | 1211 | 1156 | 0 | `775142b7165c41178aebf90fc5ecbd6a` |
| A3 | 2 | 16.7s | 3235 | 2170 | 0 | `13fc93a4de163491d445067ec15049ad` |
| A5 | 5 | 32.6s | 3670 | 2471 | 0 | `4bfcab69f5f04b60d4da7acc94bf8df6` |
| A6 | 6 | 7.4s | 189 | 151 | 0 | `7032f1b2f9bced70480df71dff1a4a9e` |
| B1 | 9 | 22.7s | 9245 | 8180 | 0 | `4384668d81f4f57824a142dabd9fb170` |
| C1 | 10 | 23.0s | 3254 | 2189 | 0 | `dd4a7381f51ad7a760645cf314cd00d4` |
| C2 | 11 | 93.6s | 8727 | 4865 | 0 | `57ad676ae0655a7d5de98629faf61d7d` |
| B2 | 12 | 46.0s | 11533 | 8260 | **1533** 🚨 | `6fe628511b8003e7ceb700b6e7c1e3c8` |

---

### A1 (#1) — create 1,000 disabled rules

`POST /api/detection_engine/rules/_import` — `1000disabled-rules.ndjson` (create; clean space).

`trace.id=775142b7165c41178aebf90fc5ecbd6a` · 13.5s · started=1211 · dropped=0

Disabled create — **no** `createAPIKey` / grant. Still pays authz + SO write + a fixed `pre-route` tax.

| Rank | Candidate | Union | % txn | n | Pattern | Optimization tip |
|---|---|---:|---:|---:|---|---|
| 1 | `bulkCreateRulesSo` | **5.1s** | 37.6% | 5 | SO write | Keep; main create cost. |
| 2 | `_bulk` | **3.1s** | 23.2% | 5 | Serial / write path | Secondary. |
| 3 | `_has_privileges` | **2.7s** | 19.8% | **1073** | Authz N+1 / cache | Request-scoped privilege cache (even with no keys). |
| 4 | `prepareRule` | **2.2s** | 16.1% | 5 | Create prep | Keep. |
| 5 | `pre-route` middlewares | **2.1s** | 15.6% | 1 | Fixed tax / dark time | Investigate children — large self under parent (step 4). |
| 6 | prebuilt `fetchLatestVersions` | **1.3s** | 9.5% | 5 | Asset fetch | Cache across batches. |

Parent `importRules` ≈ 11.0s (81%).

**Highest leverage for A1:** authz cache → then understand `pre-route` self-time.

---

### A3 (#2) — create 1,000 enabled rules

`POST /api/detection_engine/rules/_import` — `1000enabled-rules.ndjson` (create; clean space).

`trace.id=13fc93a4de163491d445067ec15049ad` · 16.7s · started=3235 · dropped=0

Same create path as A1 plus **1000** API-key grants (`refresh=false` already helps union).

| Rank | Candidate | Union | % txn | n | Pattern | Optimization tip |
|---|---|---:|---:|---:|---|---|
| 1 | `bulkCreateRulesSo` | **6.4s** | 38.5% | 5 | SO write | Keep. |
| 2 | `_bulk` | **4.4s** | 26.6% | 10 | Serial / write path | Secondary. |
| 3 | `_has_privileges` | **4.0s** | 24.2% | **1072** | Authz N+1 / cache | Request-scoped cache. |
| 4 | `prepareRule` | **3.8s** | 22.8% | 5 | Create prep | Keep. |
| 5 | `createAPIKey` + `api_key/grant` | **~3.6s** each | 21.5% | **1000** | API-key churn (double-count) | Expected for enabled create; bulk-generate leftover (#273675) if still serial grants. |
| 6 | `pre-route` middlewares | **2.1s** | 12.5% | 1 | Fixed tax | Same as A1. |

Parent `importRules` ≈ 14.3s (86%).

**Highest leverage for A3:** authz cache → bulk-generate keys (grants that remain necessary).

---

### A5 (#5) — fully update 1,000 enabled rules (overwrite)

`POST /api/detection_engine/rules/_import` with `overwrite=true` — `1000enabled-rules.all-updated.ndjson`.

`trace.id=4bfcab69f5f04b60d4da7acc94bf8df6` · 32.6s · started=3670 · dropped=0

All 1000 rules change → skip-unchanged does **not** apply. Path is `bulkUpdateRules`.

| Rank | Candidate | Union | % txn | n | Pattern | Optimization tip |
|---|---|---:|---:|---:|---|---|
| 1 | `_bulk` | **13.7s** | 42.1% | 29 | Serial / write path | Real update write work. |
| 2 | `invalidateKeys` / `bulkMarkApiKeysForInvalidation` | **9.1s** | 28.0% | — | API-key churn | Avoid rotate when action authz / enabled unchanged. |
| 3 | `bulkCreateRulesSo` (putAttempt) | **8.7s** | 26.7% | 9 | SO write | Keep; shrink key/authz tax around it. |
| 4 | `_has_privileges` | **5.2s** | 16.0% | **1208** | Authz N+1 / cache | Request-scoped cache. |
| 5 | `prepareUpdate` | **4.8s** | 14.7% | 9 | Update prep | Slim when only a subset of fields change. |
| 6 | `createAPIKey` + `api_key/grant` | **~4.4s** each | 13.4% | **1007** | API-key churn (double-count) | Pair with tip 2. |
| 7 | `resolve capabilities` | **4.1s** | 12.5% | **64** | Fan-out | Cache per request. |
| 8 | `space:default` GET | **3.1s** | 9.5% | **66** | N+1 ES | Cache space doc once per request. |
| 9 | `pre-route` middlewares | **2.1s** | 6.4% | 1 | Fixed tax | Later. |

Parent `importRules` ≈ 30.2s (93%).

**Highest leverage for A5:** stop full API-key rotate when authz unchanged → authz / capabilities / space cache → then tune `_bulk`.

---

### A6 (#6) — update 1 of 1,000 (999 unchanged)

`POST /api/detection_engine/rules/_import` with `overwrite=true` — `1000enabled-rules.1-updated.ndjson` (`updated=1, skipped=999`).

`trace.id=7032f1b2f9bced70480df71dff1a4a9e` · 7.4s · started=189 · dropped=0

Skip-unchanged path is live — tiny rule write/key work. Remaining wall is mostly fixed taxes + asset fetches.

| Rank | Candidate | Union | % txn | n | Pattern | Optimization tip |
|---|---|---:|---:|---:|---|---|
| 1 | `pre-route` middlewares | **2.0s** | 27.8% | 1 | Fixed tax / dark time | Dominates this short txn — investigate children. |
| 2 | prebuilt `fetchLatestVersions` (+ related) | **~1.9s** | 26.0% | 5 | Asset fetch | Still runs for a 1-rule change; cache / short-circuit. |
| 3 | `_bulk` | **1.1s** | 14.8% | 2 | Write path | Expected for the 1 updated rule. |
| 4 | `invalidateKeys` / mark invalidation | **1.0s** | 13.7% | — | API-key churn | Only 1 rule — already small. |
| 5 | `_has_privileges` | **0.8s** | 11.2% | **70** | Authz | Mild; cache still helps. |

Parent `importRules` ≈ 4.9s (66%) — large gap vs route (~5.3s) is mostly `pre-route`.

**Highest leverage for A6:** already the win scenario; leftover is `pre-route` + prebuilt asset tax on near-noop imports.

---

### B1 (#9) — create 1,000 enabled rules + 1 connector

`POST /api/detection_engine/rules/_import` — `1000enabled.rules+connector-email-smtp.ndjson`.

`trace.id=4384668d81f4f57824a142dabd9fb170` · 22.7s · started=9245 · dropped=0

Create + connector — authz and `_mget` explode vs plain enabled create.

| Rank | Candidate | Union | % txn | n | Pattern | Optimization tip |
|---|---|---:|---:|---:|---|---|
| 1 | `_has_privileges` | **9.8s** | 43.2% | **4076** | Authz N+1 / cache | Worst authz count of the create investigations — cache per request. |
| 2 | `prepareRule` | **7.3s** | 32.0% | 5 | Create prep | Slim when actions share one connector. |
| 3 | `_mget` | **6.6s** | 28.9% | **2012** | Read amplification | Dedupe connector / action SO loads across 1000 rules. |
| 4 | `bulkCreateRulesSo` | **5.5s** | 24.3% | 5 | SO write | Keep. |
| 5 | `createAPIKey` + `api_key/grant` | **~4.8s** each | 21.1% | **1000** | API-key churn (double-count) | Expected for enabled create. |
| 6 | `_bulk` | **4.0s** | 17.6% | 11 | Serial / write path | Secondary. |
| 7 | cases `_search` | **2.3s** | 10.1% | **1012** | ~1/rule | Batch/cache case connector lookups. |
| 8 | `pre-route` | **2.1s** | 9.3% | 1 | Fixed tax | Later. |

Parent `importRules` ≈ 17.2s (76%).

**Highest leverage for B1:** authz cache → dedupe `_mget` / cases lookups for shared connector.

---

### C1 (#10) — create 1,000 enabled rules + 20 shared lists (50 items each)

`POST /api/detection_engine/rules/_import` — `1000enabled.rules+20exceptionlists.ndjson`.

`trace.id=dd4a7381f51ad7a760645cf314cd00d4` · 23.0s · started=3254 · dropped=0

Create path — relatively clean vs C2 (no key invalidate dance, no huge `_mget`).

| Rank | Candidate | Union | % txn | n | Pattern | Optimization tip |
|---|---|---:|---:|---:|---|---|
| 1 | `bulkCreateRulesSo` | **6.8s** | 29.6% | 5 | SO write | Keep. |
| 2 | `_has_privileges` | **4.8s** | 21.0% | **1082** | Authz N+1 / cache | Request-scoped cache. |
| 3 | `_bulk` | **4.7s** | 20.3% | 12 | Serial / write path | Rules + exception materialization. |
| 4 | `prepareRule` | **3.7s** | 16.0% | 5 | Create prep | Keep. |
| 5 | `createAPIKey` + `api_key/grant` | **~3.4s** each | 14.9% | **1000** | API-key churn (double-count) | Expected on enabled create. |
| 6 | `pre-route` middlewares | **2.6s** | 11.3% | 1 | Fixed tax | Later. |
| 7 | prebuilt asset fetches | **~2.4s** | 10.2% | 5 | Asset fetch | Cache across batches. |

Parent `importRules` ≈ 18.4s (80%).

**Highest leverage for C1:** authz cache. Create+key work is largely inherent; C2’s update tax is the bigger leftover vs this baseline.

---

### C2 (#11) — add one shared exception list (to 21; 50 items; all 1000 rules change)

`POST /api/detection_engine/rules/_import` with `overwrite=true` — `1000enabled.rules+21exceptionlists.ndjson`.

`trace.id=57ad676ae0655a7d5de98629faf61d7d` · 93.6s · started=8727 · dropped=0 · analyzed span docs=6204 (partial page).

~**26.6s** of the txn runs **before** `importRules` finishes overlapping the route (route 90.7s − importRules 64.1s) — dominated by exception-item / list write work (`_bulk` + ~1000 `_update_by_query`). Then rule overwrite pays authz + key tax again.

| Rank | Candidate | Union | % txn | n | Pattern | Optimization tip |
|---|---|---:|---:|---:|---|---|
| 1 | `_bulk` | **33.9s** | 36.3% | 43 | Write path | Exception-list + rule linkage writes dominate. |
| 2 | `_has_privileges` | **19.0s** | 20.3% | **2318** | Authz N+1 | Request-scoped cache. |
| 3 | `resolve capabilities` | **13.6s** | 14.6% | **623** | Fan-out / repeated resolve | Cache capabilities per request. |
| 4 | `bulkCreateRulesSo` | **12.1s** | 13.0% | 9 | SO write | Keep; shrink authz/key tax around it. |
| 5 | `invalidateKeys` / mark invalidation | **10.6s** | 11.3% | — | API-key churn | Exception-list-only change shouldn’t need ~600 key grants. |
| 6 | `createAPIKey` + `grant` | **~8.5s** | 9.1% | ~595 | API-key churn | Same as tip 5. |
| 7 | `space:default` GET | **7.7s** | 8.2% | **663** | N+1 ES | Cache space doc once per request. |
| 8 | `_update_by_query` | **3.2s** | 3.4% | **1000** | N+1 ES (items) | Early-phase item path (~1/rule). |
| 9 | `pre-route` | **2.9s** | 3.1% | 1 | Fixed tax | Later. |

**Highest leverage for C2:** stop key rotate on exception-only overwrite + cache `resolve capabilities` / space GET + authz cache. `_bulk` ~34s is real write work — secondary after removing unnecessary key/authz tax.

Contrast with B2: C2 has almost no `_mget` but huge `resolve capabilities` + space GETs + more `_bulk`, plus a long pre-`importRules` exception write phase.

---

### B2 (#12) — add extra connector (all 1000 rules change)

`POST /api/detection_engine/rules/_import` with `overwrite=true` — `1000enabled.rules+2connectors-email-smtp-cases.ndjson`.

`trace.id=6fe628511b8003e7ceb700b6e7c1e3c8` · 46.0s · started=10000 · dropped=1533 🚨 incomplete — rankings under-count late spans.

| Rank | Candidate | Union | % txn | n | Pattern | Optimization tip |
|---|---|---:|---:|---:|---|---|
| 1 | `_bulk` | **13.1s** | 28.4% | 17 | Serial / write path | Check batch size / payload on connector update bulks. |
| 2 | `_has_privileges` | **11.9s** | 25.9% | **4911** | Authz N+1 / cache | Sum ≫ union → already parallel; cut **count**. |
| 3 | `invalidateKeys` / mark invalidation | **8.2s** | 17.8% | — | API-key churn | On connector-add: invalidate/regrant only rules whose action authz changed. |
| 4 | `prepareUpdate` | **8.0s** | 17.5% | 7 | Update prep | Fast-path when only `actions[]` / connectors change. |
| 5 | `bulkCreateRulesSo` (putAttempt) | **8.0s** | 17.3% | 8 | SO write | Keep; shrink prep/authz around it. |
| 6 | `_mget` | **7.3s** | 15.9% | **1498** | Read amplification | Batch/dedupe SO loads in update + action/connector path. |
| 7 | `createAPIKey` + `api_key/grant` | **~4.2s** each | 9.2% | ~705 | API-key churn (double-count) | Pair with tip 3. |
| 8 | cases `_search` | **3.0s** | 6.4% | **1011** | ~1/rule | Batch or cache. |
| 9 | `pre-route` middlewares | **2.2s** | 4.8% | 1 | Fixed tax | Later. |

Parent `importRules` ≈ 40.4s (88%).

**Highest leverage for B2:** authz cache → cut `_mget` / slim `prepareUpdate` for actions-only diffs → reduce API-key rotate on connector-only updates.

---

## Recurring themes (`_import` only)

Ordered by breadth × wall impact on this deploy. Unions overlap — do **not** add rows.

| Theme | Scenarios affected | Impact | Why it matters |
|---|---|---|---|
| **1. Request-scoped `_has_privileges` cache** | #1,#2,#5,#9,#10,#11,#12 | **~2.7–19s / ~16–43%** (n≈1k–5k) | Largest N+1 across creates and overwrites. |
| **2. Skip API-key rotate when authz unchanged** | #5,#11,#12 (mild #6) | **invalidate ~8–11s / ~11–28%**; grant ~4–9s / ~9–13% (double-count if added) | Overwrites re-mint keys even when enabled/actions don’t need new credentials. |
| **3. Cache `resolve capabilities` + space doc** | #5,#11 | **resolve ~4–14s / ~12–15%**; space GET ~3–8s / ~8–10% | Explodes on exception overwrite (#11). |
| **4. Dedupe connector / action reads** | #9,#12 | **`_mget` ~6.6–7.3s / ~16–29%**; cases `_search` ~2–3s / ~6–10% | 1000 rules → 1–2 connectors still fan out SO/case lookups. |
| **5. Exception overwrite tax ≫ create** | #11 (vs #10 baseline) | **pre-`importRules` ~27s / ~28%**; `_bulk` ~34s / ~36% on #11 (93.6s vs #10 23.0s) | Exception writes + rule update key/authz tax. |
| **6. Fixed `pre-route` ~2.1–2.9s** | all imports | **~2.0–2.9s / ~3–28%** (dominates short #6) | Visible tax; children poorly attributed (step 4). |
| **7. Bulk-generate remaining keys** | enabled creates (#2,#9,#10) | **grant ~3.4–4.8s / ~15–21%** @ n=1000 | After skips, leftover grants still look per-rule. |

**Already good:** #6 skip-unchanged (~7.4s, 189 spans). **Inherent:** SO `_bulk` / `bulkCreateRulesSo` on real creates/updates.


## Upcoming PRs and their impact

Ran a deeper investigation on the list of tickets shown on issue [#298302 comment](https://github.com/elastic/kibana/issues/298302#issuecomment-6441073219) listing the upcoming PRs and their priority.

The idea is to check each PR against relevant scenarios and see how much "wall clock" time could be addressed in that scenario. Note that wall clock estimates show the whole time being consumed by relevant transactions as % of request, but addressing each PR will only improve _part of the time_, depending on how efficient each change is.

### 1 — Skip Endpoint authz when it no-ops ([#298458](https://github.com/elastic/kibana/issues/298458))

**Plan:** On bulk create/update, Security’s rule-params authorizer always asks Fleet/Endpoint for authz (`getEndpointAuthz` → ES `_has_privileges`) even when the rule has **no** response actions. The ticket skips that call (or caches the answer per request) when response actions are empty / unchanged.

**Why:** Those privilege checks show up here as thousands of `_has_privileges` spans. Cutting the no-op Endpoint path collapses the largest shared N+1 across almost every import. Caveat on this deploy: the span name is generic `_has_privileges` — not labeled “Endpoint” — so measure how many of the n calls are Endpoint-empty vs other authz before claiming 100% of the union. #4 not in this investigation.

| | Claimed | This deploy |
|---|---|---|
| Scenarios | `#1,#2,#4,#5,#9,#10,#11,#12` | `#1,#2,#5,#9,#10,#11,#12` (imports); #4 not measured |
| Impact | ~4–15s / ~17–42% | **~2.7–19s / ~16–43%** |

| Scenario | Evidence |
|---|---|
| #1 | `_has_privileges` **2.7s / 20%** (n=1073) |
| #2 | **4.0s / 24%** (n=1072) |
| #5 | **5.2s / 16%** (n=1208) |
| #9 | **9.8s / 43%** (n=4076) |
| #10 | **4.8s / 21%** (n=1082) |
| #11 | **19.0s / 20%** (n=2318) |
| #12 | **11.9s / 26%** (n=4911) |

---

### 2 — Dedupe connector / action reads ([#273680](https://github.com/elastic/kibana/issues/273680))

**Plan:** Alerting’s per-rule `validateActions` loads connectors via `actionsClient.getBulk` / `listTypes` inside `prepareRule` / `prepareUpdate`. The ticket adds a **bulk** validate path so shared connector ids are fetched once per request instead of once per rule.

**Why:** Connector imports (#9 create, #12 overwrite) fan out `_mget` and cases `_search` roughly once per rule even when all 1000 rules share 1–2 connectors. Deduping those reads removes the connector-specific tax that plain enabled create does not pay. Quote `_mget` alone (**~16–29%**); don’t stack cases/prep into a ~40% claim.

| | Claimed | This deploy |
|---|---|---|
| Scenarios | `#9,#12` only | `#9,#12` only |
| Impact | ~7–13s / ~19–40% | **`_mget` ~6.6–7.3s / ~16–29%**; cases `_search` ~2–3s / ~6–10% (don’t add to `_mget`) |

| Scenario | Evidence |
|---|---|
| #9 | `_mget` **6.6s / 29%** (n=2012); cases `_search` **2.3s / 10%** (n=1012) |
| #12 | `_mget` **7.3s / 16%** (n=1498); cases `_search` **3.0s / 6%** (n=1011) |

---

### 3 — Skip API-key rotate when authz unchanged ([#264911](https://github.com/elastic/kibana/issues/264911))

**Plan:** Overwrite / upgrade paths that only change params (or leave action authz + enabled state alone) still invalidate and re-grant rule API keys. The ticket short-circuits that rotate when credentials do not need to change.

**Why:** On full overwrite (#5), exception-list-only overwrite (#11), and connector-add (#12), APM shows a large `invalidateKeys` / `bulkMarkApiKeysForInvalidation` envelope plus ~hundreds–1000 `createAPIKey`/`grant` calls. Skipping rotate removes that churn without touching real SO writes. Dial claimed **%** to invalidate **~11–28%** here (not 42%); don’t sum invalidate+grant. #4 not measured.

| | Claimed | This deploy |
|---|---|---|
| Scenarios | `#4,#5,#11` (maybe `#12`) | `#5,#11,#12` (mild `#6`); #4 not measured |
| Impact | ~6–18s / ~12–42% | **invalidate ~8–11s / ~11–28%**; grant ~4–9s / ~9–13% |

| Scenario | Evidence |
|---|---|
| #5 | invalidateKeys **9.1s / 28%**; grant ~4.4s / 13% (n≈1007) |
| #11 | invalidate **10.6s / 11%**; grant ~8.5s / 9% (n≈595) |
| #12 | invalidate **8.2s / 18%**; grant ~4.2s / 9% (n≈705) |
| #6 | invalidate **1.0s / 14%** (1 rule only) |

---

### 4 — Exception overwrite path ([#249176](https://github.com/elastic/kibana/issues/249176))

**Plan:** Exception-heavy imports (especially overwrite of shared lists / items) still do expensive list+item write work and then re-touch every linked rule. The ticket targets that path — skip/diff unchanged lists on overwrite and keep exception materialization from dominating the txn.

**Why:** #11 (add one shared list to 21) is the slowest import at **93.6s**. ~**27s (~28%)** sits before/outside the main `importRules` rule batches (exception `_bulk` / UbQ-shaped work); `_bulk` alone is **~34s / 36%**. Themes 1/3/5 also fire on the rule-update half — isolate those before attributing the whole ~70s delta vs #10 create to this ticket.

| | Claimed | This deploy |
|---|---|---|
| Scenarios | mostly `#11` | mostly `#11` (vs `#10` create baseline) |
| Impact | ~25–35s / ~30–42% | **pre-`importRules` ~27s / ~28%**; `_bulk` ~34s / ~36% |

| Scenario | Evidence |
|---|---|
| #11 | txn **93.6s**; pre-`importRules` gap ≈ **26.6s (~28%)**; `_bulk` **33.9s / 36%**; UbQ ×1000 **3.2s / 3%** |
| #10 | create baseline **23.0s** (contrast) |

---

### 5 — Cache resolveCapabilities / space GET ([#299794](https://github.com/elastic/kibana/issues/299794))

**Plan:** When read-auth-editable params change (`exceptions_list`, etc.), bulk update re-runs `resolveCapabilities` (and space doc fetch) **per rule**. The ticket caches that answer once per `KibanaRequest`.

**Why:** Identical capability/space answers today scale with rule count on exception-param overwrites. On #11 that is **~14s / 15%** of resolve alone plus **~8s / 8%** space GETs; #5 is milder. Creates barely hit it. Prefer separate line items over summing resolve+space into one %.

| | Claimed | This deploy |
|---|---|---|
| Scenarios | `#11`, milder `#5` | `#11`, milder `#5` (creates ~0) |
| Impact | ~5–12s / ~15–24% | **resolve ~4–14s / ~12–15%**; space GET ~3–8s / ~8–10% |

| Scenario | Evidence |
|---|---|
| #11 | resolve **13.6s / 15%** (n=623); space GET **7.7s / 8%** (n=663) |
| #5 | resolve **4.1s / 13%** (n=64); space GET **3.1s / 9%** (n=66) |
| creates | resolve ~0.05s on #1,#2,#9,#10 |

---

### 6 — Bulk-generate remaining keys ([#273675](https://github.com/elastic/kibana/issues/273675) + [#299787](https://github.com/elastic/kibana/issues/299787))

**Plan:** Even after skip-rotate, enabled creates (and any path that still needs new keys) call `createAPIKey` / `api_key/grant` (and UIAM grant on serverless) **once per rule**. These tickets batch ES (and UIAM) key grants into fewer round-trips.

**Why:** On enabled creates this deploy still shows ~1000 grants with union **~3.4–4.8s / ~15–21%**. That work is necessary — batching cuts latency/chat without changing semantics. Do after / beside #264911 so overwrite paths stop minting keys they do not need first. High cross-team complexity remains.

| | Claimed | This deploy |
|---|---|---|
| Scenarios | enabled creates/updates | strongest on creates `#2,#9,#10`; overwrites shrink if #3 lands |
| Impact | ~2–5s / ~10–20% | **grant ~3.4–4.8s / ~15–21%** @ n=1000 |

| Scenario | Evidence |
|---|---|
| #2 | grant ~**3.6s / 21%** (n=1000) |
| #9 | grant ~**4.8s / 21%** (n=1000) |
| #10 | grant ~**3.4s / 15%** (n=1000) |


## Instrumentation gaps / missing spans

Parents with large **self** time (inclusive − union of direct children), plus span names from open [#300213](https://github.com/elastic/kibana/pull/300213) that this deploy does **not** emit (`c4c560f2` predates / does not include that PR).

### `#300213` spans — absent on this deploy

PR adds `withSecuritySpan` around four import phases. **Zero** hits for these names across all eight `_import` traces here:

| Span (from #300213) | What it would cover | Why we want it |
|---|---|---|
| `createPromiseFromRuleImportStream` | NDJSON stream → rule/exception/connector parse | Separates upload/parse tax from rule write work |
| `importRuleExceptions` | Exception list/item import before/alongside rules | Names the #11 early phase (today only naked `_bulk` / UbQ) |
| `fetchImportContext` | Existing lists, prebuilt context, existing rules | Shows read-prep before validate/write |
| `validateRulesToImport` | Per-import validation of rule payloads | Splits validate from `importRules` batches |

**Recommendation:** merge/land #300213 (or equivalent) before the next import APM pass — especially before trusting exception-overwrite attributions.

---

### `pre-route handler middlewares` — ~2.1–2.9s, ~99% dark

Present on **every** `_import` (n=1). Direct children are only:

- `GET /_security/_authenticate` (~3–8ms)
- one `POST /_security/user/_has_privileges` (~5–9ms)

| Scenario | pre-route | Child sum | Self (dark) | % of txn |
|---|---:|---:|---:|---:|
| #1 | 2.109s | 0.012s | **2.098s** | 15.6% |
| #2 | 2.076s | 0.010s | **2.067s** | 12.5% |
| #5 | 2.073s | 0.008s | **2.065s** | 6.4% |
| #6 | 2.048s | 0.009s | **2.040s** | **27.8%** |
| #9 | 2.103s | 0.009s | **2.094s** | 9.3% |
| #10 | 2.597s | 0.010s | **2.588s** | 11.3% |
| #11 | 2.880s | 0.016s | **2.864s** | 3.1% |
| #12 | 2.213s | 0.008s | **2.205s** | 4.8% |

On short #6 this is the largest single candidate. Route-handler self on #1/#6 is only ~0.2–0.3s — the mystery is almost entirely inside `pre-route`, not `importRules`.

**Recommend spans** (Core HTTP / security middleware chain — pick stable names via `withSpan` / existing APM middleware hooks):

| Suggested span | Intent |
|---|---|
| `preRoute.authenticate` | Already partly visible as ES authenticate — wrap the Kibana auth layer |
| `preRoute.checkPrivileges` / license / feature gates | Whatever runs after auth before the handler (today unlabeled) |
| `preRoute.encryptedSavedObjects` / `preRoute.uiSettings` (if applicable) | Only if code review shows them on this path |
| Keep parent `pre-route handler middlewares` | Envelope; optimize once children exist |

Until children exist, treat ~2.1s as a **fixed import tax** and a Core instrumentation gap — not a Detection Rules logic bug.

---

### `#11` exception phase — long dark *named* work, wrong labels

Route handler starts; first `DetectionRulesClient.importRules` begins ~**26.6s** later. Early-phase unions (before that first batch):

| Candidate | Union | n | Note |
|---|---:|---:|---|
| `_bulk` | **17.1s** | 24 | Exception list/item writes (inferred) |
| `_update_by_query` | **3.2s** | **1000** | Per-item / per-rule UbQ shape |
| `_has_privileges` | **2.2s** | 97 | Authz during exception path |
| PIT / `_search` / `_mget` | ~1–2s combined | tens | Supporting reads |

Wall is visible; **product meaning is not** — no `importRuleExceptions` (or list/item sub-spans).

**Recommend** (in addition to #300213’s `importRuleExceptions`):

| Suggested span | Intent |
|---|---|
| `importExceptionLists` / `importExceptionListItems` | Split list SO vs item writes |
| `exceptionItems.bulkCreate` / `exceptionItems.updateByQuery` | Tie UbQ ×1000 to a code path |
| `linkRulesToExceptionLists` (if separate) | Rule-ref updates vs item materialization |

---

### Alerting framework — dark / mislabeled under known parents

Alerting already emits envelopes (`prepareRule` / `prepareUpdate`, `bulkCreateRulesSo`, `invalidateKeys`, `createAPIKey`). Probed those parents on #2, #5, #9, #11, #12 for **self-time** and missing domain names. Three gaps:

#### 1. No `validateActions` / `actionsClient` spans (connector path)

On #9 / #12, `prepareRule` / `prepareUpdate` wall is mostly children — but those children are only naked ES / key spans (`_has_privileges`, `_mget`, `createAPIKey`). **Zero** hits for `validateActions`, `actionsClient.getBulk`, or `listTypes` across these traces.

| Scenario | Under `prepare*` (evidence) |
|---|---|
| #9 | `prepareRule` union **7.3s**; children include `_mget` ×**2000**, `_has_privileges` ×**3000**, `createAPIKey` ×1000 — no Alerting validate span |
| #12 | `prepareUpdate` union **8.0s**; `_mget` ×**732**+ among children — same gap |

Cases index `_search` ×~1011 on #9/#12 likewise has no named Alerting/actions parent.

**Recommend:** `validateActions`, `actionsClient.getBulk` / `listTypes` (and cases lookup if separate) so #273680 shows up as a named parent over `_mget`.

#### 2. `loadPending.loadRulesByIds` — large self on overwrites

Parent loads existing rules before update. ES children (PIT + `_search`) do **not** explain most of the wall — hydration / decode looks unlabeled.

| Scenario | Parent union | Summed self | Accounted children |
|---|---:|---:|---|
| #5 | 2.7s | **~1.9s** | `_search` + PIT open/close |
| #12 | 2.7s | **~2.0s** | same |
| #11 | 5.3s | **~2.6s** | same |

**Recommend:** sub-spans e.g. `loadRulesByIds.search` vs `loadRulesByIds.hydrate` (or equivalent).

#### 3. `bulkCreateRulesSo` — ~2–3s self beyond `_bulk`

Create/update SO write parent: direct children are basically `_bulk` + tiny `_mget`. Remaining self is unlabeled (serialize / encrypt / mapping / prep).

| Scenario | Parent union | Summed self (across batches) |
|---|---:|---:|
| #2 | 6.4s | **~2.0s** |
| #9 | 5.5s | **~2.3s** |
| #5 | 8.7s | **~2.4s** |
| #12 | 8.0s | **~2.2s** |
| #11 | 12.1s | **~3.3s** |

**Recommend:** sub-spans under `bulkCreateRulesSo` for build-docs / encrypt / ES `_bulk` (keep the parent as envelope).

Also still useful (Security authorizer / caps, called from prepare paths):

| Gap | Evidence | Suggested span |
|---|---|---|
| Endpoint / Fleet authz vs other `_has_privileges` | Generic ES span under `prepare*`; #298458 needs proof of share | `authorizeRuleParams` / `endpointAuthz` |
| Caps / space on param edits | `resolve capabilities` + `space:default` GET on #5/#11 | `getRulesAuthz` (ties to #299794) |

---

### Suggested instrumentation order

1. **Land #300213** four spans (especially `importRuleExceptions` + `createPromiseFromRuleImportStream`).
2. **Explode `pre-route`** — ~2.1s fixed tax, ~99% unlabeled; blocks understanding #6 and every import header.
3. **Label `validateActions` / `actionsClient.getBulk`** so #273680 is a named parent over `_mget`.
4. **Label authz sources** (`endpointAuthz` vs generic privileges) so #298458 impact is measurable.
5. **`loadRulesByIds` hydrate vs search** — ~2s self on overwrites.
6. **`bulkCreateRulesSo` sub-spans** — ~2–3s self beyond `_bulk`.
7. Exception list vs item sub-spans under `importRuleExceptions` for #249176.

