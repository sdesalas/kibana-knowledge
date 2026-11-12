# Full bench r3: main-at-545231e vs PR 🔴 #304858 (ECH)

Third dual-stack wall clock of the fourteen detection-rule scenarios (re-bench after r1/r2 host-noise suspicion).
Timed **Action** steps only (seeds/wipes not timed). APM section is **txn pointers + span counts only** (no dig).

**PR:** [🔴 #304858](https://github.com/elastic/kibana/pull/304858) — skip Endpoint authz when rules have no response actions (and cache when needed).

**Prior stamps:**
- r1: `.knowledge/benchmarks/2026-11-11T1706.full-bench-main5452-vs-pr304858/`
- r2: `.knowledge/benchmarks/2026-11-12T0815.full-bench-main5452-vs-pr304858-r2/`

**Span result (headline):** same shape as r1/r2 — PR has **~1000 fewer spans** on scenarios **#1–#5, #9–#12**. Flat on **#6, #7, #8, #13, #14**.

**Wall result (headline):** still noisy. Clear-ish PR time wins this run: **#5** (−2.9s / −9.0%) and **#10** (−1.9s / −8.3%). Mild PR wins on **#1–#4, #12**. Still worse on PR for **#7 / #8 / #9 / #11 / #13**.


## Targets

Both stacks: **2GB Kibana** (`sdesalas3_security_oom_testing`, `gcp-us-west2`).

| Label | Deployment | Kibana build | Role |
|---|---|---|---|
| **main** | `main-at-545231e` (`main-at-545231e-f7ad8f.kb.us-west2.gcp.elastic-cloud.com`) | `545231ed4724a3b6422dc6313c67c2648b4b026e` | Baseline (`main`) |
| **PR** | `sdesalas.pr.304858.skip-endpoint-authz` (`sdesalas-pr-304858-skip-endpoint-authz-44a5f2.kb.us-west2.gcp.elastic-cloud.com`) | `67f870e867a4c1b4d6e1e07ccc15289ebfabdd74` | PR image `kibana-cloud-pr:9.7.0-SNAPSHOT-67f870e8…` |

Wall-clock window: `2026-11-12T08:52:41Z` → `2026-11-12T09:07:06Z` (per-step UTC in `windows.tsv`).

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
| 1 | A1 | Create 1,000 disabled rules | 14.9s | 14.1s | −0.8s | −5.3% |
| 2 | A3 | Create 1,000 enabled rules | 16.6s | 16.1s | −0.5s | −3.0% |
| 3 | A2 | Enable 1,000 disabled rules | 14.0s | 13.3s | −0.7s | −5.2% |
| 4 | A4 | Edit 1,000 rules (add tag) | 21.4s | 21.2s | −0.2s | −0.9% |
| 5 | A5 | Fully update 1,000 enabled rules | 32.7s | 29.8s | **−2.9s** | **−9.0%** |
| 6 | A6 | Update 1 of 1,000 (999 unchanged) | 8.0s | 8.3s | +0.2s | +2.7% |
| 7 | A7 | Disable 1,000 enabled rules | 13.3s | 14.9s | +1.6s | +12.0% |
| 8 | A8 | Delete 1,000 rules (no gaps) | 14.8s | 17.2s | +2.4s | +15.9% |
| 9 | B1 | Create 1,000 enabled + 1 connector | 27.0s | 29.5s | +2.4s | +9.0% |
| 10 | C1 | Create 1,000 rules + 20 shared lists | 23.4s | 21.5s | **−1.9s** | **−8.3%** |
| 11 | C2 | Update +1 shared list (to 21) | 77.1s | 84.1s | +7.0s | +9.1% |
| 12 | B2 | Update 1,000 rules (+ extra connector) | 47.6s | 47.1s | −0.5s | −1.0% |
| 13 | C3 | Delete 1,000 rules (with gaps) | 21.2s | 25.3s | +4.1s | +19.1% |
| 14 | C4 | Delete 21 shared exception lists | 6.2s | 6.1s | −0.1s | −1.8% |

### Notes on wall-clock

- Clearest PR improvements this run: **#5** and **#10**. Mild wins on **#1–#4, #12**.
- Still worse on PR for **#7 disable**, **#8 / #13 delete**, **#9** connector create, **#11** list overwrite — same host/noise pattern as r1/r2 on paths with flat spans (#7/#8/#13) or fat requests.
- **#6** `rules_summary`: `updated=1,skipped=999` on both sides.
- Both stacks ran **in parallel** (same driver step).


## r1 / r2 / r3 comparison

Δ = PR − main. % = (PR − main) / main × 100. **avg** = mean of r1+r2+r3. Same deploys / builds.

### Wall clock

| # | Step | r1 Δ | r2 Δ | r3 Δ | avg Δ | avg % | note |
|---|---|---:|---:|---:|---:|---:|---|
| 1 | A1 | +0.8s | +0.9s | −0.8s | +0.3s | +2.5% | flipped PR win in r3 |
| 2 | A3 | −1.8s | **−3.8s** | −0.5s | **−2.0s** | **−11.5%** | PR win all three; size bounces |
| 3 | A2 | +1.4s | +1.2s | −0.7s | +0.6s | +4.9% | flipped PR win in r3 |
| 4 | A4 | **−3.4s** | −0.7s | −0.2s | −1.4s | −5.9% | PR win shrinks |
| 5 | A5 | +0.6s | **−3.3s** | **−2.9s** | **−1.9s** | **−5.6%** | PR win in r2/r3 |
| 6 | A6 | +0.4s | −0.0s | +0.2s | +0.2s | +2.2% | flat |
| 7 | A7 | +1.9s | +2.6s | +1.6s | +2.0s | +15.7% | PR worse all three |
| 8 | A8 | +5.4s | +3.0s | +2.4s | +3.6s | +24.0% | PR worse all three (shrinking) |
| 9 | B1 | +2.9s | +3.2s | +2.4s | +2.8s | +11.6% | PR worse all three |
| 10 | C1 | +1.1s | −0.2s | **−1.9s** | −0.4s | −1.4% | PR win grows in r3 |
| 11 | C2 | +0.3s | −0.7s | +7.0s | +2.2s | +2.9% | r3 outlier (noise) |
| 12 | B2 | +5.5s | +4.7s | −0.5s | +3.2s | +7.3% | flipped flat/PR-win in r3 |
| 13 | C3 | +8.0s | +4.3s | +4.1s | +5.5s | +24.6% | PR worse all three |
| 14 | C4 | −0.1s | +0.5s | −0.1s | +0.1s | +1.4% | flat |

### Spans (Δ = PR − main)

| # | Step | r1 Δ | r2 Δ | r3 Δ | avg Δ |
|---|---|---:|---:|---:|---:|
| 1 | A1 | −1000 | −1000 | −1000 | **−1000** |
| 2 | A3 | −999 | −1002 | −999 | **−1000** |
| 3 | A2 | −1000 | −1000 | −1002 | **−1001** |
| 4 | A4 | −1020 | −1048 | −1045 | **−1038** |
| 5 | A5 | −1030 | −1049 | −1026 | **−1035** |
| 6 | A6 | −1 | 0 | −1 | −1 |
| 7 | A7 | 0 | 0 | 0 | 0 |
| 8 | A8 | +2 | −1 | +1 | +1 |
| 9 | B1 | −999 | −1001 | −1000 | **−1000** |
| 10 | C1 | −1001 | −999 | −1001 | **−1000** |
| 11 | C2 | −984 | −1072 | −957 | **−1004** |
| 12 | B2 | −992 | −1033 | −1056 | **−1027** |
| 13 | C3 | −2 | 0 | 0 | −1 |
| 14 | C4 | 0 | 0 | 0 | 0 |

Three runs: span story is stable (~−1000 on **#1–#5, #9–#12**); wall Δs keep bouncing. Avg wall still shows PR wins on **#2 / #4 / #5**; delete/disable stay worse on PR (noise / unrelated path).


## APM — transaction pointers + span counts

No dig. One HTTP txn per side per timed step. Each `trace.id` links to the transaction in the [monitoring Kibana](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com) (`rangeFrom`/`rangeTo` padded around the bench window). (`service.environment` / `labels.deploymentName` = deploy name).
**Spans** = `transaction.span_count.started` (`dropped` was null on these txns). 📊 links open static waterfalls on [GitHub Pages](https://sdesalas.github.io/kibana-knowledge/benchmarks/published/2026-11-12T0852.full-bench-main5452-vs-pr304858-r3/index.html) (exported for **#1–#5** only).

All Δ = PR − main. Negative = fewer spans / faster on the PR.

| # | Step | main spans | PR spans | Δ spans | main `trace.id` | PR `trace.id` | main 📊 | PR 📊 |
|---|---|---:|---:|---:|---|---|---|---|
| 1 | A1 | 1245 | 245 | **−1000** | [`6ad1311ee46c9138ebd97997314f6d18`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=6ad1311ee46c9138ebd97997314f6d18&transactionId=3cc3decca6b3db1f) | [`4bc2e278f65cae38f238d0536de575bb`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=4bc2e278f65cae38f238d0536de575bb&transactionId=6e6835eccd8b994f) | [📊](https://sdesalas.github.io/kibana-knowledge/benchmarks/published/2026-11-12T0852.full-bench-main5452-vs-pr304858-r3/apm/01-import-1000-disabled.main.html) | [📊](https://sdesalas.github.io/kibana-knowledge/benchmarks/published/2026-11-12T0852.full-bench-main5452-vs-pr304858-r3/apm/01-import-1000-disabled.pr.html) |
| 2 | A3 | 3273 | 2274 | **−999** | [`10d86cd489f6e415e876911b383f095e`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=10d86cd489f6e415e876911b383f095e&transactionId=7388c7a206019d20) | [`0daf2a4bd569d42c212ea3029e4d6dff`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=0daf2a4bd569d42c212ea3029e4d6dff&transactionId=496a11bb673396c8) | [📊](https://sdesalas.github.io/kibana-knowledge/benchmarks/published/2026-11-12T0852.full-bench-main5452-vs-pr304858-r3/apm/02-import-1000-enabled.main.html) | [📊](https://sdesalas.github.io/kibana-knowledge/benchmarks/published/2026-11-12T0852.full-bench-main5452-vs-pr304858-r3/apm/02-import-1000-enabled.pr.html) |
| 3 | A2 | 3104 | 2102 | **−1002** | [`2a608c63af8bf96537c20ce0b063e5f0`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=2a608c63af8bf96537c20ce0b063e5f0&transactionId=eabef70b295801fe) | [`92509c0df540687d09caf6e26cff553f`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=92509c0df540687d09caf6e26cff553f&transactionId=2d666688dc42b1b7) | [📊](https://sdesalas.github.io/kibana-knowledge/benchmarks/published/2026-11-12T0852.full-bench-main5452-vs-pr304858-r3/apm/03-enable-1000-disabled.main.html) | [📊](https://sdesalas.github.io/kibana-knowledge/benchmarks/published/2026-11-12T0852.full-bench-main5452-vs-pr304858-r3/apm/03-enable-1000-disabled.pr.html) |
| 4 | A4 | 3190 | 2145 | **−1045** | [`97d368727bce33d143ea42a8c3f0706c`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=97d368727bce33d143ea42a8c3f0706c&transactionId=3cd453cccfcbf414) | [`d756c9f155d1f1c1c589eccfea35b492`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=d756c9f155d1f1c1c589eccfea35b492&transactionId=7ad91d1e9820f3e1) | [📊](https://sdesalas.github.io/kibana-knowledge/benchmarks/published/2026-11-12T0852.full-bench-main5452-vs-pr304858-r3/apm/04-edit-1000-add-tag.main.html) | [📊](https://sdesalas.github.io/kibana-knowledge/benchmarks/published/2026-11-12T0852.full-bench-main5452-vs-pr304858-r3/apm/04-edit-1000-add-tag.pr.html) |
| 5 | A5 | 3739 | 2713 | **−1026** | [`ba54468177b1862975f46e0a047c68ce`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=ba54468177b1862975f46e0a047c68ce&transactionId=2106f64d42fc55e9) | [`9c8fc9a64d86e4bcad86ec1cf4acbdec`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=9c8fc9a64d86e4bcad86ec1cf4acbdec&transactionId=a7f1da5370428d78) | [📊](https://sdesalas.github.io/kibana-knowledge/benchmarks/published/2026-11-12T0852.full-bench-main5452-vs-pr304858-r3/apm/05-import-full-update-1000-enabled.main.html) | [📊](https://sdesalas.github.io/kibana-knowledge/benchmarks/published/2026-11-12T0852.full-bench-main5452-vs-pr304858-r3/apm/05-import-full-update-1000-enabled.pr.html) |
| 6 | A6 | 221 | 220 | −1 | [`aac6da87731c0966e3dbf0c65e56dfea`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=aac6da87731c0966e3dbf0c65e56dfea&transactionId=85089e0a9d435323) | [`66e6c6abe89f91263002c2263e9c779d`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=66e6c6abe89f91263002c2263e9c779d&transactionId=4bf22b313133627e) | — | — |
| 7 | A7 | 114 | 114 | 0 | [`9d19cdc735686745bca09e9d47a50fed`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=9d19cdc735686745bca09e9d47a50fed&transactionId=a55fd2aa45cbbcd1) | [`4d4ac31b5b4e6bce13c2ff38d38f47e9`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=4d4ac31b5b4e6bce13c2ff38d38f47e9&transactionId=2a4a208266d2bfbb) | — | — |
| 8 | A8 | 3095 | 3096 | +1 | [`fb100a480b193e81e36a8fc7c154a254`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=fb100a480b193e81e36a8fc7c154a254&transactionId=7bb2eb3ff62521ce) | [`dd15e690eb1cd1c25c9f53551923a878`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=dd15e690eb1cd1c25c9f53551923a878&transactionId=c7bc665c5a7b397b) | — | — |
| 9 | B1 | 9282 | 8282 | **−1000** | [`ca8f4769e1672e8581e911a6d82854a8`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=ca8f4769e1672e8581e911a6d82854a8&transactionId=97b5715b4e79387d) | [`35b70410f3e36a0ef0a91db9993a5596`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=35b70410f3e36a0ef0a91db9993a5596&transactionId=192718d950bf372e) | — | — |
| 10 | C1 | 3298 | 2297 | **−1001** | [`483d811ba72a3fb2203ac35387a3e719`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=483d811ba72a3fb2203ac35387a3e719&transactionId=04c7dda2c6077981) | [`ec26f3fe6f1e3151d60e327392b199f6`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=ec26f3fe6f1e3151d60e327392b199f6&transactionId=e8cd91b0966e18c9) | — | — |
| 11 | C2 | 8783 | 7826 | **−957** | [`3209a8665725644f79919e4d7213b20a`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=3209a8665725644f79919e4d7213b20a&transactionId=643b12371500f752) | [`3f78f5930019f6f58826e8fd5c211fb7`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=3f78f5930019f6f58826e8fd5c211fb7&transactionId=0123e0e5edd66459) | — | — |
| 12 | B2 | 11547 | 10491 | **−1056** | [`12463cb69e58444086f76be833e324e4`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=12463cb69e58444086f76be833e324e4&transactionId=c01d0f3e4911c527) | [`4101e39406a2832f37d50152f48eaa72`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_import&traceId=4101e39406a2832f37d50152f48eaa72&transactionId=ffc2b0284d46a657) | — | — |
| 13 | C3 | 3093 | 3093 | 0 | [`b2ac985c84e12d9379b2ff45f637f8f1`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=b2ac985c84e12d9379b2ff45f637f8f1&transactionId=82024f3d103d7cc9) | [`dce18d92fb11e57f2f25fe01d9a1279b`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Fapi%2Fdetection_engine%2Frules%2F_bulk_action&traceId=dce18d92fb11e57f2f25fe01d9a1279b&transactionId=cb0308e0ecafec2b) | — | — |
| 14 | C4 | 1380 | 1380 | 0 | [`b0a62e26e7f3766b38ba2f43496c977b`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Finternal%2Fapi%2Fexception_lists%2F_bulk_action&traceId=b0a62e26e7f3766b38ba2f43496c977b&transactionId=147bf8b628ce4aed) | [`1a7b4e28ab54f3315b0bef0a85e1dd85`](https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com/app/apm/services/kibana/transactions/view?anomalyThreshold=major&comparisonEnabled=true&environment=ENVIRONMENT_ALL&kuery=&latencyAggregationType=avg&offset=1d&rangeFrom=2026-11-12T08%3A52%3A00.000Z&rangeTo=2026-11-12T09%3A08%3A00.000Z&serviceGroup=&showCriticalPath=&transactionType=request&transactionName=POST+%2Finternal%2Fapi%2Fexception_lists%2F_bulk_action&traceId=1a7b4e28ab54f3315b0bef0a85e1dd85&transactionId=8c0bfba3e2738c28) | — | — |

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

Same as r1/r2. Authz N+1 is real; wall clock still often dominated by other work / host variance on 2GB ECH.

Raw: `timings.tsv`, `windows.tsv`, `logs/`, `apm/txn_pointers.tsv`.
