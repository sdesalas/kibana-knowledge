# Full bench: 9.5.4 vs main (ECH) — EXITED

Dual-stack wall-clock of the detection-rule performance scenarios on Elastic Cloud Hosted.
**Status: incomplete.** Driver aborted at **C3 (#12)** after the 180s step limit; C4–C6 never ran. Timed **Action** column only. Self-contained.

## Targets

Both stacks: **2GB Kibana** (`sdesalas3_security_oom_testing`, `gcp-us-west2`).

| Label | Deployment | Role |
|---|---|---|
| **9.5.4** | `kibana-9-5-4-5d6a7f` (`kibana-9-5-4-5d6a7f.kb.us-west2.gcp.elastic-cloud.com`) | Baseline (pre 9.5.5/9.5.6/9.6 import perf work) |
| **main** | `main-at-7c296350-e72534` (`main-at-7c296350-e72534.kb.us-west2.gcp.elastic-cloud.com`) | Control with bulk create/update, skip-unchanged, gap batching, exception-list bulk delete |

Wall-clock window: `2026-10-20T20:55:53Z` → abort at `2026-10-20T21:21:18Z` (per-step UTC in `windows.tsv`).

Scripts: `.knowledge/scripts/bulk-primitives/`. Fixtures: `.knowledge/data/rules-import/`.
Import flags: `overwrite=true&overwrite_exceptions=true&overwrite_action_connectors=true`.
Abort gate: **180s** per timed step (driver kills parallel wait and stops).


## Why it exited

| | |
|---|---|
| Stopped at | **C3 (#12)** — overwrite import `1000enabled.rules+rule_default_exceptions.ndjson` |
| Trigger | Still running after **181s** (limit 180s) |
| main C3 | Finished in **74.9s** (`rules_summary` updated=1000); APM txn present |
| 9.5.4 C3 | Client aborted; Kibana **finished server-side later** (space had 1000 rules + 1006 exception lists). **No** `POST …/_import` APM transaction for this C3 on `kibana-9.5.4` |
| Not run | C4 (#14), C5 (#15 shared `detection` lists), C6 (#16 `rule_default` lists) |
| APM done | **main C3 only** (`apm/C3.md`). No B2/C2/C5 tip dig this run |

Instances were retired after this session (QAF remove + recreate) for a clean re-run.


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
| 15 | Delete 6 shared exception lists after deleting the rules that used them. | 🟢 #285608 |
| 16 | Delete 1,000 rule-default exception lists after deleting those rules. | 🟢 #285608 |

## PRs and impact

### `POST /api/detection_engine/rules/_import`

| PR | Impact |
|---|---|
| 🔴 [#275695](https://github.com/elastic/kibana/pull/275695) `9.5.5` | Routes new rule imports through `bulkCreateRules()` instead of per-rule creation. |
| 🟤 [#291560](https://github.com/elastic/kibana/pull/291560) `9.5.6` | Routes overwrite imports through `bulkUpdateRules()` and batches enable/disable transitions. |
| 🟠 [#290306](https://github.com/elastic/kibana/pull/290306) `9.5.5` | Uses `refresh=false` for bulk API-key grants, removing refresh waits. |
| 🟡 [#293948](https://github.com/elastic/kibana/pull/293948) `9.5.6` | Skips unchanged rules during overwrite imports (scenario 6). |

### `POST /api/detection_engine/rules/_bulk_action`

| PR | Impact |
|---|---|
| 🔵 [#287065](https://github.com/elastic/kibana/pull/287065) `9.5.6` | Batches gap cleanup during rule deletion using `_update_by_query`. |

### `POST /internal/api/exception_lists/_bulk_action`

| PR | Impact |
|---|---|
| 🟢 [#285608](https://github.com/elastic/kibana/pull/285608) `9.6.0` | Bulk exception-list deletion (≤100 ids/req). **404 on 9.5.4.** |

## Endpoints

| Endpoint | Scenarios | Usage |
|---|---|---|
| `POST /api/detection_engine/rules/_import` | 1–2, 5–6, 9–13 | Create / overwrite import. |
| `POST /api/detection_engine/rules/_bulk_action` | 3–4, 7–8, 14 | enable / edit / disable / delete. |
| `POST /internal/api/exception_lists/_bulk_action` | 15–16 | delete; filter `type: detection` (#15) then `rule_default` (#16). |

## Methodology (execution order)

Single repetition. Seed left → timed Action right. Branch order **A → B → C**.

### Branch A — baseline rules (then wipe)

| Step | # | Seed | Action (timed) |
|---|---|---|---|
| A1 | 1 | clean space | Import `1000disabled-rules.ndjson` |
| A2 | 3 | after A1 | `_bulk_action` enable |
| A3 | 2 | clean space | Import `1000enabled-rules.ndjson` |
| A4 | 4 | after A3 | `_bulk_action` edit `add_tags: ["bench"]` |
| A5 | 5 | reseed #2 | Import overwrite `1000enabled-rules.all-updated.ndjson` |
| A6 | 6 | reseed #2 | Import overwrite `1000enabled-rules.1-updated.ndjson` |
| A7 | 7 | reseed #2 | `_bulk_action` disable |
| A8 | 8 | after A7 | `_bulk_action` delete (no gaps) |

### Branch B — connectors

| Step | # | Seed | Action (timed) |
|---|---|---|---|
| B1 | 9 | clean space | Import `1000enabled.rules+connector-email-smtp.ndjson` |
| B2 | 13 | B1 | Import overwrite `1000enabled.rules+2connectors-email-smtp-cases.ndjson` |

### Branch C — exceptions → delete lists

| Step | # | Seed | Action (timed) | This run |
|---|---|---|---|---|
| C1 | 10 | clean space | Import `…+5exceptionlists.ndjson` | done |
| C2 | 11 | C1 | Import overwrite `…+6exceptionlists.ndjson` | done |
| C3 | 12 | C2 | Import overwrite `…+rule_default_exceptions.ndjson` | **aborted** |
| C4 | 14 | C3 + gaps | seed gaps → `_bulk_action` delete | not run |
| C5 | 15 | after C4 | Bulk delete `TYPE=detection` (6 shared) | not run |
| C6 | 16 | after C5 | Bulk delete `TYPE=rule_default` (1000) | not run |


## Wall-clock results (curl `time_total`)

| Step | # | Scenario | 9.5.4 | main | Δ (954−main) | speedup |
|---|---|---|---:|---:|---:|---:|
| A1 | 1 | Create 1,000 disabled rules | 44.6s | 18.6s | +26.0s | 2.4× |
| A2 | 3 | Enable 1,000 disabled rules | 35.7s | 15.8s | +19.9s | 2.3× |
| A3 | 2 | Create 1,000 enabled rules | 91.7s | 20.9s | +70.9s | 4.4× |
| A4 | 4 | Edit 1,000 rules (add tag) | 47.5s | 29.9s | +17.5s | 1.6× |
| A5 | 5 | Fully update 1,000 enabled rules | 92.9s | 39.4s | +53.5s | 2.4× |
| A6 | 6 | Update 1 of 1,000 (999 unchanged) | 98.1s | 10.4s | +87.8s | **9.5×** |
| A7 | 7 | Disable 1,000 enabled rules | 19.8s | 17.4s | +2.4s | 1.1× |
| A8 | 8 | Delete 1,000 rules (no gaps) | 28.0s | 18.4s | +9.7s | 1.5× |
| B1 | 9 | Create 1,000 enabled + 1 connector | 97.7s | 32.8s | +64.8s | 3.0× |
| B2 | 13 | Update 1,000 rules (+ extra connector) | 47.5s | 54.8s | −7.3s | 0.9× |
| C1 | 10 | Create 1,000 rules + 5 shared exception lists | 105.3s | 23.0s | +82.3s | 4.6× |
| C2 | 11 | Update +1 shared exception list | 109.9s | 66.0s | +43.8s | 1.7× |
| C3 | 12 | Replace shared lists → rule_default per rule | **aborted (>180s)** | **74.9s** | n/a | n/a |
| C4 | 14 | Delete 1,000 rules (with gaps) | — | — | — | — |
| C5 | 15 | Bulk delete shared (`detection`) lists | — | — | — | — |
| C6 | 16 | Bulk delete `rule_default` lists | — | — | — | — |

### Notes

- **A1–C2 look sane** for this pair: big main wins on creates / skip-path (#6); B2 near parity (main slightly slower).
- **C3 is the failure mode.** main ~75s; 9.5.4 blew past the 180s gate (same failure class as a ~1113s C3 seen earlier on this 9.5.4 deploy).
- Before Branch C, wipe left **1006 leftover exception lists on 9.5.4** (bulk-delete API 404); main had 0. C1 still completed on both.
- Raw: `timings.tsv`, `windows.tsv`, `logs/`, `driver.log`.


## What we know about C3 (post-abort dig)

### Code paths

| Stack | Overwrite import path |
|---|---|
| **9.5.4** | Per-rule `DetectionRulesClient.importRule` → `rulesClient.update` (no `bulkUpdateRules`) |
| **main** | `bulkUpdateRules` / `bulkCreateRulesSo` batching |

Missing bulk-update on 9.5.4 is real and explains steady ~2× gaps elsewhere — **it does not by itself explain a ~10× C3 climb** (same per-rule path can finish ~100s or ~1000s).

### Slow-path APM shape (~1113s C3 on this 9.5.4 deploy)

Forensic APM (same deployment, incomplete span capture at 10k cap):

| Observation | Detail |
|---|---|
| Wall | ~1113s; `POST /_bulk` union ~833s (~75% of txn) |
| `_bulk` count | ~907 calls, avg ~0.9s each |
| Parallelism | **max concurrency 50 → 1** (union ≈ sum). Healthy C3 on same code: concurrency ~50, `_bulk` union ~9.5s |
| Latency | Per-bulk only ~25% slower; wall went ~10× because work **stopped overlapping** |
| Open | **Why** concurrency clamped to 1 (ES pool, client queue, key/invalidate lock, event-loop collapse, …) — **not proven** |

### Ruled out / weak as unique cause

| Hypothesis | Finding |
|---|---|
| “main is fast only because of `bulkUpdateRules`” | Climb is lost `_bulk` parallelism on 9.5.4, not absence of bulk-update |
| Dirty API keys unique to 9.5.4 | Both stacks dirty after benches (~37k keys on 9.5.4, ~48k on main). Not unique to the slow side |
| “No finish ⇒ no APM” | False for this abort: 9.5.4 **did** finish server-side; agent simply never emitted a usable C3 import txn here |

### Main C3 (this run) — APM tips

`trace.id=489abccc67128c0fb270adc31a1d9fe0` · 74.1s · started=7538 · dropped=0 · `apm/C3.md`

| Rank | Candidate | Union | % | n | Pattern | Optimization tip |
|---|---|---:|---:|---:|---|---|
| 1 | `_has_privileges` | 19.5s | 26% | 2679 | Authz N+1 | Request-scope / batch privilege checks |
| 2 | `resolve capabilities` | 16.9s | 23% | 759 | Parallel fan-out | Cache capabilities per request |
| 3 | `POST /_bulk` | 15.9s | 21% | 22 | Serial / critical path | Inspect payload (rule + embedded exceptions) |
| 4 | `bulkCreateRulesSo` | 12.4s | 17% | 10 | Serial writes | SO write path for 1000 updates |
| 5 | `createAPIKey` / `api_key/grant` | ~12.0s | 16% | ~748 | API-key churn | Skip key rotation on exceptions-only overwrite |
| 6 | `GET …/space%3Adefault` | 11.8s | 16% | 782 | Repeated fetches | Cache space SO once per request |
| 7 | `invalidateKeys` / mark invalidation | ~10.1s | 14% | 10–16 | API-key churn | Pair with tip 5 |

Almost **no named exception-list spans** — rule-default create/attach is largely uninstrumented.

**Highest leverage (main C3):** authz cache → stop key rotate on exception-only overwrite → instrument exception-list import.


## Next

1. Fresh ECH instances (delete + recreate `kibana-9.5.4` + latest `main-at-<sha>`).
2. Clean dual-stack re-run A→C6; keep C3 / C6 abort gates.
3. If 9.5.4 C3 climbs again on a clean stack → concurrency clamp is environmental/product under load, not leftover SO dirt. If it stays ~100s → prior deploys were poisoned; dig why under load.
4. Then main-only APM tips for B2 / C2 / C5 / C6 as needed.

## References

- [Published one-changed-rule benchmark](https://github.com/elastic/kibana/pull/293948#issuecomment-6172642578)
- [Import performance audit](https://github.com/elastic/kibana/issues/298302)
- [Exception-heavy import investigation](https://github.com/elastic/kibana/issues/249176)
- Scenario source: `.knowledge/demos/benchmark-scenarios.md`
