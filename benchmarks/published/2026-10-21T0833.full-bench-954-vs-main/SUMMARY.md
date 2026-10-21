# Full bench: 9.5.4 vs main (ECH)

Single run of the fourteen detection-rule performance scenarios on Elastic Cloud Hosted.
Timed **Action** column only (seed steps not timed). This doc is self-contained — you do not need `benchmark-scenarios.md`.


## Targets

Both stacks: **2GB Kibana** (`sdesalas3_security_oom_testing`, `gcp-us-west2`).
Import payload limit: `xpack.securitySolution.maxRuleImportPayloadBytes: 26214400` (25 MiB).

| Label | Deployment | Role |
|---|---|---|
| **9.5.4** | `kibana-9-5-4-55213f` (`kibana-9-5-4-55213f.kb.us-west2.gcp.elastic-cloud.com`) | Baseline (pre 9.5.5/9.5.6/9.6 import perf work) |
| **main** | `main-at-ffa1cb22-d52474` (`main-at-ffa1cb22-d52474.kb.us-west2.gcp.elastic-cloud.com`) | Control with bulk create/update, skip-unchanged, gap batching, exception-list bulk delete |

Wall-clock window: `2026-10-21T08:36:02Z` → `2026-10-21T09:14:05Z` (per-step UTC in `windows.tsv`).

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
| 🟢 [#285608](https://github.com/elastic/kibana/pull/285608) `9.6.0` | Adds `POST /internal/api/exception_lists/_bulk_action`. On builds without it (9.5.4), the bench falls back to a timed loop of `DELETE /api/exception_lists?id=…` so C4 can still be compared. |

## Endpoints

| Endpoint | Scenarios | Usage |
|---|---|---|
| `POST /api/detection_engine/rules/_import` | 1–2, 5–6, 9–12 | Create rules, or import updates with `overwrite=true`. |
| `POST /api/detection_engine/rules/_bulk_action` | 3–4, 7–8, 13 | `enable` (3), `edit`/`add_tags` (4), `disable` (7), `delete` (8, 13). #13 also leaves exception lists for #14. |
| `POST /internal/api/exception_lists/_bulk_action` (main) / `DELETE /api/exception_lists` loop (9.5.4) | 14 | Delete 21 unreferenced `detection` lists — bulk vs single-delete. |


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

Portable SMTP fixtures (`bench-email-connector`). Both sides start from a clean space after A8.

| Step | # | Seed | Action (timed) | Fixture |
|---|---|---|---|---|
| B1 | 9 | clean space | Import | `1000enabled.rules+connector-email-smtp.ndjson` |
| B2 | 12 | B1 (#9) | Import overwrite | `1000enabled.rules+2connectors-email-smtp-cases.ndjson` (actions only; empty `exceptions_list` both sides) |

### Branch C — exceptions → delete lists

Clean space before C1 (rules + lists wiped after B2). Shared lists carry **50 items each**. C2 is a strict supersets of C1 (lists 1–20 unchanged; list 21 added).

| Step | # | Seed | Action (timed) | Fixture / notes |
|---|---|---|---|---|
| C1 | 10 | clean space | Import | `1000enabled.rules+20exceptionlists.ndjson` (20 lists × 50 items) |
| C2 | 11 | C1 (#10) | Import overwrite | `1000enabled.rules+21exceptionlists.ndjson` (21 lists × 50 items) |
| C3 | 13 | C2 + gaps | `_bulk_action` delete | `GAPS_PER_RULE=3 ./parallel_seed_gaps.sh` (not timed) then delete; lists remain |
| C4 | 14 | after C3 | Delete 21 shared lists | `TYPE=detection` via `./parallel_delete_exception_lists.sh` — bulk on main; single-DELETE loop on 9.5.4 |


## Wall-clock results (curl `time_total`)

| Step | # | Scenario | 9.5.4 | main | Δ (954−main) | speedup (954/main) |
|---|---|---|---:|---:|---:|---:|
| A1 | 1 | Create 1,000 disabled rules | 43.8s | 13.7s | +30.0s | 3.2× |
| A2 | 3 | Enable 1,000 disabled rules | 31.5s | 12.7s | +18.8s | 2.5× |
| A3 | 2 | Create 1,000 enabled rules | 87.2s | 16.0s | +71.2s | 5.5× |
| A4 | 4 | Edit 1,000 rules (add tag) | 35.2s | 22.4s | +12.8s | 1.6× |
| A5 | 5 | Fully update 1,000 enabled rules | 86.9s | 33.8s | +53.1s | 2.6× |
| A6 | 6 | Update 1 of 1,000 (999 unchanged) | 91.3s | 8.2s | +83.2s | **11.2×** |
| A7 | 7 | Disable 1,000 enabled rules | 18.8s | 14.3s | +4.5s | 1.3× |
| A8 | 8 | Delete 1,000 rules (no gaps) | 23.7s | 16.2s | +7.5s | 1.5× |
| B1 | 9 | Create 1,000 enabled + 1 connector | 90.5s | 25.1s | +65.4s | 3.6× |
| B2 | 12 | Update 1,000 rules (+ extra connector) | 42.8s | 49.0s | −6.1s | 0.9× |
| C1 | 10 | Create 1,000 rules + 20 shared lists (50 items each) | 118.7s | 24.9s | +93.8s | 4.8× |
| C2 | 11 | Update +1 shared list (to 21; 50 items) | 202.6s | 82.6s | +120.0s | 2.5× |
| C3 | 13 | Delete 1,000 rules (with gaps) | 94.2s | 19.8s | +74.4s | 4.8× |
| C4 | 14 | Delete 21 shared exception lists | **41.7s** (single×21) | **6.1s** (bulk) | +35.7s | **6.9×** |

### Notes on wall-clock

- **#14 (C4):** 9.5.4 has no bulk API — timed loop of 21× `DELETE /api/exception_lists` = **41.7s**. Main bulk = **6.1s** for the same 21 lists (**6.9×**).
- **#12 (B2):** main slower than 9.5.4 (49.0s vs 42.8s). Not a skip scenario — every rule gets a real connector change.
- **#11 (C2)** is the slowest step on both stacks; exception-list linkage updates dominate.
- Biggest deltas: **#6** (skip path), **#11**, **#10 / #2 / #9** (enabled creates), **#13**, **#14**.
- main `rules_summary` where present: A6 `updated=1,skipped=999`; other overwrites `updated=1000`.

Raw: `timings.tsv`, `windows.tsv`, `logs/`.


## Performance investigation

Used APM to investigate performance bottlenecks in **main** for scenarios taking longer than 20s. Ie **A4 (#4)**, **A5 (#5)**, **A8 (#8)**, **B1 (#9)**, **B2 (#12)**, **C1 (#10)**, **C2 (#11)**, and **C3 (#13)**. Span inventory below covers both stacks for every timed step.

### Span counts (9.5.4 vs main)

Per timed step’s HTTP transaction. **Spans** = APM `started + dropped` (attempted). 🚨 = agent hit the span cap (trace incomplete). **ES calls** = recorded spans whose name starts with `Elasticsearch:`. C4 on 9.5.4 is **21×** sequential single-`DELETE` (no bulk API) — spans/ES there are **sums** across those requests; `trace.id` is one sample.

| Step | # | 9.5.4 spans | 9.5.4 ES calls | 9.5.4 `trace.id` | main spans | main ES calls | main `trace.id` |
|---|---|---:|---:|---|---:|---:|---|
| A1 | 1 | 16580 🚨 | 4513 | `ee6671ad5fe3f79b966726b5808fbac5` | 1211 | 1156 | `7ccd4eb13b0fdb9392c23fd7389ebe82` |
| A2 | 3 | 2071 | 1056 | `72272e3879b6542654d08662ac745bbf` | 2073 | 847 | `b293d6e0fe1892592e4e1e8d5fad4927` |
| A3 | 2 | 24578 🚨 | 5100 | `de2c43b52a6ce0c4cce1140e4ad3bc1d` | 3236 | 2171 | `612cb13d326b77c2f3c5a91964d6799c` |
| A4 | 4 | 3085 | 2074 | `786a66edf05ab96dbc5cb42f161e9838` | 3212 | 2160 | `6eff38b9bdef5d8e710f9697d8265d3d` |
| A5 | 5 | 24889 🚨 | 7549 | `d68638bf433b49d51d67ed245bc52f25` | 3674 | 2475 | `bccceda30774cc44d6138bd08b167fdc` |
| A6 | 6 | 24649 🚨 | 7500 | `23ecf9ebba87deef4322f67da1f57a5c` | 189 | 151 | `df1ac8fcc9aad1682f8899795f00067e` |
| A7 | 7 | 111 | 90 | `d0a133e62a17a637429e94eb3b0e3cd3` | 111 | 90 | `498a0bc86acdecfea565a8359172409b` |
| A8 | 8 | 6784 | 5768 | `c06d6d9fc7f335f638c65c50f9fca5dc` | 3090 | 2073 | `72f102d027b67e1410a1478801c0c7b5` |
| B1 | 9 | 30581 🚨 | 6665 | `fbb9b638b28ca66b4d92426aab92c8bd` | 9243 | 7997 | `0fb7873f0ed41516506ce1376078bb98` |
| B2 | 12 | 16601 🚨 | 8840 | `949d3311d3b0535adf61df3d67931464` | 11506 🚨 | 8265 | `d51175516621fce1b4769160acd68db8` |
| C1 | 10 | 24625 🚨 | 5100 | `cfec86a17824f2f599cb2d078a5f94e2` | 3254 | 2189 | `185a9688efb5079e7d742541fa5363ff` |
| C2 | 11 | 25875 🚨 | 7805 | `b24b6dedc8347ebfe5af19d0fd3a2b31` | 8698 | 4846 | `13be4ed38ac636a9a76782839692121d` |
| C3 | 13 | 10484 🚨 | 8888 | `c936b936e2b8dba2e52ea6789bf47ff6` | 3088 | 2071 | `5e9cbcad5a5a379b89a295bf98f6d893` |
| C4 | 14 | 1498 (21×) | 1454 | `c5933f29f893bb711221777f10079c46` | 1336 | 1334 | `86679658f00be9263231f769b6377465` |

---

### A4 (#4) — edit 1,000 rules (add tag)

`POST /api/detection_engine/rules/_bulk_action` — JSON body `{"action":"edit","edit":[{"type":"add_tags","value":["bench"]}]}`.

`trace.id=6eff38b9bdef5d8e710f9697d8265d3d` · 21.0s · started=3212 · dropped=0

Tag edit still mints ~1000 API keys — the expensive part isn’t the tag write.

| Rank | Candidate | Union | % txn | n | Pattern | Optimization tip |
|---|---|---:|---:|---:|---|---|
| 1 | `_has_privileges` | **4.3s** | 20.4% | **1064** | Authz N+1 / cache | Request-scoped privilege cache. |
| 2 | `createAPIKey` + `api_key/grant` | ~4.0s each | 19.0% | **1039** | API-key churn (double-count) | Tag-only edit shouldn’t rotate keys — short-circuit when action authz unchanged. |
| 3 | `_bulk` | **2.7s** | 12.7% | 3 | Serial / write path | Real SO update; secondary after keys/authz. |
| 4 | `bulkMarkApiKeysForInvalidation` | **2.0s** | 9.6% | 1 | API-key churn | Pair with tip 2. |
| 5 | `_search` (misc) | **1.3s** | 6.3% | 12 | Read | Later. |

**Highest leverage for A4:** skip API-key invalidate/regrant on tag-only edit → authz cache.

---

### A5 (#5) — fully update 1,000 enabled rules (overwrite)

`POST /api/detection_engine/rules/_import` with `overwrite=true` — multipart upload of `1000enabled-rules.all-updated.ndjson` (`DELETE=0`).

`trace.id=bccceda30774cc44d6138bd08b167fdc` · 33.1s · started=3674 · dropped=0

All 1000 rules change → skip-unchanged does **not** apply. Path is `bulkUpdateRules` (not create).

| Rank | Candidate | Union | % txn | n | Pattern | Optimization tip |
|---|---|---:|---:|---:|---|---|
| 1 | `_bulk` | **13.9s** | 41.9% | 30 | Serial / write path | Real update write work; check batch size / payload fatness (change-history already small). |
| 2 | `bulkCreateRulesSo` (putAttempt) | **9.2s** | 27.9% | 9 | SO write | Keep; shrink key/authz tax around it. |
| 3 | `invalidateKeys` / `bulkMarkApiKeysForInvalidation` | **9.1s** | 27.6% | — | API-key churn | Full overwrite still rotates ~1000 keys — avoid when action authz / enabled unchanged. |
| 4 | `_has_privileges` | **5.5s** | 16.7% | **1210** | Authz N+1 / cache | Request-scoped privilege cache. |
| 5 | `prepareUpdate` | **5.2s** | 15.7% | 9 | Update prep | Slim when only a subset of fields change (tags/query/etc.). |
| 6 | `createAPIKey` + `api_key/grant` | ~4.8s each | 14.4% | **1006** | API-key churn (double-count) | Pair with tip 3. |
| 7 | `resolve capabilities` | **4.6s** | 13.9% | 65 | Fan-out | Cache per request (same theme as C2). |
| 8 | `space:default` GET | **3.2s** | 9.7% | 67 | N+1 ES | Cache space doc once per request. |
| 9 | `pre-route` middlewares | 2.0s | 6.0% | 1 | Fixed tax | Later. |

Parent `importRules` is 30.7s (93%) — envelope over the above.

**Highest leverage for A5:** stop full API-key rotate on enabled overwrite when actions/authz unchanged → authz / capabilities / space cache → then tune `_bulk`.

---

### A8 (#8) — delete 1,000 rules (no gaps)

`POST /api/detection_engine/rules/_bulk_action` — JSON body `{"action":"delete","query":""}` (no gaps seeded).

`trace.id=72f102d027b67e1410a1478801c0c7b5` · 14.7s · started=3090 · dropped=0

Gap soft-delete is tiny here — leftover cost is elsewhere.

| Rank | Candidate | Union | % txn | n | Pattern | Optimization tip |
|---|---|---:|---:|---:|---|---|
| 1 | `retryIfBulkOperationConflicts` | **9.4s** | 63.9% | 2 | Retry / conflict loop | Envelope over collect + untrack + SO delete — dig why two passes; avoid full re-walk on conflict. |
| 2 | Get rules, collect attributes | **3.6s** | 24.6% | 1 | Read / collect | Batch/stream rule load; don’t hold full graph if delete only needs ids + apiKey ids. |
| 3 | `untrackRuleAlerts` | **3.3s** | 22.3% | **1000** | Per-rule fan-out | Batch alert untrack (1 call / few bulks) instead of ×1000. |
| 4 | `bulkDelete` (SO) | **1.8s** | 12.2% | 1 | SO write | Keep. |
| 5 | `bulkMarkApiKeysForInvalidation` | **1.7s** | 11.8% | 1 | API-key churn | Expected on delete; already batched. |
| 6 | `_bulk` | **1.1s** | 7.6% | 3 | Write path | Secondary. |
| 7 | `_update_by_query` | **0.8s** | 5.2% | **1000** | N+1 ES | Per-rule UbQ on delete path — collapse to query-by-ids / few UbQs (same family as gap batching). |

Parent `bulkDeleteRules` is 13.1s (89%) — envelope.

**Highest leverage for A8:** batch `untrackRuleAlerts` → collapse per-rule `_update_by_query` → shrink conflict-retry re-collect.

---

### B1 (#9) — create 1,000 enabled rules + 1 connector

`POST /api/detection_engine/rules/_import` — multipart upload of `1000enabled.rules+connector-email-smtp.ndjson` (create; space cleaned after A8).

`trace.id=0fb7873f0ed41516506ce1376078bb98` · 24.4s · started=9243 · dropped=0

Create path with connector — heavier than plain enabled create (C1-like) mainly via authz + `_mget` for connector/action resolution.

| Rank | Candidate | Union | % txn | n | Pattern | Optimization tip |
|---|---|---:|---:|---:|---|---|
| 1 | `_has_privileges` | **10.3s** | 42.3% | **4012** | Authz N+1 / cache | Worst authz count of the create digs — cache per request. |
| 2 | `bulkCreateRulesSo` | **6.7s** | 27.6% | 5 | SO write | Keep. |
| 3 | `_mget` | **6.7s** | 27.3% | **1932** | Read amplification | Dedupe connector / action SO loads across 1000 rules (same connector id). |
| 4 | `prepareRule` | **5.9s** | 24.2% | 4 | Create prep | Slim when actions share one connector. |
| 5 | `_bulk` | **4.7s** | 19.1% | 11 | Serial / write path | Secondary. |
| 6 | `createAPIKey` + `api_key/grant` | ~4.6s each | 18.8% | ~962 | API-key churn (double-count) | Expected for enabled create. |
| 7 | cases `_search` | **2.8s** | 11.4% | 1011 | ~1/rule | Batch/cache case connector lookups. |
| 8 | `pre-route` | 2.2s | 8.9% | 1 | Fixed tax | Later. |

Parent `importRules` is 19.0s (78%) — envelope.

**Highest leverage for B1:** authz cache → dedupe `_mget` / cases lookups for shared connector → then create SO/`_bulk`.

---

### B2 (#12) — add extra connector (all 1000 rules change)

`POST /api/detection_engine/rules/_import` with `overwrite=true` — multipart upload of `1000enabled.rules+2connectors-email-smtp-cases.ndjson` (`DELETE=0`; actions-only change).

`trace.id=d51175516621fce1b4769160acd68db8` · 48.2s · started=10000 · dropped=1506 🚨 incomplete (span cap) — rankings under-count late spans; still useful for top costs.

Skip-unchanged does **not** apply. Ranked remaining cost:

| Rank | Candidate | Union | % txn | n | Pattern | Optimization tip |
|---|---|---:|---:|---:|---|---|
| 1 | `_has_privileges` | **14.0s** | 29.0% | **4932** | Authz N+1 / cache | Request-scoped privilege cache. Sum ≫ union → already parallel; cut **count**. |
| 2 | `_bulk` | **12.9s** | 26.8% | 17 | Serial / write path | Check batch size / payload fatness on connector update bulks. |
| 3 | `_mget` | **9.4s** | 19.6% | **1503** | Read amplification | Batch/dedupe SO loads in update + action/connector path. |
| 4 | `bulkCreateRulesSo` (putAttempt) | **8.5s** | 17.6% | 8 | SO write | Keep; shrink prep/authz around it. |
| 5 | `prepareUpdate` | **8.2s** | 17.0% | 7 | Update prep | Fast-path when only `actions[]` / connectors change. |
| 6 | `invalidateKeys` / `bulkMarkApiKeysForInvalidation` | **8.1s** | 16.9% | — | API-key churn | On connector-add: invalidate/regrant only rules whose action authz changed. |
| 7 | `createAPIKey` + `api_key/grant` | ~5.9s each | 12.2% | ~687 | API-key churn (double-count) | Pair with tip 6. |
| 8 | cases `_search` | **3.6s** | 7.5% | 1011 | ~1/rule | Batch or cache action/connector case lookups. |
| 9 | `pre-route` middlewares | 2.4s | 5.0% | 1 | Fixed tax | Later. |

Parent `importRules` is 41.8s (87%) — envelope; optimize children, not the parent.

**Highest leverage for B2:** authz cache → cut `_mget` / slim `prepareUpdate` for actions-only diffs → reduce API-key rotate on connector-only updates.

---

### C1 (#10) — create 1,000 enabled rules + 20 shared lists (50 items each)

`POST /api/detection_engine/rules/_import` — multipart upload of `1000enabled.rules+20exceptionlists.ndjson` (create; rules wiped first).

`trace.id=185a9688efb5079e7d742541fa5363ff` · 24.3s · started=3254 · dropped=0

Create path (`bulkCreateRules`), not update. Relatively clean vs C2 — no key invalidate dance, no huge `_mget`.

| Rank | Candidate | Union | % txn | n | Pattern | Optimization tip |
|---|---|---:|---:|---:|---|---|
| 1 | `bulkCreateRulesSo` | **6.9s** | 28.4% | 5 | SO write | Keep; main create cost. |
| 2 | `_bulk` | **5.4s** | 22.2% | 12 | Serial / write path | Rules + exception materialization; inspect batching if lists grow further. |
| 3 | `_has_privileges` | **4.6s** | 19.0% | **1082** | Authz N+1 / cache | Request-scoped privilege cache. |
| 4 | `prepareRule` | **3.8s** | 15.6% | 5 | Create prep | Keep; secondary after authz/keys. |
| 5 | `createAPIKey` + `api_key/grant` | ~3.5s each | 14.5% | **1000** | API-key churn (double-count) | Expected on enabled create; `refresh=false` already helps union. |
| 6 | `pre-route` middlewares | 2.7s | 11.2% | 1 | Fixed tax | Later. |
| 7 | prebuilt rule asset fetches | ~1.9s | 7.9% | 5 | Asset fetch | Cache across batches in one import. |

Parent `importRules` is 18.8s (77%) — envelope.

**Highest leverage for C1:** authz cache (same as others). Create+key work is largely inherent for 1000 enabled rules; C2’s update tax is the bigger leftover vs this baseline.

---

### C2 (#11) — add one shared exception list (to 21; 50 items; all 1000 rules change)

`POST /api/detection_engine/rules/_import` with `overwrite=true` — multipart upload of `1000enabled.rules+21exceptionlists.ndjson` (`DELETE=0`; +1 shared list vs C1).

`trace.id=13be4ed38ac636a9a76782839692121d` · 81.9s · started=8698 · dropped=0

~28s of the txn runs **before** the first `importRules` batch — dominated by exception-item / list write work (`_bulk` + ~1000 `_update_by_query` calls). Then rule overwrite pays authz + key tax again.

| Rank | Candidate | Union | % txn | n | Pattern | Optimization tip |
|---|---|---:|---:|---:|---|---|
| 1 | `_bulk` | **33.6s** | 41.1% | 44 | Write path | Exception-list + rule linkage writes dominate vs B2; inspect bulk payload / batching for exception refs. |
| 2 | `_has_privileges` | **15.3s** | 18.6% | **2298** | Authz N+1 | Same request-scoped cache as B2. |
| 3 | `resolve capabilities` | **11.9s** | 14.6% | **632** | Fan-out / repeated resolve | Cache capabilities per request; should not scale with rule count like this. |
| 4 | `bulkCreateRulesSo` | **10.8s** | 13.2% | 10 | SO write | Keep; shrink authz/key tax around it. |
| 5 | `invalidateKeys` / mark invalidation | **10.1s** | 12.3% | — | API-key churn | Exception-list-only change shouldn’t need ~600 key grants — short-circuit when actions/enabled unchanged. |
| 6 | `createAPIKey` + `grant` | ~7.6s | 9.3% | ~601 | API-key churn | Same as tip 5. |
| 7 | `space:default` GET | **7.3s** | 9.0% | **661** | N+1 ES | Cache space doc once per request. |
| 8 | `_update_by_query` | **2.3s** | 2.9% | **1000** | N+1 ES (items) | Early-phase item path (~1/rule); low union now but scales with item work — watch as list sizes grow. |
| 9 | `pre-route` | 2.8s | 3.4% | 1 | Fixed tax | Later. |

**Highest leverage for C2:** stop key rotate on exception-only overwrite + cache `resolve capabilities` / space GET + authz cache. `_bulk` ~34s is real write work for exception + rule updates — secondary after removing unnecessary key/authz tax.

Contrast with B2: C2 has almost no `_mget` but huge `resolve capabilities` + space GETs + more `_bulk`, plus a long pre-`importRules` exception write phase. Shared theme: **authz + API keys on every rule**.

---

### C3 (#13) — delete 1,000 rules (with gaps)

`POST /api/detection_engine/rules/_bulk_action` — JSON body `{"action":"delete","query":""}` after `GAPS_PER_RULE=3` seed (not timed).

`trace.id=5e9cbcad5a5a379b89a295bf98f6d893` · 18.9s · started=3088 · dropped=0

Same shape as A8 (no-gaps delete). Batched gap soft-delete is only **~0.4s** — not the wall.

| Rank | Candidate | Union | % txn | n | Pattern | Optimization tip |
|---|---|---:|---:|---:|---|---|
| 1 | `retryIfBulkOperationConflicts` | **12.1s** | 63.9% | 2 | Retry / conflict loop | Same envelope as A8 — avoid full re-walk on conflict. |
| 2 | `untrackRuleAlerts` | **5.3s** | 27.9% | **1000** | Per-rule fan-out | Batch alert untrack (worse than A8’s 3.3s here). |
| 3 | Get rules, collect attributes | **4.5s** | 23.6% | 1 | Read / collect | Stream/ids-only collect. |
| 4 | `bulkMarkApiKeysForInvalidation` | **2.1s** | 10.9% | 1 | API-key churn | Expected; batched. |
| 5 | `bulkDelete` (SO) | **1.2s** | 6.2% | 1 | SO write | Keep. |
| 6 | `_update_by_query` | **1.0s** | 5.2% | **1000** | N+1 ES | Per-rule UbQ on delete — collapse (gap UbQ already batched separately at ~0.4s). |
| 7 | `softDeleteGapsByQuery` | **0.4s** | 2.0% | 1 | Gap cleanup | Already cheap — leave alone. |

**Highest leverage for C3:** same as A8 — batch `untrackRuleAlerts` + collapse per-rule UbQ + shrink conflict-retry. Gap batching (#287065) is already winning.

## Recurring performance themes (big cross-scenario wins)

These show up in multiple investigations. Ordered by breadth × wall impact on **main**.

| Theme | Where it hurts | Typical union (main) | Why it’s a big win |
|---|---|---|---|
| **1. Request-scoped `_has_privileges` cache** | A4, A5, B1, B2, C1, C2 | ~4–15s; n≈1k–5k | Same authz question × rule count. One cache per request collapses the largest N+1 across **import and edit**. Highest ROI single change. |
| **2. Skip API-key rotate when authz unchanged** | A4 (tag edit), A5 (full overwrite), B2 (connector add), C2 (exception-only overwrite) | ~4–10s create/grant + invalidate | Keys are minted/invalidated even when enabled/actions don’t need new credentials. Fixes the “edit is almost as expensive as recreate” feel. |
| **3. Cache `resolve capabilities` + space doc** | A5, C2 (also light on A4) | ~3–12s; n hundreds | Identical GETs/resolves per rule. Cheap once you notice; compounds with authz cache. |
| **4. Dedupe connector / action reads** | B1, B2 | `_mget` ~7–9s; cases `_search` ~3s | 1000 rules → 1 shared connector still fans out SO/case lookups. Batch or memoize by connector id. |
| **5. Batch delete side-effects** | A8, C3 | `untrackRuleAlerts` ~3–5s; per-rule UbQ ~1s | Delete wall is **not** gap cleanup anymore (~0.4s with gaps). It’s untrack ×1000 + conflict-retry re-walk. Same fix helps no-gap and with-gap delete. |
| **6. Exception overwrite tax ≫ create** | C2 vs C1 | C2 82s vs C1 24s | Adding one shared list redoes key/authz/write work for all 1000 rules + a long pre-`importRules` exception write phase. Themes 1–3 first; then inspect exception `_bulk`. |

**Not the main leftover (already improved or inherent):** gap soft-delete on C3; SO `_bulk` / `bulkCreateRulesSo` on creates (real work); skip-unchanged on A6 (already ~8s).

**Suggested attack order:** (1) authz cache → (2) conditional API keys → (3) capabilities/space cache → (4) connector read dedupe → (5) delete untrack/UbQ batching. That stack covers every digged scenario above ~15s except pure create SO time.

### Relevant tickets and coverage

Ticket mappings below distinguish direct implementation coverage, related work and audit homes. The proposed savings still need validation; span durations overlap and must not be added together.

| Theme | Relevant tickets | Coverage and remaining questions |
|---|---|---|
| **1. Request-scoped privilege cache** | [#298458 — Skip Endpoint authz without response actions](https://github.com/elastic/kibana/issues/298458) | **Partial direct match:** #298458 removes unnecessary Endpoint authorization calls and discusses request-scoped caching when response actions exist. It does not establish coverage of every `_has_privileges` source seen in these traces. Attribute the remaining calls through the import/edit audits before extending the fix. |
| **2. Conditional API-key rotation** | [#264911 — Params-only upgrade path](https://github.com/elastic/kibana/issues/264911); [#298281 — Alerting performance epic](https://github.com/elastic/kibana/issues/298281) | **Related work, no exact dedicated match found:** #264911 discusses avoiding key rotation for params-only prebuilt upgrades. It does not cover all tag edits, import overwrites or connector changes here. Investigate which changes can safely retain credentials, including ownership and authorization semantics, and track any new Alerting work under #298281. |
| **3. Capabilities and space-document cache** | No ticket | **Nothing** no dedicated implementation issue found. Identify the callers responsible for repeated capability resolution and space GETs in A5/C2, then determine the appropriate request-scoped cache. |
| **4. Connector/action read deduplication** | [#273680 — Bulk action validation](https://github.com/elastic/kibana/issues/273680) | **Direct match for repeated connector reads:** batches/deduplicates `actionsClient.getBulk` and `listTypes` calls. Confirm the overwrite path is included. The repeated Cases searches in B1/B2 also need attribution; their elimination is not explicit in this ticket's acceptance criteria. |
| **5. Bulk deletion side effects** | [#264895 — Bulk alert untracking and task lookups](https://github.com/elastic/kibana/issues/264895) | **Direct match:** #264895 batches task lookups and alert untracking, including the per-rule `setAlertsToUntracked` / `updateByQuery` pattern, and wires it into delete/disable/enable. Still need to investigate the conflict-retry envelope and repeated rule collection; two wrapper spans alone do not prove two actual conflict retries. |
| **6. Exception overwrite cost** | [#249176 — Exception-heavy import timeouts](https://github.com/elastic/kibana/issues/249176) | **Existing problem ticket:** #249176 covers slow exception imports. Add the C2 evidence there: approximately 28s before the first rule-import batch, followed by rule-update key/authz costs. Separate exception item/list writes from rule-reference updates when investigating; themes 1–3 overlap with this cost. |

[#273675 — Bulk creation of rule API keys](https://github.com/elastic/kibana/issues/273675) is a separate optimization for grants that remain necessary; it does not cover skipping unnecessary rotation in theme 2.

### Trace index

| Step | # | trace.id | duration | started | dropped |
|---|---|---|---:|---:|---:|
| A4 | 4 | `6eff38b9bdef5d8e710f9697d8265d3d` | 21.0s | 3212 | 0 |
| A5 | 5 | `bccceda30774cc44d6138bd08b167fdc` | 33.1s | 3674 | 0 |
| A8 | 8 | `72f102d027b67e1410a1478801c0c7b5` | 14.7s | 3090 | 0 |
| B1 | 9 | `0fb7873f0ed41516506ce1376078bb98` | 24.4s | 9243 | 0 |
| B2 | 12 | `d51175516621fce1b4769160acd68db8` | 48.2s | 10000 | 1506 🚨 |
| C1 | 10 | `185a9688efb5079e7d742541fa5363ff` | 24.3s | 3254 | 0 |
| C2 | 11 | `13be4ed38ac636a9a76782839692121d` | 81.9s | 8698 | 0 |
| C3 | 13 | `5e9cbcad5a5a379b89a295bf98f6d893` | 18.9s | 3088 | 0 |


## References

- [Published one-changed-rule benchmark](https://github.com/elastic/kibana/pull/293948#issuecomment-6172642578)
- [Import performance audit](https://github.com/elastic/kibana/issues/298302)
- [Exception-heavy import investigation](https://github.com/elastic/kibana/issues/249176)
