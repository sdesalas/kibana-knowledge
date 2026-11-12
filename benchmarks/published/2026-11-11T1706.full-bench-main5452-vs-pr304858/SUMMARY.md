# Full bench: main-at-545231e vs PR 🔴 #304858 (ECH)

Dual-stack wall clock of the fourteen detection-rule scenarios on Elastic Cloud Hosted.
Timed **Action** steps only (seeds/wipes not timed). APM section is **txn pointers + span counts only** (no dig).

**PR:** [🔴 #304858](https://github.com/elastic/kibana/pull/304858) — skip Endpoint authz when rules have no response actions (and cache when needed).

**Span result (headline):** PR has **~1000 fewer spans** on scenarios **#1–#5, #9–#12** (import create/overwrite, enable, edit) — **not** on **#7 disable** or **#8 / #13 delete** (those stay flat; also flat on #6 skip path and #14 list delete). Wall clock is mostly flat; **#2** and **#4** are the only clear time wins.


## Targets

Both stacks: **2GB Kibana** (`sdesalas3_security_oom_testing`, `gcp-us-west2`).

| Label | Deployment | Kibana build | Role |
|---|---|---|---|
| **main** | `main-at-545231e` (`main-at-545231e-f7ad8f.kb.us-west2.gcp.elastic-cloud.com`) | `545231ed4724a3b6422dc6313c67c2648b4b026e` | Baseline (`main`) |
| **PR** | `sdesalas.pr.304858.skip-endpoint-authz` (`sdesalas-pr-304858-skip-endpoint-authz-44a5f2.kb.us-west2.gcp.elastic-cloud.com`) | `67f870e867a4c1b4d6e1e07ccc15289ebfabdd74` | PR image `kibana-cloud-pr:9.7.0-SNAPSHOT-67f870e8…` |

Wall-clock window: `2026-11-11T17:07:46Z` → `2026-11-11T17:21:54Z` (per-step UTC in `windows.tsv`).

Scripts: `.knowledge/scripts/bulk-primitives/`. Fixtures: `.knowledge/data/rules-import/`.
Import flags: `overwrite=true&overwrite_exceptions=true&overwrite_action_connectors=true`.


## Scenarios

| # | Scenario | Related PRs |
|---|---|---|
| 1 | Import → Create 1,000 disabled rules. | 🔴 #304858 |
| 2 | Import → Create 1,000 enabled rules. | 🔴 #304858 |
| 3 | Enable 1,000 existing disabled rules. | 🔴 #304858 |
| 4 | Edit 1,000 enabled rules (add tag). | 🔴 #304858 |
| 5 | Import → Fully update 1,000 enabled rules. | 🔴 #304858 |
| 6 | Import → Update 1 of 1,000 (999 unchanged). | |
| 7 | Disable 1,000 enabled rules. | |
| 8 | Delete 1,000 rules (no gaps). | |
| 9 | Import → Create 1,000 enabled + 1 connector. | 🔴 #304858 |
| 10 | Import → Create 1,000 + 20 shared exception lists (50 items each). | 🔴 #304858 |
| 11 | Import → Update +1 shared list (to 21; 50 items each). | 🔴 #304858 |
| 12 | Import → Update +1 connector (actions only). | 🔴 #304858 |
| 13 | Delete 1,000 rules with gaps. | |
| 14 | Delete 21 shared exception lists (`TYPE=detection`). | |

## PRs (short)

| PR | Endpoint / effect |
|---|---|
| **🔴 #304858** | skip/cache Endpoint authz on bulk write when no response actions |

## Endpoints

| Endpoint | Scenarios |
|---|---|
| `POST /api/detection_engine/rules/_import` | 1–2, 5–6, 9–12 |
| `POST /api/detection_engine/rules/_bulk_action` | 3–4, 7–8, 13 |
| `POST /internal/api/exception_lists/_bulk_action` | 14 |


## Methodology

### Branch A — baseline rules (then wipe)

| # | Step | Seed | Action (timed) | Fixture / body |
|---|---|---|---|---|
| 1 | A1 | clean | Import | `1000disabled-rules.ndjson` |
| 3 | A2 | after #1 | `_bulk_action` enable | |
| 2 | A3 | clean | Import | `1000enabled-rules.ndjson` |
| 4 | A4 | after #2 | edit `add_tags: ["bench"]` | |
| 5 | A5 | reseed #2 | Import overwrite | `…all-updated.ndjson` |
| 6 | A6 | reseed #2 | Import overwrite | `…1-updated.ndjson` |
| 7 | A7 | reseed #2 | disable | |
| 8 | A8 | after #7 | delete (no gaps) | |

### Branch B — connectors

| # | Step | Seed | Action (timed) | Fixture |
|---|---|---|---|---|
| 9 | B1 | clean | Import | `…+connector-email-smtp.ndjson` |
| 12 | B2 | after #9 | Import overwrite | `…+2connectors-email-smtp-cases.ndjson` |

### Branch C — exceptions → delete lists

| # | Step | Seed | Action (timed) | Fixture / notes |
|---|---|---|---|---|
| 10 | C1 | clean | Import | `…+20exceptionlists.ndjson` |
| 11 | C2 | after #10 | Import overwrite | `…+21exceptionlists.ndjson` |
| 13 | C3 | #11 + gaps | delete | `GAPS_PER_RULE=3` seed not timed |
| 14 | C4 | after #13 | delete lists | `TYPE=detection` |


## Wall-clock results (curl `time_total`)

Δ = PR − main. Negative = PR faster. % = (PR − main) / main × 100.

| # | Step | Scenario | main | PR | Δ (PR−main) | % |
|---|---|---|---:|---:|---:|---:|
| 1 | A1 | Create 1,000 disabled rules | 13.9s | 14.7s | +0.8s | +5.8% |
| 2 | A3 | Create 1,000 enabled rules | 16.3s | 14.5s | **−1.8s** | **−11.0%** |
| 3 | A2 | Enable 1,000 disabled rules | 13.3s | 14.7s | +1.4s | +10.5% |
| 4 | A4 | Edit 1,000 rules (add tag) | 25.2s | 21.8s | **−3.4s** | **−13.5%** |
| 5 | A5 | Fully update 1,000 enabled rules | 34.6s | 35.2s | +0.6s | +1.7% |
| 6 | A6 | Update 1 of 1,000 (999 unchanged) | 7.8s | 8.2s | +0.4s | +5.1% |
| 7 | A7 | Disable 1,000 enabled rules | 13.7s | 15.6s | +1.9s | +13.9% |
| 8 | A8 | Delete 1,000 rules (no gaps) | 14.6s | 20.0s | +5.4s | +37.0% |
| 9 | B1 | Create 1,000 enabled + 1 connector | 23.7s | 26.5s | +2.9s | +11.8% |
| 10 | C1 | Create 1,000 rules + 20 shared lists | 22.4s | 23.5s | +1.1s | +4.9% |
| 11 | C2 | Update +1 shared list (to 21) | 80.0s | 80.4s | +0.3s | +0.5% |
| 12 | B2 | Update 1,000 rules (+ extra connector) | 45.1s | 50.6s | +5.5s | +12.2% |
| 13 | C3 | Delete 1,000 rules (with gaps) | 21.9s | 29.9s | +8.0s | +36.5% |
| 14 | C4 | Delete 21 shared exception lists | 6.6s | 6.5s | −0.1s | −1.5% |

### Notes on wall-clock

- PR is **not** a clear wall-clock win. Most scenarios are flat-to-slightly-worse; **#2** and **#4** are the only clear PR improvements.
- Span wins and wall wins are not the same set: create/overwrite/enable/edit (#1–#5, #9–#12) drop ~1000 spans; disable/delete (#7, #8, #13) do not. See APM notes below.
- **#8** / **#13** (delete) are worse on PR even though 🔴 #304858 should not change that path much → treat as host/noise, not a product regression signal.
- **#6** `rules_summary`: `updated=1,skipped=999` on both sides.
- Both stacks ran **in parallel** (same driver step).


## APM — transaction pointers + span counts

No dig. One HTTP txn per side per timed step. Each `trace.id` links to the transaction in the [monitoring Kibana](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com) (`rangeFrom`/`rangeTo` padded around the bench window). (`service.environment` / `labels.deploymentName` = deploy name).
**Spans** = `transaction.span_count.started` (`dropped` was null on these txns).

All Δ = PR − main. Negative = fewer spans / faster on the PR.

| # | Step | main spans | PR spans | Δ spans | main `trace.id` | PR `trace.id` |
|---|---|---:|---:|---:|---|---|
| 1 | A1 | 1245 | 245 | **−1000** | [`b2b3eff550ec0a0247a28a8d2efd790c`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=b2b3eff550ec0a0247a28a8d2efd790c&transactionId=67973489b00fc600) | [`0758450d7f0943911722e5ad83a05aaa`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=0758450d7f0943911722e5ad83a05aaa&transactionId=04ed92c50364cf02) |
| 2 | A3 | 3274 | 2275 | **−999** | [`233ac5635ab1fde143d29a9c0cc72794`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=233ac5635ab1fde143d29a9c0cc72794&transactionId=ee1b5a8da8e712cf) | [`b685387cda27e211e0ec7eb3678e50cf`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=b685387cda27e211e0ec7eb3678e50cf&transactionId=fac3d2f6634528ba) |
| 3 | A2 | 3104 | 2104 | **−1000** | [`88ebb1052d973c7043ad6a42ae4a9a8f`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=88ebb1052d973c7043ad6a42ae4a9a8f&transactionId=028d60df49ce486e) | [`91961ba12a2d90d3551c164e2c1a4021`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=91961ba12a2d90d3551c164e2c1a4021&transactionId=5b819f60eb61de4c) |
| 4 | A4 | 3190 | 2170 | **−1020** | [`a2ad0114ec09989f3111466154ad9691`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=a2ad0114ec09989f3111466154ad9691&transactionId=621957e3229322c4) | [`7fabb23c961dfbc357035d01d358a90b`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=7fabb23c961dfbc357035d01d358a90b&transactionId=5a7929f17b5101f6) |
| 5 | A5 | 3780 | 2750 | **−1030** | [`964b4ea5d444a27ae760028cadddce7a`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=964b4ea5d444a27ae760028cadddce7a&transactionId=af03b620e49217a0) | [`5b0f770da5f544c80ccb8ce68497a822`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=5b0f770da5f544c80ccb8ce68497a822&transactionId=e4de3af4ed872e12) |
| 6 | A6 | 221 | 220 | −1 | [`dbd43e898ff00ec8df8a37bb558cfe95`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=dbd43e898ff00ec8df8a37bb558cfe95&transactionId=5ffb753e740a2428) | [`750782e1a10982af4f08ac65b4150d74`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=750782e1a10982af4f08ac65b4150d74&transactionId=4747a9996ad067e2) |
| 7 | A7 | 114 | 114 | 0 | [`8cfa9534d43870d72c2fd8dbf416f7f8`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=8cfa9534d43870d72c2fd8dbf416f7f8&transactionId=50a74b777edbfa1e) | [`26cf0d18f5e883138b2ebabd8409d06e`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=26cf0d18f5e883138b2ebabd8409d06e&transactionId=ebf43a7d480267ed) |
| 8 | A8 | 3094 | 3096 | +2 | [`12d3803e647a4c5008428e48e8fb87b2`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=12d3803e647a4c5008428e48e8fb87b2&transactionId=8707f96930fbe6cd) | [`7e5339decec6c9bfdfcfae9e5df622f5`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=7e5339decec6c9bfdfcfae9e5df622f5&transactionId=df674afb37c4ff96) |
| 9 | B1 | 9284 | 8285 | **−999** | [`4eefe5073e05864b46895b42c400fe66`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=4eefe5073e05864b46895b42c400fe66&transactionId=92e18a9633ae4563) | [`7402ccb4aaa96e9fa79057d16411ca9f`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=7402ccb4aaa96e9fa79057d16411ca9f&transactionId=16375784384e8cde) |
| 10 | C1 | 3298 | 2297 | **−1001** | [`e9fb274c28f9b8a1219ae53bdabab2df`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=e9fb274c28f9b8a1219ae53bdabab2df&transactionId=47e45096fc7d9d47) | [`b64137556edf75c2d9b25541e0f823c8`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=b64137556edf75c2d9b25541e0f823c8&transactionId=c14028e7a21ed37d) |
| 11 | C2 | 8755 | 7771 | **−984** | [`6f22afb8f77aa8725032403118c4983e`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=6f22afb8f77aa8725032403118c4983e&transactionId=1196069c47f414ec) | [`df9ae56242716f090667386dd9f5042c`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=df9ae56242716f090667386dd9f5042c&transactionId=df05ec8fda1ae52c) |
| 12 | B2 | 11539 | 10547 | **−992** | [`bbda10186f083581ae52b8641c599a9d`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=bbda10186f083581ae52b8641c599a9d&transactionId=5d981d2dae1f2b78) | [`fa720e1294bfc82d9fa0e2c698dd9ef6`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=fa720e1294bfc82d9fa0e2c698dd9ef6&transactionId=9952e43a72afadc4) |
| 13 | C3 | 3095 | 3093 | −2 | [`cdb61cb2ced9bdaa132a7af3405e0a8d`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=cdb61cb2ced9bdaa132a7af3405e0a8d&transactionId=0c2fe63f764e959c) | [`7468a4d8401d5caa230d17fc3e41323b`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=7468a4d8401d5caa230d17fc3e41323b&transactionId=14b829dc593b41e3) |
| 14 | C4 | 1380 | 1380 | 0 | [`b01ac000515bfa20944065946192c615`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Finternal%2Fapi%2Fexception_lists%2F_bulk_action&traceId=b01ac000515bfa20944065946192c615&transactionId=5d7646f867d9685b) | [`d62c762f850c912b5b84ad62ec56c89a`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-11T17%3A07%3A00.000Z&rangeTo=2026-11-11T17%3A22%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Finternal%2Fapi%2Fexception_lists%2F_bulk_action&traceId=d62c762f850c912b5b84ad62ec56c89a&transactionId=b04a31c86f3cd05b) |

### Notes on spans

**~1000 fewer spans on the PR** for:
- import create / overwrite — **#1, #2, #5, #9, #10, #11, #12**
- enable — **#3**
- edit — **#4**

**No span win** (flat ± a couple) for:
- **#6** — skip-heavy overwrite (999 unchanged; already cheap)
- **#7** — disable
- **#8, #13** — delete
- **#14** — exception-list delete

Wall clock often did not move with the span drop → authz was real N+1 work, but not the dominant slice of these requests on 2GB ECH.

Raw: `timings.tsv`, `windows.tsv`, `logs/`, `apm/txn_pointers.tsv`.
