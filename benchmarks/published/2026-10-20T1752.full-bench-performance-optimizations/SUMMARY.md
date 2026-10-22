# Full bench: 9.5.4 vs main (ECH)

Single run of the fifteen detection-rule performance scenarios on Elastic Cloud Hosted.
Timed **Action** column only (seed steps not timed). This doc is self-contained — you do not need `benchmark-scenarios.md`.

## Targets

| Label | Deployment | Role |
|---|---|---|
| **9.5.4** | `kibana-9-5-4-5d6a7f` (`kibana-9-5-4-5d6a7f.kb.us-west2.gcp.elastic-cloud.com`) | Baseline (pre 9.5.5/9.5.6/9.6 import perf work) |
| **main** | `main-at-7c296350-e72534` (`main-at-7c296350-e72534.kb.us-west2.gcp.elastic-cloud.com`) | Control with bulk create/update, skip-unchanged, gap batching, exception-list bulk delete |

Wall-clock window: `2026-10-20T17:57:43Z` → `2026-10-20T18:27:06Z` (per-step UTC in `windows.tsv`).

Scripts: `.knowledge/scripts/bulk-primitives/` (`parallel_import_rules.sh`, `parallel_bulk_action.sh`, `parallel_seed_gaps.sh`, `parallel_delete_exception_lists.sh`). Fixtures: `.knowledge/data/rules-import/`.

Import flags on every import: `overwrite=true&overwrite_exceptions=true&overwrite_action_connectors=true`.


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
| 10 | Create 1,000 rules with five shared exception lists. | 🔴 #275695, 🟠 #290306 |
| 11 | Update 1,000 rules by adding one more shared exception list, with no other changes. | 🟤 #291560, 🟠 #290306 |
| 12 | Update 1,000 rules by replacing shared exception lists with a rule-default list per rule. | 🟤 #291560, 🟠 #290306 |
| 13 | Update 1,000 rules by adding an extra connector, with no other changes. | 🟤 #291560, 🟠 #290306 |
| 14 | Delete 1,000 rules with existing gaps. | 🔵 #287065 |
| 15 | Delete the exception lists associated with 1,000 rules after deleting those rules. | 🟢 #285608 |

## PRs and impact

### `POST /api/detection_engine/rules/_import`

