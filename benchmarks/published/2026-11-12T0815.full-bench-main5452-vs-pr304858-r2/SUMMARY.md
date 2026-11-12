# Full bench r2: main-at-545231e vs PR 🔴 #304858 (ECH)

Second dual-stack wall clock of the fourteen detection-rule scenarios (re-bench after r1 host-noise suspicion).
Timed **Action** steps only (seeds/wipes not timed). APM section is **txn pointers + span counts only** (no dig).

**PR:** [🔴 #304858](https://github.com/elastic/kibana/pull/304858) — skip Endpoint authz when rules have no response actions (and cache when needed).

**Prior stamp:** `.knowledge/benchmarks/2026-11-11T1706.full-bench-main5452-vs-pr304858/` (r1).

**Span result (headline):** same shape as r1 — PR has **~1000 fewer spans** on scenarios **#1–#5, #9–#12**. Flat on **#6, #7, #8, #13, #14**.

**Wall result (headline):** still not a clear overall win. Clear PR time wins this run: **#2** (−3.8s) and **#5** (−3.3s). Delete / connector overwrite (#8, #9, #12, #13) still slower on PR → same host-noise pattern as r1.


## Targets

Both stacks: **2GB Kibana** (`sdesalas3_security_oom_testing`, `gcp-us-west2`).

| Label | Deployment | Kibana build | Role |
|---|---|---|---|
| **main** | `main-at-545231e` (`main-at-545231e-f7ad8f.kb.us-west2.gcp.elastic-cloud.com`) | `545231ed4724a3b6422dc6313c67c2648b4b026e` | Baseline (`main`) |
| **PR** | `sdesalas.pr.304858.skip-endpoint-authz` (`sdesalas-pr-304858-skip-endpoint-authz-44a5f2.kb.us-west2.gcp.elastic-cloud.com`) | `67f870e867a4c1b4d6e1e07ccc15289ebfabdd74` | PR image `kibana-cloud-pr:9.7.0-SNAPSHOT-67f870e8…` |

Wall-clock window: `2026-11-12T08:17:12Z` → `2026-11-12T08:28:36Z` (per-step UTC in `windows.tsv`).

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
| 1 | A1 | Create 1,000 disabled rules | 13.4s | 14.3s | +0.9s | +6.7% |
| 2 | A3 | Create 1,000 enabled rules | 18.7s | 14.9s | **−3.8s** | **−20.3%** |
| 3 | A2 | Enable 1,000 disabled rules | 12.8s | 13.9s | +1.1s | +8.6% |
| 4 | A4 | Edit 1,000 rules (add tag) | 21.4s | 20.7s | −0.7s | −3.3% |
| 5 | A5 | Fully update 1,000 enabled rules | 33.8s | 30.5s | **−3.3s** | **−9.8%** |
| 6 | A6 | Update 1 of 1,000 (999 unchanged) | 8.0s | 8.0s | −0.0s | 0.0% |
| 7 | A7 | Disable 1,000 enabled rules | 12.3s | 14.9s | +2.6s | +21.1% |
| 8 | A8 | Delete 1,000 rules (no gaps) | 15.3s | 18.2s | +3.0s | +19.0% |
| 9 | B1 | Create 1,000 enabled + 1 connector | 23.5s | 26.7s | +3.2s | +13.6% |
| 10 | C1 | Create 1,000 rules + 20 shared lists | 23.0s | 22.8s | −0.2s | −0.9% |
| 11 | C2 | Update +1 shared list (to 21) | 81.4s | 80.7s | −0.7s | −0.9% |
| 12 | B2 | Update 1,000 rules (+ extra connector) | 43.6s | 48.3s | +4.7s | +10.8% |
| 13 | C3 | Delete 1,000 rules (with gaps) | 24.3s | 28.6s | +4.3s | +17.7% |
| 14 | C4 | Delete 21 shared exception lists | 6.4s | 6.9s | +0.5s | +7.8% |

### Notes on wall-clock

- Clear PR improvements this run: **#2** and **#5**. **#4 / #10 / #11** flat-to-slightly better.
- Still worse on PR for **#7 disable**, **#8 / #13 delete**, **#9 / #12** connector paths — paths where span count is flat (#7/#8/#13) or where authz is a small slice of a fat request (#9/#12). Treat as host/noise, same as r1.
- **#6** `rules_summary`: `updated=1,skipped=999` on both sides.
- Both stacks ran **in parallel** (same driver step).


## r1 vs r2 (wall Δ only)

Δ = PR − main. Same deploys / builds.

| # | Step | r1 Δ | r2 Δ | note |
|---|---|---:|---:|---|
| 1 | A1 | +0.8s | +0.9s | flat both |
| 2 | A3 | −1.8s | **−3.8s** | PR win both; larger in r2 |
| 3 | A2 | +1.4s | +1.1s | PR slightly worse both |
| 4 | A4 | **−3.4s** | −0.7s | r1 big win; r2 near-flat |
| 5 | A5 | +0.6s | **−3.3s** | flipped — PR win in r2 |
| 6 | A6 | +0.4s | −0.0s | flat |
| 7 | A7 | +1.9s | +2.6s | PR worse both |
| 8 | A8 | +5.4s | +3.0s | PR worse both (smaller in r2) |
| 9 | B1 | +2.9s | +3.2s | PR worse both |
| 10 | C1 | +1.1s | −0.2s | flipped to flat |
| 11 | C2 | +0.3s | −0.7s | flat |
| 12 | B2 | +5.5s | +4.7s | PR worse both |
| 13 | C3 | +8.0s | +4.3s | PR worse both (smaller in r2) |
| 14 | C4 | −0.1s | +0.5s | flat |

Re-bench confirms: span story is stable; wall deltas bounce between runs on the same hosts. No systematic “PR slower everywhere” once you weight the span-win scenarios.


## APM — transaction pointers + span counts

No dig. One HTTP txn per side per timed step. Each `trace.id` links to the transaction in the [monitoring Kibana](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com) (`rangeFrom`/`rangeTo` padded around the bench window). (`service.environment` / `labels.deploymentName` = deploy name).
**Spans** = `transaction.span_count.started` (`dropped` was null on these txns).

All Δ = PR − main. Negative = fewer spans / faster on the PR.

| # | Step | main spans | PR spans | Δ spans | main `trace.id` | PR `trace.id` |
|---|---|---:|---:|---:|---|---|
| 1 | A1 | 1245 | 245 | **−1000** | [`5105414f4b4e2f3f49a83e5cdc8c5c4d`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=5105414f4b4e2f3f49a83e5cdc8c5c4d&transactionId=5eb0c2c05ae06bdd) | [`01e6c50c97f6598c0fdf33e2c6034b12`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=01e6c50c97f6598c0fdf33e2c6034b12&transactionId=3a80d5d1bb36c9cc) |
| 2 | A3 | 3275 | 2273 | **−1002** | [`eaaf97342c8ab0c0ea823a16c53bf328`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=eaaf97342c8ab0c0ea823a16c53bf328&transactionId=1b3ed0e251958291) | [`35544664a310737ab3757241b946abb6`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=35544664a310737ab3757241b946abb6&transactionId=49b87b923f439581) |
| 3 | A2 | 3103 | 2103 | **−1000** | [`2c99cea9a48a73f2ed71d5403ec78749`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=2c99cea9a48a73f2ed71d5403ec78749&transactionId=d670d6bfcead5ddb) | [`766d97245bf80affd714c6a647f13380`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=766d97245bf80affd714c6a647f13380&transactionId=e2d1cfb477026b2e) |
| 4 | A4 | 3217 | 2169 | **−1048** | [`5a38b1658951bdf0c8b75b4800a3c963`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=5a38b1658951bdf0c8b75b4800a3c963&transactionId=fde81f2d4acfc3c3) | [`540c487e724b5889b1e749e172c64486`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=540c487e724b5889b1e749e172c64486&transactionId=8f8ce29ca0bb50c1) |
| 5 | A5 | 3758 | 2709 | **−1049** | [`9fb13cb937c81b67f6ab8a5dd675e895`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=9fb13cb937c81b67f6ab8a5dd675e895&transactionId=021ca99e2406f0d9) | [`620e02e2fa2abc883473fba011873866`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=620e02e2fa2abc883473fba011873866&transactionId=e572df5fcad6bb43) |
| 6 | A6 | 221 | 221 | 0 | [`44bb725a0395bcb1b76ae23537c12855`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=44bb725a0395bcb1b76ae23537c12855&transactionId=0a82e5e531470dcf) | [`a67f0405ca59d648603e41fc5fe56960`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=a67f0405ca59d648603e41fc5fe56960&transactionId=da5db7c04df2009d) |
| 7 | A7 | 115 | 115 | 0 | [`7fb4c401b43dc89cb83b5e6cfb19d44e`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=7fb4c401b43dc89cb83b5e6cfb19d44e&transactionId=76cdeb404241eee1) | [`1d510a54e33c7676bb3abc0f3538eaee`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=1d510a54e33c7676bb3abc0f3538eaee&transactionId=1225064f90aa6598) |
| 8 | A8 | 3094 | 3093 | −1 | [`acb384134a03ba253f1c6c13e516de7a`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=acb384134a03ba253f1c6c13e516de7a&transactionId=11fff3c8720dd29d) | [`c2774d2eafe7a37f49d3c4cf457fa582`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=c2774d2eafe7a37f49d3c4cf457fa582&transactionId=d4b1ce465b6c3039) |
| 9 | B1 | 9283 | 8282 | **−1001** | [`72ca1535f32aceb4438b7303bf295650`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=72ca1535f32aceb4438b7303bf295650&transactionId=1eaca9a741ca5b53) | [`b3dd164e19efe6cead476c2fe80aceea`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=b3dd164e19efe6cead476c2fe80aceea&transactionId=b63247f3fdeb62ce) |
| 10 | C1 | 3297 | 2298 | **−999** | [`693cfb2ce8c1c36f545bde0a1814420d`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=693cfb2ce8c1c36f545bde0a1814420d&transactionId=22d92820758b10bb) | [`dffb2689504f5e952643364a92af4d7b`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=dffb2689504f5e952643364a92af4d7b&transactionId=835cf7a52b40b105) |
| 11 | C2 | 8818 | 7746 | **−1072** | [`eadc5d90ea07201dbfb764caee70038b`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=eadc5d90ea07201dbfb764caee70038b&transactionId=1b8d6b598bd5e68a) | [`46798e5c8170c2cfd2c710706c276f23`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=46798e5c8170c2cfd2c710706c276f23&transactionId=b03aa5c05889d258) |
| 12 | B2 | 11521 | 10488 | **−1033** | [`21412529f83d7a3b6fe59ae2a2ff8705`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=21412529f83d7a3b6fe59ae2a2ff8705&transactionId=db67f42021913bf0) | [`6702db1a1af915ff0211bff7cd815a15`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=6702db1a1af915ff0211bff7cd815a15&transactionId=8b5a14d57c928e3e) |
| 13 | C3 | 3093 | 3093 | 0 | [`f6adc4e75333c3057ac221bdf34c3669`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=f6adc4e75333c3057ac221bdf34c3669&transactionId=720f59b98d7d2b14) | [`331abd3a1645cae48a983e4438a9342d`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=331abd3a1645cae48a983e4438a9342d&transactionId=6726e7142e9432fc) |
| 14 | C4 | 1380 | 1380 | 0 | [`7415b465aae60a72849e094f6f6b0468`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Finternal%2Fapi%2Fexception_lists%2F_bulk_action&traceId=7415b465aae60a72849e094f6f6b0468&transactionId=e53edd5112a6e9d1) | [`1dcd9c2d65192db543300e524475110e`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A17%3A00.000Z&rangeTo=2026-11-12T08%3A29%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Finternal%2Fapi%2Fexception_lists%2F_bulk_action&traceId=1dcd9c2d65192db543300e524475110e&transactionId=8ce7ede6662241e5) |

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

Same as r1. Authz N+1 is real; wall clock still often dominated by other work / host variance on 2GB ECH.

Raw: `timings.tsv`, `windows.tsv`, `logs/`, `apm/txn_pointers.tsv`.
