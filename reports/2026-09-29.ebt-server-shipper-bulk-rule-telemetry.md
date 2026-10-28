# EBT server shipper vs bulk rule telemetry (2K installs, 10K imports)

Context: Maxim's review on [PR #293496](https://github.com/elastic/kibana/pull/293496#pullrequestreview-5341303486)
asked how one-event-per-rule telemetry scales for a ~2K prebuilt rule install.
This note checks what the server-side shipper actually does with that volume,
and what it means for `rules/_import` at its 10K cap.

## TL;DR

- Nothing is dropped for a single 2K install or a single 10K import. Both fit under the shipper's 10,000-event queue cap.
- The events are **not** sent in one go. The shipper drains ~10KB every 10s, so a 2K install takes **~35 min** to leave Kibana and a 10K import **~2h45m**.
- The real risks are: (a) back-to-back bulk ops pushing the queue past 10K (overflow is dropped), and (b) a failed POST losing its batch (no retry).
- A 10K import already maxes the queue today on `main`. Bulk install at ~2K adds nothing new in kind. It's ~1/5 of what import can already do.
- CPU/memory cost is negligible (~2MB of queue for 2K, ~10MB for 10K; ~2–10ms per 10s tick to measure it).

---

## How the path works

Source: `node_modules/@elastic/ebt` v1.4.1 (external package, not in the Kibana repo).
Registered in `src/platform/plugins/shared/telemetry/server/plugin.ts` as `ElasticV3ServerShipper` on channel `kibana-server`.

1. **Our code** calls `analytics.reportEvent()` once per rule (`sendRuleLifecycleTelemetryEvent` in `rule_lifecycle_telemetry.ts`).
2. **Analytics client** (`client/src/analytics_client/analytics_client.js`) stamps each event with `timestamp`, the full `context`, and `trace`, then hands it straight to the shipper as a 1-event array. No batching here once opt-in is known. (The `bufferCount(1000)` in that file only applies to events queued *before* opt-in config arrives at startup.)
3. **Shipper** (`shippers/elastic_v3/server/src/server_shipper.js`) pushes into an in-memory `internalQueue`.

### Shipper constants and behaviour

| Thing | Value |
|---|---|
| Queue cap | `MAX_NUMBER_OF_EVENTS_IN_INTERNAL_QUEUE = 10000` |
| Send cadence | checks every 1s, sends only if ≥10s since last send (`MIN_TIME_SINCE_LAST_SEND`) |
| Batch size | ~10KB per send ("leaky bucket"): shifts events until ≥10KB |
| Flush | explicit `flush()` or shutdown sends the whole queue in one request |
| Overflow | events beyond the cap are spliced off and counted as `dropped` / `queue_full` |
| Failed POST | batch is already removed from the queue; counted as failed, **not retried** |
| Offline > 24h | queue cleared, new events ignored |
| Opt-out | queue cleared |

Notes:

- The code comment says "we only want store up-to 1000 events", but the constant is 10,000. The comment is stale.
- The queue is shared by **every** server-side EBT event on the `kibana-server` channel, not just ours.
- `telemetry.localShipper: true` registers a separate local shipper. Local testing proves events are emitted, not how the real shipper queues/drains them.

---

## Event size and drain time

Rule lifecycle events carry 4 tiny properties (`ruleId`, `ruleType`, `isPrebuilt`, `isCustomized`).
Almost all the weight is the context stamped on every event by the core, licensing, cloud and status context providers.

Measured with a synthetic event with every context field filled in (ECH-like values), sized the same way the shipper does (`Buffer.from(JSON.stringify(event)).length`):

| | Bytes |
|---|---:|
| Context alone | ~820 |
| Full `detection_rule_install` / `detection_rule_import` event | **~1,040** |
| Events per ~10KB batch | ~10 |

That works out to roughly **1 event/second** leaving Kibana.

| Scenario | Events | Queue size | Batches | Time to drain |
|---|---:|---:|---:|---:|
| Full prebuilt install (current package) | 2,117 | ~2.1MB | ~212 | **~35 min** |
| Max import (`maxRuleImportExportSize` default) | 10,000 | ~10MB | ~1,000 | **~2h 47m** |

Caveat: synthetic, not captured from a real deployment. Serverless/ECH context may be a bit bigger or smaller. Order of magnitude should hold.

### CPU/memory cost

Every send tick, the shipper runs `getQueueByteSize` over the **whole** queue, i.e. it JSON-stringifies every queued event. Measured locally:

