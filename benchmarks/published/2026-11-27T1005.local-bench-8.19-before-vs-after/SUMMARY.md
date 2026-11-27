# Local bench: 8.19 before vs after backport of #304858

Local before/after of [backport PR #307975](https://github.com/elastic/kibana/pull/307975) ([source #304858](https://github.com/elastic/kibana/pull/304858)) on 8.19. Question: does the backport make ~1,000 fewer `POST /_security/user/_has_privileges` calls per 1,000-rule bulk write, as on main?

**Result:** yes. Every scenario makes exactly ~1,000 fewer calls. Wall clock is unchanged.

**Context:** 8.19 is expected to be slow and span-heavy. The bulk-primitive and API-key work from the [Detections bulk performance epic (#264906)](https://github.com/elastic/kibana/issues/264906) shipped in 9.5.5, 9.5.6 and 9.6.0 and was not backported ([see the 9.5.4 vs 9.5.6/9.6.0 comparison](https://github.com/elastic/kibana/issues/264906#issuecomment-6313484568)). So absolute times and span counts here are not comparable to 9.x. Only the before/after delta is.

## Targets

| Label | Commit | Server |
|---|---|---|
| **Before** | `62a7d17` (parent of the backport) | `http://localhost:5610/kbn` (`elastic:changeme`) |
| **After** | `d140230` (`backport/8.19/pr-304858`) | same server, same ES (`:9209`), branch switched in place |

Kibana `8.19.26`. APM: `elastic.apm.environment: localhost-kibana-8.19`, `transactionMaxSpans: 40000` (no trace was truncated, `dropped` = 0 on all runs), `xpack.securitySolution.maxRuleImportPayloadBytes: 26214400`.

Harness: `.knowledge/scripts/bulk-primitives/`, guide `guides/detection_rule_wall_bench.md`. Fixtures: `.knowledge/data/rules-import/`. Raw timings and windows: `benchmarks/2026-11-27T1005.local-bench-8.19-{before-62a7d17,after-d140230}/` (not published).

## Scenarios

| # | Scenario |
|---|---|
| 1 | Import → Create 1,000 disabled rules. |
| 2 | Import → Create 1,000 enabled rules. |
| 3 | Enable 1,000 existing disabled rules. |
| 4 | Edit 1,000 enabled rules (add tag). |
| 5 | Import → Fully update 1,000 enabled rules. |
| 15 | Import → Create 1,000 disabled rules with response actions. |
| 16 | Enable 1,000 rules with response actions. |

## `_has_privileges` spans per request

Spans named `Elasticsearch: POST /_security/user/_has_privileges` inside the operation's own request trace (joined on `trace.id`). Single run each.

| Scenario | Before | After | Diff |
|---|---|---|---|
| 1. Import 1000 disabled | 3,072 | 2,072 | -1,000 |
| 3. Bulk enable | 1,027 | 27 | -1,000 |
| 2. Import 1000 enabled | 3,072 | 2,072 | -1,000 |
| 4. Bulk edit | 1,031 | 31 | -1,000 |
| 5. Import overwrite | 5,024 | 4,024 | -1,000 |
| 15. Import w/ response actions | 3,072 | 2,072 | -1,000 |
| 16. Enable w/ response actions | 1,027 | 28 | -999 |

Total spans per request also drop by ~1,000 (e.g. scenario 1: 14,225 → 13,225; scenario 3: 2,096 → 1,096).

## Wall clock (curl `time_total`, seconds)

| Scenario | Before | After |
|---|---|---|
| 1. Import 1000 disabled | 21.0 | 21.2 |
| 3. Bulk enable | 22.4 | 24.5 |
| 2. Import 1000 enabled | 49.4 | 50.9 |
| 4. Bulk edit | 24.7 | 24.6 |
| 5. Import overwrite | 55.2 | 53.0 |
| 15. Import w/ response actions | 21.0 | 20.8 |
| 16. Enable w/ response actions | 22.4 | 23.4 |

Within run-to-run noise. The endpoint authz calls are a small share of 8.19 request time.

## Reading the results

- Imports on 8.19 still make ~2,000 `_has_privileges` calls after the backport (~3 per rule before, ~2 after). The remaining calls are not from endpoint authz, so "~1,000 fewer" is accurate; "1000x less" is not.
- Bulk enable and edit go from ~1,000 calls to ~27.
- The high span counts and slow imports are expected on 8.19. None of this work was backported to 8.19, so it still processes imports and enables rule by rule. Missing 9.x changes, from the [epic comment](https://github.com/elastic/kibana/issues/264906#issuecomment-6313484568):
  - [#275695](https://github.com/elastic/kibana/pull/275695): new rule imports go through `bulkCreateRules()` (9.5.5).
  - [#290306](https://github.com/elastic/kibana/pull/290306): no refresh waits when bulk operations grant new API keys (9.5.5).
  - [#291560](https://github.com/elastic/kibana/pull/291560): overwrite imports go through `bulkUpdateRules()`, and enable/disable transitions are batched (9.5.6).
  - [#293948](https://github.com/elastic/kibana/pull/293948): unchanged rules are skipped on overwrite import (9.5.6).
  - [#287065](https://github.com/elastic/kibana/pull/287065): gap cleanup is batched on delete (9.5.6).

## Caveats

- One run per side. Same server and ES, branch switched in place (dev watcher restart, uptime checked before the "after" run).
- Local wall clocks are not comparable to ECH.
- A temp APM patch forced a root transaction for `rules/_import` on this branch (local only, not committed).
- Counts came from `benchmarks/2026-11-27T0925.count_spans.py` with targets `8.19-before` and `8.19-after`. It needs the APM creds in `~/config/apm.creds`, so it isn't copied here.