| PR | Impact |
|---|---|
| 🔴 [#275695](https://github.com/elastic/kibana/pull/275695) `9.5.5` | Routes new rule imports through `bulkCreateRules()` instead of per-rule creation. |
| 🟤 [#291560](https://github.com/elastic/kibana/pull/291560) `9.5.6` | Routes overwrite imports through `bulkUpdateRules()` and batches enable/disable transitions. |
| 🟠 [#290306](https://github.com/elastic/kibana/pull/290306) `9.5.5` | Uses `refresh=false` for bulk API-key grants, removing refresh waits. Applies when new keys are minted: enabled creates, updates and enables, including the update step before disabling. For scenarios 6 and 9–13, the benefit depends on enabled state and key creation. |
| 🟡 [#293948](https://github.com/elastic/kibana/pull/293948) `9.5.6` | Skips unchanged rules during overwrite imports, avoiding writes and API-key rotation for the 999 unchanged rules in scenario 6. |

### `POST /api/detection_engine/rules/_bulk_action`

| PR | Impact |
|---|---|
| 🔵 [#287065](https://github.com/elastic/kibana/pull/287065) `9.5.6` | Batches gap cleanup during rule deletion using `_update_by_query`, reducing requests both with and without existing gaps. |

### `POST /internal/api/exception_lists/_bulk_action`

| PR | Impact |
|---|---|
| 🟢 [#285608](https://github.com/elastic/kibana/pull/285608) `9.6.0` | Adds bulk exception-list deletion, batching reference checks and streaming item cleanup in requests of up to 100 lists. |

## Endpoints

| Endpoint | Scenarios | Usage |
|---|---|---|
| `POST /api/detection_engine/rules/_import` | 1–2, 5–6, 9–13 | Create rules, or import updates with `overwrite=true`. |
| `POST /api/detection_engine/rules/_bulk_action` | 3–4, 7–8, 14 | `enable` (3), `edit`/`add_tags` (4), `disable` (7), `delete` (8, 14). #14 also leaves exception lists for #15. |
| `POST /internal/api/exception_lists/_bulk_action` | 15 | `action: delete`; unreferenced lists; ≤100 ids per request. |


## Methodology (how this run was executed)

Scenario **#** is the scenario id. Rows below are **execution order** — not 1…15 in sequence. Each timed step needs the seed on its left. Time only the **Action** column. This run was a **single repetition** (no 3× means).

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
| B2 | 13 | B1 (#9) | Import overwrite | `1000enabled.rules+2connectors-email-smtp-cases.ndjson` (actions only; empty `exceptions_list` both sides) |

### Branch C — exceptions → delete lists

Clean space before C1 (rules deleted after B2).

| Step | # | Seed | Action (timed) | Fixture / notes |
|---|---|---|---|---|
| C1 | 10 | clean space | Import | `1000enabled.rules+5exceptionlists.ndjson` |
| C2 | 11 | C1 (#10) | Import overwrite | `1000enabled.rules+6exceptionlists.ndjson` |
| C3 | 12 | C2 | Import overwrite | `1000enabled.rules+rule_default_exceptions.ndjson` |
| C4 | 14 | C3 + gaps | `_bulk_action` delete | `GAPS_PER_RULE=3 ./parallel_seed_gaps.sh` (not timed) then delete; lists remain |
| C5 | 15 | after C4 | Bulk delete exception lists | `/internal/api/exception_lists/_bulk_action`, ≤100 ids/req, `elastic-api-version: 1` |

Do not run B2 on top of C3 — that would clear `rule_default` lists.


## Wall-clock results (curl `time_total`)

| Step | # | Scenario | 9.5.4 | main | Δ (954−main) | speedup (954/main) |
|---|---|---|---:|---:|---:|---:|
| A1 | 1 | Create 1,000 disabled rules | 43.9s | 13.8s | +30.0s | 3.2× |
| A2 | 3 | Enable 1,000 disabled rules | 33.9s | 12.0s | +21.9s | 2.8× |
| A3 | 2 | Create 1,000 enabled rules | 96.4s | 18.8s | +77.6s | 5.1× |
| A4 | 4 | Edit 1,000 rules (add tag) | 48.2s | 22.2s | +26.0s | 2.2× |
| A5 | 5 | Fully update 1,000 enabled rules | 90.0s | 32.2s | +57.9s | 2.8× |
| A6 | 6 | Update 1 of 1,000 (999 unchanged) | 95.9s | 8.7s | +87.2s | **11.0×** |
| A7 | 7 | Disable 1,000 enabled rules | 21.6s | 13.2s | +8.4s | 1.6× |
| A8 | 8 | Delete 1,000 rules (no gaps) | 27.0s | 15.2s | +11.8s | 1.8× |
| B1 | 9 | Create 1,000 enabled + 1 connector | 99.7s | 22.0s | +77.7s | 4.5× |
| B2 | 13 | Update 1,000 rules (+ extra connector) | 45.4s | 44.7s | +0.8s | 1.0× |
| C1 | 10 | Create 1,000 rules + 5 shared exception lists | 98.6s | 19.7s | +79.0s | 5.0× |
| C2 | 11 | Update +1 shared exception list | 108.1s | 54.6s | +53.4s | 2.0× |
| C3 | 12 | Replace shared lists → rule_default per rule | 104.0s | 51.9s | +52.1s | 2.0× |
| C4 | 14 | Delete 1,000 rules (with gaps) | 45.6s | 17.3s | +28.3s | 2.6× |
| C5 | 15 | Bulk delete exception lists (after C4) | **404** (0.5s) | 212.7s (1006 lists) | n/a | n/a |

### Notes on wall-clock

- **#15 on 9.5.4:** `POST /internal/api/exception_lists/_bulk_action` → HTTP 404 (API added in 9.6 / #285608). Main deleted 1006 lists in ~213s (slow; expected).
- **#13 (B2) almost parity (~45s both).** Not a skip scenario — every rule gets a real connector change. On main, B2 (~45s) is *slower* than B1 create (~22s); on 9.5.4, B2 overwrite (~45s) is already much faster than B1 create (~100s). Paths changed under the hood; wall met in the middle. See APM § #13.
- Biggest deltas: **#6** (skip path), **#2 / #9 / #10** (enabled creates), **#5**, **#14 vs #8**.

Raw: `timings.tsv`, `windows.tsv`, `logs/`.


## APM (9.5.4 vs main)

Env / deploy labels in traces: `kibana-9.5.4` / `main-at-7c296350`. Script outputs under `apm/`.

🚨 **Dropped spans:** long imports on 9.5.4 hit the agent cap (`started=10000`, `dropped≈14–20k`). Main also dropped on heavy imports (`started=5000` at the time of this run — `transactionMaxSpans` was 5k on main). **Do not trust n-count deltas** across sides; prefer union wall and presence/absence. A follow-up main-only re-run with `transactionMaxSpans=15k` is in `../2026-10-20T1855.full-bench-main-15kspans/` (when complete).

### Priority compares

| Scenario | 9.5.4 APM | main APM | speedup | Traces (prefix) |
|---|---:|---:|---:|---|
| #6 1-updated overwrite | 95.2s | 7.9s | **12.0×** | `3db8f051…` / `5d74f493…` |
| #2 enabled create | 95.8s | 18.2s | 5.3× | `b0f23d4b…` / `8944fc54…` |
| #3 enable (A2) | 31.9s | 10.7s | 3.0× | `08893c4b…` / `e45ab9ad…` |
| #14 delete+gaps | 44.1s | 15.6s | 2.8× | `52c6d8a0…` / `1fa3147b…` |
| #8 delete no gaps | 25.6s | 13.8s | 1.9× | `3c31e030…` / `cf998e32…` |
| #13 add connector (B2) | 44.2s | 43.9s | 1.0× | `5dd3c5a0…` / `10d1c724…` |
| #15 exception bulk (main only) | n/a (404) | ~20s × 11 batches ≈ 213s wall | — | e.g. `e17be757…` |

### #6 — skip-path (biggest win) — 🟡 #293948 + 🟤 #291560

Shape change: **per-rule `importRule` gone on main**; only ~189 spans vs 10k on 9.5.4.

| Candidate | 9.5.4 union | main union | Δ | Pattern |
|---|---:|---:|---:|---|
| `DetectionRulesClient.importRules` | 47.0s | 5.4s | −41.5s | serial / bulk path |
| `DetectionRulesClient.importRule` | 41.3s (n=450) | 0 | −41.3s | **only 9.5.4** — per-rule path |
| `_has_privileges` | 15.7s | 0.6s | −15.1s | authz N+1 (counts unreliable) |
| `bulkMarkApiKeysForInvalidation` | 9.6s (n=400) | 1.0s | −8.6s | API-key churn on rewrite |
| `createAPIKey` / `api_key/grant` | ~7.9s (n=400) | ~0.02s | −7.9s | double-count same work |
| `bulkUpdateRules.putAttempt.*` | 0 | ~1.0s | +1s | **only main** — bulk update path |

Skip-unchanged + bulk update explain the ~12×. Remaining main cost is mostly `importRules` envelope + small invalidate/putAttempt.

### #2 — enabled create — 🔴 #275695 + 🟠 #290306

| Candidate | 9.5.4 | main | Δ | Pattern |
|---|---:|---:|---:|---|
| `importRule` | 37.0s (n=450) | 0 | −37s | per-rule path (only 9.5.4) |
| `importRules` | 42.0s | 15.5s | −27s | → `bulkCreateRules.runBatch.*` on main |
| `createRuleSavedObject` / SO create+update | ~19s / ~10s | 0 | — | only 9.5.4 |
| `createAPIKey` / grant | 7.8s (n=400) | 3.4s (n=1000) | −4.4s union | refresh=false helps union even with more grants |
| `taskManager.schedule` | 2.0s (n=400) | 0 | −2s | per-item schedule → bulkSchedule on main |

### #3 — enable — 🟤 #291560 + 🟠 #290306

Main win is almost entirely **API-key grant path**: `createAPIKey`/`grant` union 20.1s → 0.9s (n≈1000 both — union collapse = refresh=false / batching). Also `Get rules, collect…` only on 9.5.4 (22s).

### #13 — add connector (B2) — why wall is flat

Skip-unchanged does **not** apply (all 1000 rules change). APM shows path *did* change (`importRule` only on 9.5.4; `bulkUpdateRules.putAttempt.*` on main), but remaining cost on main is still large:

| Candidate (main B2) | Union | Pattern / tip |
|---|---:|---|
| `DetectionRulesClient.importRules` | ~15.9s | envelope — dig phases outside named children |
| `_has_privileges` | ~5.9s (n≈2455) | authz N+1 / request-scoped cache |
| cases `_search` | ~2.6s (n≈1005) | ~1 search/rule — batch/cache |
| API-key invalidate + grant | ~2s + ~1.5s | churn when actions change |
| `prepareUpdate` + SO bulk | ~2.3s + ~1.9s | connector-only diff prep |
| `_mget` | ~2.8s (n≈536) | read amplification |
| `pre-route handler middlewares` | ~2.2s | fixed tax |

Main B2 also dropped heavily (`started=5000`, `dropped=6445` → ~11.4k attempted spans). Re-analyze after 15k cap re-run.

### #14 vs #8 — gaps delete — 🔵 #287065

| | #8 no gaps | #14 with gaps |
|---|---:|---:|
| 9.5.4 wall | 27.0s | 45.6s |
| main wall | 15.2s | 17.3s |

On 9.5.4, #14 adds `updateGapsInEventLog…` (~3.3s) + more `_has_privileges` / space GETs. Main keeps both deletes in the mid-teens; gap cleanup via `_update_by_query` (n=1000, ~0.8s union). Authz N+1 still large on 9.5.4 delete path.

### #15 — exception-list bulk delete (main) — 🟢 #285608

- 9.5.4: HTTP **404** — no compare.
- main: 11 batches × ~20s; one batch analyzed (`e17be757…`, dropped=0): ~half wall in parallel `_bulk` (9.5s union / n=100); many per-list `DELETE …/exception-list%3A…` docs (~1s each, overlapping). Endpoint still slow end-to-end (~213s for 1006 lists) — expected.

### Trace index / artifacts

- `apm/discover-*.txt`, `apm/compare-*.txt`, `apm/analyze-*.txt`
- `APM.md` — file list
- UTC windows: `windows.tsv`
- Driver: `run_bench.sh`, `driver.log`, `logs/`

## References

- [Published one-changed-rule benchmark](https://github.com/elastic/kibana/pull/293948#issuecomment-6172642578)
- [Import performance audit](https://github.com/elastic/kibana/issues/298302)
- [Exception-heavy import investigation](https://github.com/elastic/kibana/issues/249176)
- Scenario source (optional): `.knowledge/demos/benchmark-scenarios.md`
