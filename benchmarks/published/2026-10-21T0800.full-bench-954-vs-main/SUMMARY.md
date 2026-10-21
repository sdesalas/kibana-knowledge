# Full bench: 9.5.4 vs main (ECH)

Single run of the fourteen detection-rule performance scenarios on Elastic Cloud Hosted.
Timed **Action** column only (seed steps not timed). This doc is self-contained — you do not need `benchmark-scenarios.md`.

**APM:** not started — waiting for go-ahead.


## Targets

Both stacks: **2GB Kibana** (`sdesalas3_security_oom_testing`, `gcp-us-west2`).

| Label | Deployment | Role |
|---|---|---|
| **9.5.4** | `kibana-9-5-4-55213f` (`kibana-9-5-4-55213f.kb.us-west2.gcp.elastic-cloud.com`) | Baseline (pre 9.5.5/9.5.6/9.6 import perf work) |
| **main** | `main-at-ffa1cb22-d52474` (`main-at-ffa1cb22-d52474.kb.us-west2.gcp.elastic-cloud.com`) | Control with bulk create/update, skip-unchanged, gap batching, exception-list bulk delete |

Wall-clock window: `2026-10-21T08:00:15Z` → `2026-10-21T08:23:27Z` (per-step UTC in `windows.tsv`).

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

### Exception-list delete

| PR | Impact |
|---|---|
| 🟢 [#285608](https://github.com/elastic/kibana/pull/285608) `9.6.0` | Adds `POST /internal/api/exception_lists/_bulk_action`. On builds without it (9.5.4), the bench falls back to a timed loop of `DELETE /api/exception_lists?id=…` so C4 can still be compared. |

## Endpoints

| Endpoint | Scenarios | Usage |
|---|---|---|
| `POST /api/detection_engine/rules/_import` | 1–2, 5–6, 9–12 | Create rules, or import updates with `overwrite=true`. |
| `POST /api/detection_engine/rules/_bulk_action` | 3–4, 7–8, 13 | `enable` (3), `edit`/`add_tags` (4), `disable` (7), `delete` (8, 13). #13 also leaves exception lists for #14. |
| `POST /internal/api/exception_lists/_bulk_action` (main) / `DELETE /api/exception_lists` loop (9.5.4) | 14 | Delete 6 unreferenced `detection` lists — bulk vs single-delete. |


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
| C4 | 14 | after C3 | Delete 6 shared lists | `TYPE=detection` via `./parallel_delete_exception_lists.sh` — bulk on main; single-DELETE loop on 9.5.4 |


## Wall-clock results (curl `time_total`)

| Step | # | Scenario | 9.5.4 | main | Δ (954−main) | speedup (954/main) |
|---|---|---|---:|---:|---:|---:|
| A1 | 1 | Create 1,000 disabled rules | 44.0s | 13.7s | +30.2s | 3.2× |
| A2 | 3 | Enable 1,000 disabled rules | 32.9s | 12.4s | +20.5s | 2.6× |
| A3 | 2 | Create 1,000 enabled rules | 85.2s | 16.6s | +68.6s | 5.1× |
| A4 | 4 | Edit 1,000 rules (add tag) | 41.8s | 22.7s | +19.0s | 1.8× |
| A5 | 5 | Fully update 1,000 enabled rules | 88.6s | 31.8s | +56.8s | 2.8× |
| A6 | 6 | Update 1 of 1,000 (999 unchanged) | 89.3s | 8.9s | +80.4s | **10.0×** |
| A7 | 7 | Disable 1,000 enabled rules | 18.1s | 15.1s | +2.9s | 1.2× |
| A8 | 8 | Delete 1,000 rules (no gaps) | 26.0s | 16.0s | +10.0s | 1.6× |
| B1 | 9 | Create 1,000 enabled + 1 connector | 90.6s | 25.7s | +64.8s | 3.5× |
| B2 | 12 | Update 1,000 rules (+ extra connector) | 45.1s | 49.5s | −4.4s | 0.9× |
| C1 | 10 | Create 1,000 rules + 5 shared lists (50 items each) | 88.5s | 20.8s | +67.7s | 4.3× |
| C2 | 11 | Update +1 shared list (50 items) | 107.2s | 57.7s | +49.4s | 1.9× |
| C3 | 13 | Delete 1,000 rules (with gaps) | 30.2s | 21.7s | +8.5s | 1.4× |
| C4 | 14 | Delete 6 shared exception lists | **11.7s** (single×6) | **2.4s** (bulk) | +9.3s | **5.0×** |

### Notes on wall-clock

- **#14 (C4):** 9.5.4 has no bulk API — timed loop of 6× `DELETE /api/exception_lists` = **11.7s**. Main bulk = **2.4s** for the same 6 lists (**5.0×**).
- **#12 (B2):** main slightly slower than 9.5.4 (49.5s vs 45.1s). Not a skip scenario — every rule gets a real connector change.
- Biggest deltas: **#6** (skip path), **#2 / #9 / #10** (enabled creates), **#5**, **#11**, **#14**.
- main `rules_summary` where present: A6 `updated=1,skipped=999`; other overwrites `updated=1000`.

Raw: `timings.tsv`, `windows.tsv`, `logs/`.


## Performance investigation

Pending — waiting for go-ahead (planned: main B2 / C2).


## References

- [Published one-changed-rule benchmark](https://github.com/elastic/kibana/pull/293948#issuecomment-6172642578)
- [Import performance audit](https://github.com/elastic/kibana/issues/298302)
- [Exception-heavy import investigation](https://github.com/elastic/kibana/issues/249176)
