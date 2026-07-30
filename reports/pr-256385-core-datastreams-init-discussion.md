# PR #256385 — Core `dataStreams` vs direct `DataStreamClient.initialize`

**PR:** [elastic/kibana#256385](https://github.com/elastic/kibana/pull/256385) — *[SecuritySolution] Create '@kbn/change-history' package*  
**Thread:** [discussion_r2895761023](https://github.com/elastic/kibana/pull/256385#discussion_r2895761023) (on `kbn-change-history/index.ts`)  
**Raised by:** @yngrdyn (2026-03-06)  
**Resolved:** Tabled by @sdesalas (2026-03-18); PR merged 2026-03-20  
**Report date:** 2026-07-30  
**Branch checked:** `alerting-v2-rule-versioning` @ `fba40a5fb75c`

---

## Summary

Review asked whether `@kbn/change-history` should register/init via Core’s `dataStreams` service (`registerDataStream` + `initializeClient`) instead of calling `DataStreamClient.initialize()` directly.

**Decision:** keep the direct-init package API. Parallel multi-plugin init is treated as safe (idempotent; first wins). Revisit only if discoverability or coordinated init becomes a real need.

That call still mostly holds. A few original arguments are stale (notably `_meta.startDate`), and three production consumers now initialize the same `.kibana_change_history` stream.

---

## Thread timeline (permalinks)

| When | Who | Link | Point |
|---|---|---|---|
| Mar 6 | @yngrdyn | [r2895761023](https://github.com/elastic/kibana/pull/256385#discussion_r2895761023) | Other plugins use Core `dataStreams`; direct init means Core can’t list change-history streams. |
| Mar 6 | @sdesalas | [r2895805832](https://github.com/elastic/kibana/pull/256385#discussion_r2895805832) | Fair point; will look at integrating. |
| Mar 9 | @sdesalas | [r2906026417](https://github.com/elastic/kibana/pull/256385#discussion_r2906026417) | Core’s main win is injecting `esClient`; change-history still needs `esClient` for `_meta.startDate`, so API gets *more* params, not fewer. |
| Mar 10 | @jloleysens | [r2910305216](https://github.com/elastic/kibana/pull/256385#discussion_r2910305216) | Small upsides: coordinated updates across Kibanas, registry/discoverability. Not strong enough alone; a cleaner API would need a plugin/service, not just Core wiring. |
| Mar 10 | @yngrdyn | [r2910783299](https://github.com/elastic/kibana/pull/256385#discussion_r2910783299) | Fine with status quo; revisit if listing/coordination is needed. |
| Mar 10 | @sdesalas | [r2910847071](https://github.com/elastic/kibana/pull/256385#discussion_r2910847071) | Package stays more reusable; Core contracts would be drilled through alerting layers (`plugin → RulesClientFactory → ChangeTrackingService → ChangeHistoryClient`). |
| Mar 10 | @jloleysens | [r2911644515](https://github.com/elastic/kibana/pull/256385#discussion_r2911644515) | Agrees package preference; notes `@kbn/core-di-server` as future dep-drilling relief. |
| Mar 11 | @sdesalas | [r2918347084](https://github.com/elastic/kibana/pull/256385#discussion_r2918347084) | Naming meeting → **one shared stream**; race risk if multiple plugins init at once → maybe Core as central owner. |
| Mar 11 | @marshallmain | [r2920817563](https://github.com/elastic/kibana/pull/256385#discussion_r2920817563) | Prefer Core wrapper; ctor takes `DataStreamsSetup`, `initialize` takes only `DataStreamsStart`; keep package (not plugin) for now; later plugin if many consumers need dedupe. |
| Mar 13 | @jloleysens | [r2930616998](https://github.com/elastic/kibana/pull/256385#discussion_r2930616998) | Is init already idempotent in `@kbn/data-streams`? If not, that’s a bug. |
| Mar 16 | @sdesalas | [r2940029260](https://github.com/elastic/kibana/pull/256385#discussion_r2940029260) | Confirms parallel creation handled in [`data_stream.ts` L109](https://github.com/elastic/kibana/blob/4035360c10b2a3a5babca1f506bd74feeeb6cc87/src/platform/packages/private/kbn-data-streams/src/initialize/data_stream.ts#L109); Core mainly caps unbounded parallelism (5 at a time). |
| Mar 18 | @sdesalas | [r2954987972](https://github.com/elastic/kibana/pull/256385#discussion_r2954987972) | **Tables the issue.** First wins; all attempts get a valid client. No pressing reason to change. Confirmed in 17/03 meeting. |

---

## Positions (compressed)

### Against switching (status quo)

- Core registration does not remove the need for a privileged `esClient` in the change-history path (as designed then).
- Extra `DataStreamsSetup` / `DataStreamsStart` params complicate consumer APIs and drill through deep stacks.
- A plain package (esClient in → client out) is more reusable than a Core-coupled or plugin-shaped service.
- `@kbn/data-streams` init is intended to be idempotent under parallel create.

### For switching (Core registry)

- Discoverability: one place to list system/hidden streams for ops / future tooling.
- Coordination: Core can throttle parallel data-stream creates across multi-Kibana clusters.
- With a **single** shared `.kibana_change_history` stream, a central owner feels cleaner than N consumers each calling init.
- Marshall’s sketch: encapsulate Core register/init inside `ChangeHistoryClient` so consumers don’t duplicate definitions.

---

## Decision that shipped

Keep:

```ts
await DataStreamClient.initialize({ dataStream, elasticsearchClient, logger, lazyCreation: false });
```

Do **not** require `core.dataStreams` in `ChangeHistoryClient` setup/start.

Revisit criteria (from thread): need for listing, coordination under many consumers, or moving change-history behind a dedicated plugin/service.

---

## What’s still true (Jul 2026)

1. **Package-over-plugin was right.** alerting_v2 already centralizes one client via DI without making `@kbn/change-history` a plugin — see [`rule_changes_history_initializer.ts`](../../x-pack/platform/plugins/shared/alerting_v2/server/lib/rule_changes_history/rule_changes_history_initializer.ts) and [`bind_services.ts`](../../x-pack/platform/plugins/shared/alerting_v2/server/setup/bind_services.ts).
2. **Idempotent init is the safety net**, not Core registration. Correctness of multi-plugin startup rests on `@kbn/data-streams`, not on a single Core owner.
3. **Dep drilling was a real cost** for v1-style stacks. DI in v2 partially answers [jloleysens’ `@kbn/core-di-server` note](https://github.com/elastic/kibana/pull/256385#discussion_r2911644515).

---

## What’s gone stale

1. **`_meta.startDate` / `esClient` argument.**  
   The Mar 9 case for keeping `esClient` hinged on reading `changeHistoryStartDate` from the data stream `_meta` during `initialize()`. That read is **gone** from today’s client — `initialize()` only builds a definition and calls `DataStreamClient.initialize`:

   - Current: [`x-pack/platform/packages/shared/kbn-change-history/src/client.ts`](../../x-pack/platform/packages/shared/kbn-change-history/src/client.ts) (`initialize` ~L104–139)  
   - No `startDate` / `getDataStream` usage under the package anymore.

   Marshall’s “`initialize(DataStreamsStart)` only” sketch is closer to today’s reality than it was in March.

2. **Multi-consumer init is no longer hypothetical.** Real callers of `ChangeHistoryClient.initialize` / construction today:

   | Consumer | File |
   |---|---|
   | Alerting v1 `ChangeTrackingService` | [`alerting/.../change_tracking/service.ts`](../../x-pack/platform/plugins/shared/alerting/server/rules_client/lib/change_tracking/service.ts) (`initializeAll` ~L107–121; per-solution clients, sequential) |
   | Alerting v2 `RuleChangesHistoryInitializer` | [`alerting_v2/.../rule_changes_history_initializer.ts`](../../x-pack/platform/plugins/shared/alerting_v2/server/lib/rule_changes_history/rule_changes_history_initializer.ts) |
   | Workflows | [`workflows_management/.../workflow_change_history_service.ts`](../../src/platform/plugins/shared/workflows_management/server/services/workflow_change_history_service.ts) |

   All target the shared `.kibana_change_history` stream. Still OK if init stays idempotent; Core’s remaining value is mostly **capping unbounded parallelism**, not correctness.

3. **`system: true` is outside this debate.**  
   Kibana `registerDataStream` / `@kbn/data-streams` cannot mark a stream as an ES system data stream — that requires an ES [`SystemDataStreamDescriptor`](https://github.com/elastic/elasticsearch/pull/154113). Switching to Core registration does **not** buy system-stream semantics.

   - Package README: [`kbn-change-history/README.md` — Retention / system streams](../../x-pack/platform/packages/shared/kbn-change-history/README.md)  
   - Platform docs: [`kbn-data-streams/README.md` — System data streams](../../src/platform/packages/private/kbn-data-streams/README.md)  
   - Related local notes: [`.knowledge/reports/kibana-change-history-system-datastream.md`](./kibana-change-history-system-datastream.md), [`.knowledge/reports/es-snapshot-verify-change-history-system-ds-2026-07-21.md`](./es-snapshot-verify-change-history-system-ds-2026-07-21.md)

---

## Relevant code (current tree)

### Package (direct init — status quo)

- [`x-pack/platform/packages/shared/kbn-change-history/src/client.ts`](../../x-pack/platform/packages/shared/kbn-change-history/src/client.ts) — `DataStreamClient.initialize({ ... })`
- [`x-pack/platform/packages/shared/kbn-change-history/README.md`](../../x-pack/platform/packages/shared/kbn-change-history/README.md) — usage + system-stream note
- [`src/platform/packages/private/kbn-data-streams/src/initialize/data_stream.ts`](../../src/platform/packages/private/kbn-data-streams/src/initialize/data_stream.ts) — parallel-create / idempotency handling (thread cited ~L109 on older SHA)

### Consumers

- Alerting v1: [`change_tracking/service.ts`](../../x-pack/platform/plugins/shared/alerting/server/rules_client/lib/change_tracking/service.ts)
- Alerting v2: [`create_change_history_client.ts`](../../x-pack/platform/plugins/shared/alerting_v2/server/lib/rule_changes_history/create_change_history_client.ts), [`rule_changes_history_initializer.ts`](../../x-pack/platform/plugins/shared/alerting_v2/server/lib/rule_changes_history/rule_changes_history_initializer.ts), [`bind_services.ts`](../../x-pack/platform/plugins/shared/alerting_v2/server/setup/bind_services.ts)
- Workflows: [`workflow_change_history_service.ts`](../../src/platform/plugins/shared/workflows_management/server/services/workflow_change_history_service.ts)

### Core data-streams service (the alternative path)

- Package docs (historically thin at review time): [`src/core/packages/data-streams/server`](../../src/core/packages/data-streams/server)  
- Internal service (thread linked `initializeAllDataStreams`): under `src/core/packages/data-streams/server-internal`

---

## Bottom line / when to reopen

| Trigger | Action |
|---|---|
| Need a single registry for ops/tooling | Revisit Core `registerDataStream` |
| Many more consumers + observed init storms / mapping races | Revisit Core coordination **or** a thin change-history plugin/service that owns one init |
| Want `system: true` | Do **not** reopen this thread — fix ES `SystemDataStreamDescriptor` registration instead |
| alerting_v2-only “dedupe init” | Already largely done via DI singleton; no Core change required |

**Recommendation:** decision still stands. Don’t reopen for correctness. Reopen only for discoverability or measured coordination pain.
