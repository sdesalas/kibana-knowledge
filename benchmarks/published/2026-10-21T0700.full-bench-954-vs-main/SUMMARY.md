# Full bench: 9.5.4 vs main (ECH)

Single run of the fourteen detection-rule performance scenarios on Elastic Cloud Hosted.
Timed **Action** column only (seed steps not timed). This doc is self-contained — you do not need `benchmark-scenarios.md`.

## Targets

Both stacks: **2GB Kibana** (`sdesalas3_security_oom_testing`, `gcp-us-west2`).

| Label | Deployment | Role |
|---|---|---|
| **9.5.4** | `kibana-9-5-4-55213f` (`kibana-9-5-4-55213f.kb.us-west2.gcp.elastic-cloud.com`) | Baseline (pre 9.5.5/9.5.6/9.6 import perf work) |
| **main** | `main-at-ffa1cb22-d52474` (`main-at-ffa1cb22-d52474.kb.us-west2.gcp.elastic-cloud.com`) | Control with bulk create/update, skip-unchanged, gap batching, exception-list bulk delete |

Wall-clock window: `2026-10-21T07:01:37Z` → `2026-10-21T07:25:03Z` (per-step UTC in `windows.tsv`).

Scripts: `.knowledge/scripts/bulk-primitives/` (`parallel_import_rules.sh`, `parallel_bulk_action.sh`, `parallel_seed_gaps.sh`, `parallel_delete_exception_lists.sh`). Fixtures: `.knowledge/data/rules-import/`.

Import flags on every import: `overwrite=true&overwrite_exceptions=true&overwrite_action_connectors=true`.

Exception fixtures for C1/C2: each shared list has **50 items** (250 items across 5 lists; 300 across 6).


## Scenarios

| # | Scenario | Related PRs |
|---|---|---|
| 1 | Create 1,000 disabled rules. | 🔴 #275695 |
| 2 | Create 1,000 enabled rules. | 🔴 #275695, 🟠 #290306 |
| 3 | Enable 1,000 existing disabled rules, with no other changes. | 🟤 #291560, 🟠 #290306 |
| 4 | Edit 1,000 enabled rules by adding a tag. | 🟤 #291560, 🟠 #290306 |
| 5 | Fully update 1,000 rules while they remain enabled. | 🟤 #291560, 🟠 #290306 |
| 6 | Update 1,000 rules where only one has a real update and the other 999 are unchanged. | 🟤 #291560, 🟠 #290306, 🟡 #293948 |
| 7 | Disable 1,000 existing enabled rules, with no other changes. | 🟤 #291560, 🟠 #290306 |
| 8 | Delete 1,000 rules with no gaps. | 🔵 #287065 |
| 9 | Create 1,000 enabled rules with a single connector. | 🔴 #275695, 🟠 #290306 |
| 10 | Create 1,000 rules with five shared exception lists (50 items each). | 🔴 #275695, 🟠 #290306 |
| 11 | Update 1,000 rules by adding one more shared exception list (50 items), with no other changes. | 🟤 #291560, 🟠 #290306 |
| 12 | Update 1,000 rules by adding an extra connector, with no other changes. | 🟤 #291560, 🟠 #290306 |
| 13 | Delete 1,000 rules with existing gaps. | 🔵 #287065 |
| 14 | Delete 6 shared exception lists after deleting the rules that used them. | 🟢 #285608 |

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

### `POST /internal/api/exception_lists/_bulk_action`