| Queue | Cost per tick (every 10s) |
|---|---:|
| 2,117 events | ~2ms |
| 10,000 events | ~10ms |

Memory is the queue itself (~2MB / ~10MB). Both are negligible for a Kibana process.

---

## What it means: installing ~2K prebuilt rules

- One `installation/_perform` for all rules queues ~2,117 events. That's ~21% of the queue cap. No drops.
- They trickle out over ~35 min. Timestamps are taken at `reportEvent`, so the data is still correct once it lands. It just arrives late.
- If Kibana restarts cleanly mid-drain, shutdown flushes the rest in one request. A crash/kill loses whatever is still queued.
- Installing all rules in 5 spaces within ~35 min (~10.5K events) would overflow. Anything past 10K is dropped, and so is any other `kibana-server` event reported while the queue is full.

## What it means: importing up to 10K rules

- This is already happening on `main`. `detectionRulesClient.importRules()` loops over `result.successes` and reports one `detection_rule_import` per rule.
- A max-size import fills the queue by itself. If anything else is already queued (a recent install, other plugins' events), the tail of the import is dropped with `queue_full`.
- While it drains (~2h45m), **every other** server-side EBT event on this Kibana is dropped too, not just rule events. That's the worst side effect: one big import can blank out unrelated telemetry for hours.
- Real-world imports near 10K are rare, but a single 10K import is the realistic worst case.

## Failure modes (both scenarios)

| Risk | Trigger | Impact |
|---|---|---|
| Queue overflow | >10K events queued (big import, back-to-back bulk ops) | Excess dropped, including other teams' events |
| Failed POST | Network error / non-2xx from telemetry endpoint | That ~10-event batch is lost, no retry |
| Crash before drain | Kibana killed during the ~35 min / ~2h45m drain | Remaining queue lost |
| Offline > 24h | Air-gapped or blocked egress | Queue cleared (already true for all EBT) |

---

## Options

| Option | Effect | Cost |
|---|---|---|
| Keep one event per rule (this PR) | Same as pre-#275523 install and current import. No drops for a single install | Slow drain; shares queue risk with import |
| One summary event per bulk op (e.g. counts by `ruleType` / prebuilt / customized) | 1 event instead of 2K–10K. No queue pressure | New event type + schema; loses per-rule `ruleId`. Dashboards would need changing |
| Hybrid: per-rule below a threshold, summary above | Keeps detail for small ops, protects the queue for big ones | Two shapes of data to query; more code |

For PR #293496 the first option is fine. It restores the event the route used to send, and ~2K is well inside the cap. The 10K import case is the one worth a follow-up issue, since it can starve other teams' telemetry.

## Suggested reply to Maxim

> Checked the server shipper (`@elastic/ebt` 1.4.1). It queues up to 10K events and drains ~10KB every 10s. An install event is ~1KB with context, so a full ~2K install queues ~2MB and takes ~35 min to send, with no drops. `importRules` already sends one event per rule and can hit 10K, so this doesn't add a new risk. If we want to harden it, a summary event for bulk ops would be the fix, and import is the better place to start. Happy to open a follow-up issue.

## How to verify for real

- Grab one `detection_rule_install` event from the local shipper log and check its byte size to replace the synthetic ~1KB.
- On an ECH deployment, run a full install with `logging.loggers: [{ name: analytics, level: debug }]` and watch the `Reporting N events...` lines to confirm ~10 events per 10s.
- To see drops, subscribe to `analytics.telemetryCounter$` (core analytics setup contract) and look for `type: 'dropped'`, `code: 'queue_full'` from `elastic_v3_server` after a large import. I didn't find an existing server-side subscriber, so this likely needs a throwaway dev hook.

## Sources

- `node_modules/@elastic/ebt/shippers/elastic_v3/server/src/server_shipper.js`: queue cap, cadence, leaky bucket, drop/flush logic
- `node_modules/@elastic/ebt/client/src/analytics_client/analytics_client.js`: `reportEvent`, context stamping, pre-opt-in buffer
- `src/platform/plugins/shared/telemetry/server/plugin.ts`: shipper registration, local shipper
- Context providers: `src/core/packages/{analytics,environment,elasticsearch,status}/server-internal/…`, `x-pack/platform/plugins/shared/{licensing,cloud}/common/…`
- `x-pack/solutions/security/plugins/security_solution/server/config.ts`: `maxRuleImportExportSize` default 10000
- `upstream/main` `detection_rules_client.ts`: `importRules` per-rule `DETECTION_RULE_IMPORT_EVENT`

