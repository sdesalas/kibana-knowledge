# PR Review: #276947 — [Alerting V2] Rule versioning using change history datastream

**PR:** [elastic/kibana#276947](https://github.com/elastic/kibana/pull/276947) by @adcoelho
**Linked issue:** [elastic/rna-program#643](https://github.com/elastic/rna-program/issues/643) — "Store rule changes in the change history data stream"
**Scale:** Substantive (67 files, ~1,600 insertions — full analysis).

## Context / Motivation

Issue #643 (rna-program) asks for rule versioning built on top of the rule-lifecycle events introduced by rna-program #504:

> "The work in elastic/rna-program#504, will emit rule events for every change of a rule. We should listen to these events to add a record to the change history data stream."
>
> DoD: "Create a `RuleHistoryService` service that will internally use the `@kbn/change-history` package… Create a `RuleEventRuleHistorySubscriber` in `x-pack/platform/plugins/shared/alerting_v2/server/lib/events` that will listen to rule events and record the changes."

The PR delivers exactly that shape (named `RuleChangesHistoryService` / `RuleChangesHistorySubscriber`), plus one thing the issue doesn't spell out: a persisted, monotonically increasing per-rule counter (`metadata.version`) that becomes `object.sequence` in the change-history index and `rule.version` on generated rule events. The stated intent and the diff line up; the counter is the necessary extra to make history entries orderable.

## Summary

Adds a server-managed version counter to every alerting v2 rule (`metadata.version`, starting at 1, incremented on every successful mutation including enable/disable and delete), and records each mutation as a snapshot document in the `.kibana_change_history` data stream. The `RulesClient` now emits rule-lifecycle events carrying the full post-change rule; a new `RuleChangesHistorySubscriber` maps those events to change-history entries asynchronously, while the existing workflow trigger bindings project the payload back down to `{ ruleId, spaceId }` so the full rule never leaks into workflows. Rule executor steps stop hardcoding `ruleVersion: 1` and stamp the real counter on alert/recovery events.

## Files touched

- **Public API / schemas** (`alerting-v2-schemas`: `rule_data_schema.ts`, `rule_attachment_schema.ts`): `ruleResponseSchema` now requires `metadata.version` (int ≥ 1); attachment schema keeps it optional since by-value proposed rules have no counter. The pre-existing top-level `version` (SO OCC token) gets a clarified description.
- **Saved object storage** (`saved_objects/schemas/rule_saved_object_attributes/{index,v1,v2}.ts`, `model_versions/rule_model_versions.ts`, `kbn-check-saved-objects-cli` fixture `10.3.0.json`): schema v2 adds optional `metadata.version`; model version 3 backfills pre-existing rules to `1`. No mappings change (field is not indexed on the SO).
- **RulesClient** (`rules_client.ts`, `utils.ts`): every mutation path (`create`, `update`, `upsert`, `enable`, `disable`, `delete`, and the bulk variants) computes `getNextVersion()` and persists it (except delete, which stamps the bump only on the emitted event). All emits now pass `{ ruleId, spaceId, rule }`. `transformRuleSoAttributesToRuleApiResponse` falls back to `RULE_VERSION_FALLBACK = 1` for unmigrated docs.
- **Event payloads** (`rule_event_publisher/events.ts`, `rule_event_publisher.ts`): payload reshaped from `{ rule: { ruleId, spaceId } }` to a flat `{ ruleId, spaceId, rule?, correlationId? }`. Bulk emits (>1 rule) share a generated `correlationId`.
- **Workflow trigger bindings** (`rule_workflow_subscriber/triggers/*.ts`): `toPayload` now projects only `{ rule: { ruleId, spaceId } }` instead of forwarding the payload unchanged — deliberate containment so rule state doesn't reach workflows.
- **New change-history lib** (`lib/rule_changes_history/*`): `RuleChangesHistoryService` (wraps `ChangeHistoryClient.logBulk`, swallows+warns on failure), `createChangeHistoryClient` (scoped to module `alerting-v2` / dataset `rules`), `RuleChangesHistoryInitializer` (provisions the data stream as an **optional** ResourceManager resource), DI tokens, constants.
- **New subscriber** (`rule_changes_history_subscriber/*`): maps the 5 lifecycle events to ECS `event.action`/`event.type` pairs, resolves the author via `userProfile.getCurrent({ request })`, uses `rule.metadata.version` as `object.sequence` and the full rule as `object.snapshot`. Skips events with no `rule` or no version.
- **DI wiring** (`setup/bind_services.ts`, `bind_events.ts`, `bind_on_start.ts`, `resources/register_resources.ts`, `lib/events/init_subscribers.ts`): singleton client + service + subscriber; data-stream init on plugin start.
- **Rule executor** (`create_alert_events_step.ts`, `create_recovery_events_step.ts`): `ruleVersion: 1` → `rule.metadata.version`.
- **Tests**: unit coverage for all new pieces; many UI/hook test fixtures gain `version: 1`; scout API specs assert version starts at 1 and increments on update/upsert-replace.

## Flow trace (rule update)

1. `PUT` rule route → `RulesClient.updateRule` (`rules_client.ts:374`).
2. `getExistingRule(id)` reads the SO — attributes plus the OCC version token.
3. `getNextVersion(existingAttrs.metadata.version)` → counter + 1 (`rules_client.ts:395`).
4. `buildUpdateRuleAttributes` merges the patch and **forces** the server-computed `version` into metadata after spreading `updateData.metadata` (`utils.ts`) — a client-supplied `metadata.version` can't leak through.
5. `writeRuleAttrs` updates the SO passing the OCC token (`rules_client.ts:414-418`); a concurrent writer gets a 409 (`RULE_VERSION_CONFLICT`), so two mutations can never persist the same counter value.
6. `transformRuleSoAttributesToRuleApiResponse` builds the `RuleResponse`; `metadata.version` is always populated (fallback 1).
7. `emitRuleUpdated(request, [{ ruleId, spaceId, rule }])` → the event bus dispatches each handler via `setImmediate` — fire-and-forget, the HTTP response is never blocked, handler errors are logged and isolated (`event_bus.ts`).
8. `RuleWorkflowSubscriber` projects `{ rule: { ruleId, spaceId } }` and fires the `alerting.ruleUpdated` workflow trigger; `RuleChangesHistorySubscriber.#dispatch` resolves the author profile from the request, then calls `logRuleChanges`.
9. `RuleChangesHistoryService.logRuleChanges` maps to `ObjectChange { objectId, sequence: metadata.version, snapshot: rule, timestamp: rule.updatedAt }` and calls `ChangeHistoryClient.logBulk`, which writes to `.kibana_change_history` using the internal ES client captured at initialization.
10. Failures anywhere in 8–9 are caught and logged (`RULE_CHANGES_HISTORY_SUBSCRIBER_FAILURE` / a service-level warn); they never surface to the API caller.

## Assumptions

- **OCC guarantees sequence uniqueness.** Verified: every single-rule mutation passes the SO version token to `update`, and bulk enable/disable pass `doc.version` per item. Without this the read-increment-write counter would be racy.
- **Change history is best-effort, not transactional.** The bus is fire-and-forget; if Kibana dies between the SO write and the subscriber flush, that history entry is silently lost. No reconciliation/backfill exists.
- **The data stream got provisioned at startup.** The initializer is registered as an `optional` resource so a provisioning failure doesn't block rule execution — but then `logBulk` throws "not initialized" on every write and history is dead (warn-level noise) until whatever retry semantics `ResourceManager` has kick in.
- **`userProfile.getCurrent({ request })` is meaningful for the mutating request.** For API-key/system requests it returns null → author `{ uid: null, username: null }` → stored as `username: ''`. The snapshot still carries `updatedBy` (profile uid) so attribution isn't fully lost.
- **Pre-delete reads are close enough.** `bulkDeleteRules` captures state via an extra `bulkGetByIds` before deleting; a rule mutated in that window emits a slightly stale snapshot/sequence. Rules whose pre-read failed emit a bare ref and get **no** deletion history entry (documented skip in the subscriber).

## Risks

1. ~~**Rule-ID reuse restarts the sequence and corrupts history ordering.**~~ **[Pushed back to author](https://github.com/elastic/kibana/pull/276947#discussion_r3646981452) — see activities #2/#3; awaiting their call on approach.** `metadata.version` restarts at 1 when a rule is deleted and re-created with the same id — and alerting v2 explicitly supports client-chosen ids (`createRule` `options.id`, and the upsert route). The deletion entry for the old generation carries `sequence: N+1`, so under `getHistory`'s sequence-first sort (`kbn-change-history/src/client.ts:294`) the old generation's entries permanently sort *above* the new generation's — history for a reused id reads interleaved and wrong. The package docs require the sequence to survive "reindexing, upgrades, failovers"; object recreation is an unhandled case. Needs either an id-reuse guard, seeding the new counter from the last history entry, or a generation/epoch tiebreak in the package.
2. **Empty PATCH is now a real mutation** (`rules_client.ts:422`, removed `Object.keys(parsed).length > 0` guard). A body-less/no-op PATCH now bumps the version, rewrites the SO, logs a history entry, *and fires the `alerting.ruleUpdated` workflow trigger*. The test frames the version/history alignment as intentional, but the workflow side effect is externally observable and wasn't previously there.
3. **Deletion history entries carry a stale timestamp.** The subscriber uses `rule.updatedAt ?? rule.createdAt`; `deleteRule` bumps the counter on the emitted rule but never touches `updatedAt`. So the `rule_delete` history doc is stamped with the *last update* time, not the deletion time. Ordering survives (reads sort by `object.sequence` first), but anyone rendering the timestamp will show the wrong deletion time.
4. **A failed data-stream init silently kills history with no recovery.** Provisioning is registered as an `optional` resource so rule execution proceeds, but then every mutation hits `ChangeHistoryClient`'s "not initialized" throw — swallowed into per-write warn/error noise, with no re-init path until restart. `isInitialized()` is never consulted. A transient ES hiccup at startup means change history is silently absent for the process lifetime.
5. **Self-heal enable/disable inflates history.** Enabling an already-enabled rule (intentionally not short-circuited) bumps the version and writes a `rule_enable` history entry every time. Idempotent automation looping over rules will generate noisy, change-free history.
6. **Bulk operations amplify writes N×.** The publisher emits one event per rule, so a bulk-enable of 100 rules produces 100 single-doc `logBulk` calls (100 ES bulk requests) plus 100 `userProfile.getCurrent` lookups — the batching affordance of `logBulk` goes unused. `correlationId` ties the entries together but doesn't reduce the fan-out. Fine at current scale; a cost concern if bulk ops grow.
7. **`metadata.version` is now required in the public response schema.** Any consumer doing strict equality on `metadata` breaks — the PR itself had to touch ~15 test fixtures. Low blast radius since alerting v2 is new, but it's a contract change.
8. **Two different "version" fields on one response**: top-level `version` (SO OCC token, string) vs `metadata.version` (change counter, int). The descriptions were improved, but the collision is a standing confusion hazard for API consumers.
9. **Deletion change-history snapshot is synthetic** (see activity #7a). On delete, `metadata.version` is bumped to N+1 on a rule that is never persisted, and that fabricated value is stored inside `object.snapshot.metadata.version` — so the deletion entry claims a version the rule never had. Separating ordering (`object.sequence: N+1`) from the snapshot (true pre-delete rule, version N) would keep the stored state faithful. Same synthetic object drives the stale-timestamp Risk #3.
10. **Change-history wiring lacks integration coverage** (see activity #9). The transformation logic is well covered seam-by-seam (subscriber 12 tests, service 10, rules_client 42 emit assertions) with type-checked mocks, and `@kbn/change-history` tests its own write — so most breaks are caught. Residual gaps: DI wiring + resource registration are unexercised (no test references the tokens / `createChangeHistoryClient` / `RULE_CHANGES_HISTORY_RESOURCE_KEY`); the initializer test is shallow (1 delegating test, no failed-init path per Risk #4); and `service.test.ts:135` claims "logs a warning" but only asserts it doesn't throw, so the sole silent-failure signal is untested.

## Open questions

- Is the stale deletion timestamp (risk 2) intentional? Stamping `updatedAt: nowIso` on the emitted (never persisted) rule in `deleteRule`/`bulkDeleteRules` would fix it cheaply.
- Was firing workflow `ruleUpdated` triggers on an empty PATCH considered, or is it an accepted side effect of aligning version and history? A guard could still bump/persist the version while skipping the workflow projection.
- Should a no-transition enable/disable write history at all, or write it with a distinguishable action so consumers can filter self-heal noise?
- If data-stream provisioning fails at startup (optional resource), does anything retry initialization, or is change history dead until restart?
- For bulk-delete rules whose pre-read failed, is silently skipping the history entry acceptable, or would a snapshot-less entry (id + sequence unknown) be better than a gap?
- `RULE_VERSION_FALLBACK` lives in `lib/rule_changes_history/constants.ts` but is consumed by `rules_client/utils.ts` for the API response — it's really a rule-schema concern; consider relocating. **Confirmed as a layering finding — see activity #7.**
- Is change history intended to be unconditionally on for every v2 rule, or should it inherit v1's flag+scope gating (`xpack.alerting.ruleChangeTracking.enabled` / `scope`)? Currently there's no opt-out — see activity #8.

## Notes for your codebase map

- alerting_v2 is fully inversify-DI: wiring lives in `server/setup/bind_*.ts`, tokens are `Symbol.for(...)` cast to `ServiceIdentifier<T>`; singletons vs request-scope is set at bind time.
- The alerting domain event bus (`lib/events/event_bus`) is an EventEmitter-based fire-and-forget bus: `publish` returns synchronously, handlers run on `setImmediate`, each isolated in try/catch. Subscribers are singletons started via `initSubscribers` on plugin start.
- SO schema files (`saved_objects/schemas/.../v1.ts, v2.ts`) are versioned independently of the model version map — model version `3` uses schema `v2`. Migration fixtures live in `packages/kbn-check-saved-objects-cli/src/migrations/__fixtures__/<type>/10.N.0.json` where `10.N.0` is the virtual version for model version N.
- `@kbn/change-history` is a reusable package writing to the `.kibana_change_history` data stream, scoped by `module`/`dataset`, with `object.sequence` taking precedence over timestamps when reading history back.
- The plugin's `ResourceManager` supports `optional: true` resources whose init failure doesn't block rule-execution readiness.
- Rule OCC uses the SO version token, surfaced as top-level `version` (string) on the API response — distinct from the new `metadata.version` change counter.

## Review activities

1. **Examined the PR from the `@kbn/change-history` package-owner perspective.** Findings:

   - Sequence restarts on rule-ID reuse (delete → re-create same id resets `metadata.version` to 1; `getHistory` sequence-sort interleaves generations).
   - `LogChangeHistoryOptions['data']` typing forced an `as` cast — `data.event` typed as the full object but `logBulk` only honors `type`/`reason`.
   - Per-rule fan-out: bulk ops make N single-doc `logBulk` calls; batch affordance unused.
   - Failed `initialize()` has no re-init path, `isInitialized()` unused.
   - `_id` = uuidv7 per write → retries duplicate docs; a derived `_id` would be idempotent.

2. **Dug further into the sequence-restart-on-ID-reuse problem.** Confirmed the mechanics end to end: `createRule` calls `getNextVersion()` with no argument (`rules_client.ts:322`), the upsert create path delegates there (`rules_client.ts:973`), the deletion bump produces `sequence: N+1` (`rules_client.ts:484`), and `getHistory`'s sequence-first sort (`kbn-change-history/src/client.ts:294`) is what makes the two generations interleave on read. A viable fix would be seeding the counter from the last history entry (`getHistory` with `size: 1`, falling back to 0 when there is no history) when the caller supplies an id — noting that read depends on the data stream being initialized (see risk #4).

3. **Replied to the author's skepticism about id reuse** with the detection-rules precedent (type-change upgrades delete and recreate by the same id, which is why v1 added `initialRevision` to `createRule()` in [#274605](https://github.com/elastic/kibana/pull/274605)/[#275627](https://github.com/elastic/kibana/pull/275627)): [discussion_r3646981452](https://github.com/elastic/kibana/pull/276947#discussion_r3646981452).

4. **Investigated the alerting_v2 plugin architecture** — produced a high-level report and manual testing instructions: [`kibana-knowledge/architecture/kibana-v2-high-level-architecture.md`](../architecture/kibana-v2-high-level-architecture.md).

5. **Ran the code locally to debug both flows.** Enabled the feature flags (`alerting:v2:enabled` advanced setting + the `xpack.alerting_v2` config), created/updated a rule, and traced both the V2 alerting operation and the change-history flow end to end — confirming the rule SO carries `metadata.version` and that mutations write ordered snapshots to `.kibana_change_history`.

6. **Found via manual testing: enabling a stack rule via the UI logs the wrong change-history action.** Caught by toggling a rule in the running UI and inspecting `.kibana_change_history` — not visible from the diff alone. The UI toggle calls `PATCH /{ruleId}` with `{ enabled: true }` (`use_toggle_rule_enabled.ts:21`, `rulesApi.updateRule`) instead of the dedicated enable endpoint, so the change-history entry is recorded as `rule_update` rather than `rule_enable`. Fix belongs elsewhere (client should call the appropriate enable/disable method), not in this PR's mapping.

7. **Focused review — architecture** (module boundaries, dependency direction, scope). Three findings:

   **(a) Delete paths fabricate a snapshot and embed change-history sequencing** (new — raised as Risk #9):
   - `deleteRule` (`rules_client.ts:480-486`) and `executeBulkDelete` (`:677`) build a `RuleResponse` whose `metadata.version` is bumped to N+1 — a value never persisted (the SO is being deleted).
   - That bumped version travels both as `object.sequence` (ordering) and inside `object.snapshot.metadata.version`, so the stored deletion snapshot claims a version the rule never had. Ordering and snapshot fidelity are conflated; passing `sequence: N+1` while snapshotting the true pre-delete rule (version N) would separate them.
   - The "+1 so the deletion orders after the last change" rule is change-history domain knowledge hardcoded in the core mutation path, duplicated across both delete sites. (Same synthetic object is the root of the stale-timestamp Risk #3.)

   **(b) Version-stamping responsibility is half-centralized, half-inlined** (new):
   - create/update/upsert route `version` through the transform helpers (`transformCreateRuleBodyToRuleSoAttributes`, `buildUpdateRuleAttributes` take it as a serverField).
   - enable (`:507`), disable (`:554`), bulkEnable (`:726`), bulkDisable (`:830`), delete (`:484`), bulkDelete (`:677`) each inline the same `metadata: { ...metadata, version: getNextVersion(...) }` spread.
   - Same responsibility expressed two ways across ~8 sites; a single `bumpVersion(attrs)` helper (or routing enable/disable through `buildUpdateRuleAttributes`) would centralize it.

   **(c) `RULE_VERSION_FALLBACK` inverts dependency direction** (confirms the Open-questions bullet):
   - `rules_client/utils.ts:232`, the core rule→API-response transform, imports the constant from the `rule_changes_history` feature module; the baseline version is a rule-model concern (the SO `v2.ts` comment already owns the "readers fall back to `RULE_VERSION_FALLBACK`" semantics).
   - The barrel re-exports runtime values (`RuleChangesHistoryService`, `createChangeHistoryClient`, `RuleChangesHistoryInitializer`), so a pure attribute transform transitively loads the whole feature module. Fix: move the constant to the rule schema / `saved_objects` layer.

8. **Confirmed change history is unconditionally on for every v2 rule** (raised as Open question) — no config flag or scope (`init_subscribers.ts:24` starts the subscriber unconditionally; `@kbn/change-history` hardcodes `FEATURE_ENABLED: true`), unlike v1 which gates behind `xpack.alerting.ruleChangeTracking.enabled` (default false) + `scope`. Relevant to storage growth and the bulk write-amplification cost (Risk #6).