| PR | Impact |
|---|---|
| 🟢 [#285608](https://github.com/elastic/kibana/pull/285608) `9.6.0` | Adds bulk exception-list deletion, batching reference checks and streaming item cleanup in requests of up to 100 lists. **404 on 9.5.4.** |

## Endpoints

| Endpoint | Scenarios | Usage |
|---|---|---|
| `POST /api/detection_engine/rules/_import` | 1–2, 5–6, 9–12 | Create rules, or import updates with `overwrite=true`. |
| `POST /api/detection_engine/rules/_bulk_action` | 3–4, 7–8, 13 | `enable` (3), `edit`/`add_tags` (4), `disable` (7), `delete` (8, 13). #13 also leaves exception lists for #14. |
| `POST /internal/api/exception_lists/_bulk_action` | 14 | `action: delete`; unreferenced `detection` lists; ≤100 ids per request. |


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

Clean space before C1 (rules + lists wiped after B2). Shared lists carry **50 items each**.

| Step | # | Seed | Action (timed) | Fixture / notes |
|---|---|---|---|---|
| C1 | 10 | clean space | Import | `1000enabled.rules+5exceptionlists.ndjson` (5 lists × 50 items) |
| C2 | 11 | C1 (#10) | Import overwrite | `1000enabled.rules+6exceptionlists.ndjson` (6 lists × 50 items) |
| C3 | 13 | C2 + gaps | `_bulk_action` delete | `GAPS_PER_RULE=3 ./parallel_seed_gaps.sh` (not timed) then delete; lists remain |
| C4 | 14 | after C3 | Bulk delete 6 shared lists | `TYPE=detection` via `/internal/api/exception_lists/_bulk_action` |


## Wall-clock results (curl `time_total`)

| Step | # | Scenario | 9.5.4 | main | Δ (954−main) | speedup (954/main) |
|---|---|---|---:|---:|---:|---:|
| A1 | 1 | Create 1,000 disabled rules | 59.3s | 33.5s | +25.8s | 1.8× |
| A2 | 3 | Enable 1,000 disabled rules | 31.0s | 12.8s | +18.2s | 2.4× |
| A3 | 2 | Create 1,000 enabled rules | 86.3s | 17.4s | +68.9s | 5.0× |
| A4 | 4 | Edit 1,000 rules (add tag) | 37.4s | 23.9s | +13.5s | 1.6× |
| A5 | 5 | Fully update 1,000 enabled rules | 91.2s | 32.1s | +59.1s | 2.8× |
| A6 | 6 | Update 1 of 1,000 (999 unchanged) | 91.5s | 8.8s | +82.7s | **10.4×** |
| A7 | 7 | Disable 1,000 enabled rules | 18.1s | 14.3s | +3.8s | 1.3× |
| A8 | 8 | Delete 1,000 rules (no gaps) | 25.4s | 16.0s | +9.4s | 1.6× |
| B1 | 9 | Create 1,000 enabled + 1 connector | 94.8s | 23.0s | +71.8s | 4.1× |
| B2 | 12 | Update 1,000 rules (+ extra connector) | 46.0s | 47.2s | −1.2s | 1.0× |
| C1 | 10 | Create 1,000 rules + 5 shared lists (50 items each) | 95.0s | 19.9s | +75.1s | 4.8× |
| C2 | 11 | Update +1 shared list (50 items) | 106.1s | 52.0s | +54.1s | 2.0× |
| C3 | 13 | Delete 1,000 rules (with gaps) | 31.1s | 18.7s | +12.4s | 1.7× |
| C4 | 14 | Bulk delete 6 shared exception lists | **404** (0.5s) | 1.9s (6 lists) | n/a | n/a |

### Notes on wall-clock

- **#14 on 9.5.4:** `POST /internal/api/exception_lists/_bulk_action` → HTTP 404 (API added in 9.6 / #285608). Main deleted 6 `detection` lists in **1.9s**.
- **#12 (B2) near parity (~46–47s both).** Not a skip scenario — every rule gets a real connector change. On main, B2 (~47s) is slower than B1 create (~23s).
- Biggest deltas: **#6** (skip path), **#2 / #9 / #10** (enabled creates), **#5**, **#11**.
- main `rules_summary` where present: A6 `updated=1,skipped=999`; other overwrites `updated=1000`.

Raw: `timings.tsv`, `windows.tsv`, `logs/`.


## Performance investigation

Deep dig on **main** for **B2 (#12)** and **C2 (#11)** (C4 skipped — already ~2s). Span inventory below covers both stacks for every timed step.
Raw: `apm/analyze-B2.txt`, `apm/analyze-C2.txt`, `apm/discover-*.txt`, `apm/span-counts.tsv`.

### Span counts (9.5.4 vs main)

Per timed step’s HTTP transaction. **Spans** = APM `started + dropped` (attempted). 🚨 = agent hit the 10k span cap (trace incomplete). **ES** = recorded spans whose name starts with `Elasticsearch:` (% of total spans; when 🚨, ES is only from the recorded subset so the % is a lower bound). C4 on 9.5.4 is the **404** stub (API absent).

| Step | # | 9.5.4 spans | 9.5.4 ES | 9.5.4 `trace.id` | main spans | main ES | main `trace.id` |
|---|---|---:|---:|---|---:|---:|---|
| A1 | 1 | 16695 🚨 | 4566 (27%) | `70f94cacb9e1853fb0c16309a4cd2d2a` | 1317 | 1254 (95%) | `3f651b712cfa9ba7558f473ea9a2cd9a` |
| A2 | 3 | 2072 | 1057 (51%) | `6928f4dce5aef11cdd2cd8df9419e907` | 2073 | 934 (45%) | `dd4ddfafc228aea44e6a49fae7d769cd` |
| A3 | 2 | 24578 🚨 | 5100 (21%) | `8f9fab0e05b45cb685e57485858eb8c9` | 3235 | 2170 (67%) | `987e0dd8ab0d35e88aa0d7bbaad188bf` |
| A4 | 4 | 3237 | 2177 (67%) | `6e58acf47eb0b9e1d64eca97418f11c9` | 3251 | 2186 (67%) | `ef8875c38e672c13ba47503862a5e986` |
| A5 | 5 | 24889 🚨 | 7548 (30%) | `acc213e66cb5a8ff80cf5a055740406b` | 3675 | 2475 (67%) | `10e34c29671b604c7dc8038dbe7ae4bc` |
| A6 | 6 | 24611 🚨 | 7500 (30%) | `86899e29025628fbd729be76f1cbacb9` | 189 | 151 (80%) | `34f0897e5c79094beb1841a236ce4acf` |
| A7 | 7 | 111 | 90 (81%) | `924aff61ce690dab3f684835b8f15aa6` | 110 | 89 (81%) | `0b8288a7e985f11ae869d8c2f6856c2d` |
| A8 | 8 | 6784 | 5768 (85%) | `e858d0f3bfa471bb4f994c77c0fc9b1f` | 3089 | 2072 (67%) | `3bd04a84713a7759fff28a1a76580f96` |
| B1 | 9 | 30585 🚨 | 6655 (22%) | `d50647303487d6e99270041183734f94` | 9244 | 8161 (88%) | `7ffea7a3e1e4eef1acf112113de04b97` |
| B2 | 12 | 16600 🚨 | 8840 (53%) | `3c0898efca87c7de6563b51cb7baed26` | 11472 🚨 | 8637 (75%) | `69e44871822a3b315b2ce09abfd2c6e7` |
| C1 | 10 | 24621 🚨 | 5100 (21%) | `c86042efbd2292485e098a53818e9044` | 3254 | 2189 (67%) | `723bc17355b09f34c0b5a2f7779244ed` |
| C2 | 11 | 24985 🚨 | 7661 (31%) | `582c4b95e81926058f0ce9648f3ccf28` | 7717 | 5048 (65%) | `30f4205a54b67c7964e223dd9f598389` |
| C3 | 13 | 10484 🚨 | 8888 (85%) | `083ce243479884c5b487c921349cac65` | 3088 | 2071 (67%) | `674d5cd5f6c73a7deb0dd9bf1a247443` |
| C4 | 14 | 2 (404) | 1 (50%) | `f91188c4da73c72b986fe069334bd96c` | 391 | 389 (99%) | `38664c1c2f4448dd5b8461c42d75d83f` |

---

### B2 (#12) — add extra connector (all 1000 rules change)

`trace.id=69e44871822a3b315b2ce09abfd2c6e7` · 46.4s · started=10000 · dropped=1472 🚨 incomplete (10k cap) — rankings under-count late spans; still useful for top costs.

Skip-unchanged does **not** apply. Ranked remaining cost:

| Rank | Candidate | Union | % txn | n | Pattern | Optimization tip |
|---|---|---:|---:|---:|---|---|
| 1 | `_has_privileges` | **13.1s** | 28.3% | **5165** | Authz N+1 / cache | Request-scoped privilege cache. Sum ≫ union → already parallel; cut **count**. |
| 2 | `_bulk` | **12.5s** | 27.0% | 17 | Serial / write path | Check batch size / payload fatness on connector update bulks. |
| 3 | `_mget` | **8.9s** | 19.1% | **1601** | Read amplification | Batch/dedupe SO loads in update + action/connector path. |
| 4 | `invalidateKeys` / `bulkMarkApiKeysForInvalidation` | **8.1s** | 17.5% | — | API-key churn | On connector-add: invalidate/regrant only rules whose action authz changed. |
| 5 | `bulkCreateRulesSo` (putAttempt) | **7.8s** | 16.9% | 8 | SO write | Keep; shrink prep/authz around it. |
| 6 | `prepareUpdate` | **7.8s** | 16.8% | 7 | Update prep | Fast-path when only `actions[]` / connectors change. |
| 7 | `createAPIKey` + `api_key/grant` | ~5.0s each | 10.7% | ~728 | API-key churn (double-count) | Pair with tip 4. |
| 8 | cases `_search` | **3.0s** | 6.5% | 1011 | ~1/rule | Batch or cache action/connector case lookups. |
| 9 | `pre-route` middlewares | 2.3s | 4.9% | 1 | Fixed tax | Later. |

Parent `importRules` is 40.4s (87%) — envelope; optimize children, not the parent.

**Highest leverage for B2:** authz cache → cut `_mget` / slim `prepareUpdate` for actions-only diffs → reduce API-key rotate on connector-only updates.

---

### C2 (#11) — add one shared exception list (50 items; all 1000 rules change)

`trace.id=30f4205a54b67c7964e223dd9f598389` · 51.3s · started=7717 · dropped=0

| Rank | Candidate | Union | % txn | n | Pattern | Optimization tip |
|---|---|---:|---:|---:|---|---|
| 1 | `_bulk` | **20.2s** | 39.3% | 24 | Write path | Exception-list linkage updates dominate writes vs B2; inspect bulk payload / batching for exception refs. |
| 2 | `_has_privileges` | **14.0s** | 27.3% | **2914** | Authz N+1 | Same request-scoped cache as B2. |
| 3 | `resolve capabilities` | **13.1s** | 25.6% | **856** | Fan-out / repeated resolve | Cache capabilities per request; should not scale with rule count like this. |
| 4 | `createAPIKey` + `grant` | ~10.1s | 19.7% | ~787 | API-key churn | Exception-list-only change shouldn’t need ~800 key grants — short-circuit when actions/enabled unchanged. |
| 5 | `space:default` GET | **9.9s** | 19.4% | **916** | N+1 ES | Cache space doc once per request. |
| 6 | `bulkCreateRulesSo` | **9.9s** | 19.4% | 8 | SO write | Keep; shrink authz/key tax around it. |
| 7 | `invalidateKeys` / mark invalidation | ~8.2s | 15.9% | — | Key lifecycle | Same as tip 4. |
| 8 | `prepareUpdate` | 3.2s | 6.3% | 4 | Prep | Cheaper when only `exceptions_list` changes. |
| 9 | `_update_by_query` | 0.2s | 0.5% | **250** | N+1 ES (items) | 5×50 item path under route handler — low wall now; watch if item counts grow. |

**Highest leverage for C2:** stop key rotate on exception-only overwrite + cache `resolve capabilities` / space GET + authz cache. `_bulk` ~20s is real write work for 1000 exception-link updates — secondary after removing unnecessary key/authz tax.

Contrast with B2: C2 has almost no `_mget` (n=10) but huge `resolve capabilities` + space GETs + more `_bulk`. Shared theme: **authz + API keys on every rule**.

### Cross-cutting actions (priority)

1. **Request-scoped authz / `_has_privileges` cache** — wins B2 and C2.
2. **Don’t mint/invalidate API keys when only exceptions change (C2) or when action authz is unchanged (B2).**
3. **C2:** cache `resolve capabilities` + space doc (N+1 → 1).
4. **B2:** cut `_mget` / slim `prepareUpdate` for actions-only diffs; batch cases searches.

### Trace index

| Step | # | trace.id | duration | started | dropped |
|---|---|---|---:|---:|---:|
| B2 | 12 | `69e44871822a3b315b2ce09abfd2c6e7` | 46.4s | 10000 | 1472 🚨 |
| C2 | 11 | `30f4205a54b67c7964e223dd9f598389` | 51.3s | 7717 | 0 |


## References

- [Published one-changed-rule benchmark](https://github.com/elastic/kibana/pull/293948#issuecomment-6172642578)
- [Import performance audit](https://github.com/elastic/kibana/issues/298302)
- [Exception-heavy import investigation](https://github.com/elastic/kibana/issues/249176)
