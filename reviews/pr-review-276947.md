# PR Review: #276947 — [Alerting V2] Rule versioning using change history datastream

**PR:** [elastic/kibana#276947](https://github.com/elastic/kibana/pull/276947) by @adcoelho
**Linked issue:** [elastic/rna-program#643](https://github.com/elastic/rna-program/issues/643) — "Store rule changes in the change history data stream"
**Scale:** Substantive (67 files, ~1,600 insertions).

---

### Context / Motivation

[rna-program#643](https://github.com/elastic/rna-program/issues/643) asks for rule versioning on top of the lifecycle events from rna-program#504:

> "The work in elastic/rna-program#504, will emit rule events for every change of a rule. We should listen to these events to add a record to the change history data stream."
>
> DoD: Create a `RuleHistoryService` that uses `@kbn/change-history`, and a subscriber under `alerting_v2/server/lib/events` that listens to rule events and records changes.

The PR delivers that shape (named `RuleChangesHistoryService` / `RuleChangesHistorySubscriber`), plus a persisted per-rule counter (`metadata.version`) used as `object.sequence` in change history and as `rule.version` on generated alert events. That counter is not spelled out in the issue DoD; it matches the `@kbn/change-history` guidance of storing a monotonic field on the tracked object itself.

Design discussion on the PR: [@cnasikas initially argued](https://github.com/elastic/kibana/pull/276947#discussion_r3550935029) the history index should be the source of truth and the SO should not carry the counter; [he later agreed](https://github.com/elastic/kibana/pull/276947#discussion_r3585608711) (after offline discussion) that the monotonic number does need to live on the SO. [@maximpn asked](https://github.com/elastic/kibana/pull/276947#discussion_r3585246809) for a caller-supplied starting sequence on create (relevant to delete→recreate / type-change upgrades) — [author replied](https://github.com/elastic/kibana/pull/276947#discussion_r3595502620) that was planned as internal logic and pinged cnasikas. Naming settled on [`metadata.version`](https://github.com/elastic/kibana/pull/276947#discussion_r3595652383) (integer) vs top-level OCC `version` (string).

### Summary

Adds a server-managed `metadata.version` (int ≥ 1) on every alerting v2 rule, bumped on each successful mutation (create, update, upsert, enable/disable, delete emit, and bulk variants that actually write). Mutations publish enriched lifecycle events (`{ ruleId, spaceId, rule }`); a new `RuleChangesHistorySubscriber` maps those asynchronously into `.kibana_change_history` via `@kbn/change-history`. Workflow bindings still project only `{ ruleId, spaceId }`. Alert / recovery / no-data / continued-breach executor paths stamp `rule.metadata.version` onto events. Snapshots are typed as `Omit<RuleResponse, 'version'>` (OCC stripped in the subscriber). Scout `rule_history.spec.ts` asserts action + sequence + snapshot shape for the main mutation paths.

Intent (issue + PR description) and diff line up, with the SO counter as the main addition beyond the written DoD. Security/V1 portability (action override, metadata, await/refresh, sequence seed, solution segregation) is deferred to [rna-program#797](https://github.com/elastic/rna-program/issues/797).

### Files touched

- **Schemas / API** (`alerting-v2-schemas` `rule_data_schema.ts`, attachment schema): response requires `metadata.version`; input schemas do not accept it; top-level `version` description clarified as OCC token.
- **SO storage** (`rule_saved_object_attributes` v1/v2, `rule_model_versions.ts`, migration fixture `10.3.0.json`): model version 3 backfills `metadata.version: 1`; field not indexed.
- **RulesClient** (`rules_client.ts`, `utils.ts`): `getNextVersion()`, stamp on all mutation paths; emits full `RuleResponse` on lifecycle events; empty PATCH always emits `ruleUpdated`.
- **Event publisher / workflows** (`rule_event_publisher/*`, `rule_workflow_subscriber/triggers/*`): payload enriched; workflow `toPayload` strips to ref only.
- **Change-history lib** (`lib/rule_changes_history/*`): client factory, service, optional ResourceManager initializer, constants/tokens.
- **Subscriber** (`rule_changes_history_subscriber/*`): maps 5 lifecycle events → ECS action/type via `RULE_LIFECYCLE_TO_CHANGES_HISTORY_MAP`; strips OCC; author from `userProfile.getCurrent`; omits `timestamp` (defaults to now); skips events without `rule`/version.
- **DI / startup** (`bind_services.ts`, `bind_events.ts`, `bind_on_start.ts`, `register_resources.ts`, `init_subscribers.ts`).
- **Executor** (`create_alert_events_step.ts`, recovery / `classify_absent_groups_step.ts`): all stamp `rule.metadata.version` (old hardcoded-`1` no-data step is gone).
- **Tests**: unit coverage for service/subscriber/client emits; many fixtures gain `version: 1`; Scout `rule_history.spec.ts` (+ helper) asserts action/sequence/module/dataset/snapshot for create/update/upsert/enable/disable/delete.

### Flow trace

`PUT`/`PATCH` update path:

1. Route → `RulesClient.updateRule` (`rules_client.ts:374`).
2. `getExistingRule` loads SO attrs + OCC token.
3. `getNextVersion(existingAttrs.metadata.version)` (`:395`, helper `:148–150`).
4. `buildUpdateRuleAttributes` forces server `metadata.version` after merging the patch (`utils.ts`) — client cannot set it.
5. `writeRuleAttrs` updates with OCC token (`:414–418`); conflict → `RULE_VERSION_CONFLICT`.
6. Transform to `RuleResponse` (fallback `RULE_VERSION_FALLBACK = 1` if missing).
7. `emitRuleUpdated` → domain bus (fire-and-forget; handlers on next tick).
8. `RuleWorkflowSubscriber` projects `{ rule: { ruleId, spaceId } }`; `RuleChangesHistorySubscriber.#dispatch` resolves author, strips OCC via `toRuleChangesHistorySnapshot`, calls `logRuleChanges` with `sequence = metadata.version`, `snapshot` (no `timestamp` → defaults to `new Date()`).
9. `RuleChangesHistoryService` → `ChangeHistoryClient.logBulk` on `.kibana_change_history`.
10. Failures in 8–9 are logged and swallowed; API caller is unaffected.

### Assumptions

- OCC on the SO write keeps `metadata.version` unique under concurrent mutations (single-rule paths pass the version token; bulk enable/disable pass per-doc versions).
- Change history is best-effort: bus is async, service/subscriber swallow errors, process crash between SO write and `logBulk` loses the entry with no backfill.
- Data-stream provisioning may fail without blocking rule execution (`optional: true`); CRUD still bumps version even when history writes fail.
- Delete ordering uses an emitted-only sequence bump (never persisted on the SO) — by design so deletion sorts after the last real change.
- Bulk enable/disable intentionally skip already-enabled/disabled rules (no self-heal); single enable/disable intentionally do not skip (self-heal). [Author restored single-path self-heal](https://github.com/elastic/kibana/pull/276947#discussion_r3644355291) after briefly aligning with bulk no-ops; [cnasikas asked](https://github.com/elastic/kibana/pull/276947#discussion_r3623322059) whether the original self-heal behavior was intentional.
- Change history is on for every v2 rule (subscriber started unconditionally in `init_subscribers.ts`; `@kbn/change-history` `FEATURE_ENABLED` is hardcoded `true`) — [@maximpn notes](https://github.com/elastic/kibana/pull/276947#discussion_r3583383832) the flag is cleaned up when changes history goes GA in 9.5.0. Unlike v1 / security_solution gating patterns.

### Risks

1. ~~**Rule-ID reuse restarts the sequence and corrupts history ordering.**~~ **Deferred — see activity #12 / [rna-program#797](https://github.com/elastic/rna-program/issues/797).** [Pushed back to author](https://github.com/elastic/kibana/pull/276947#discussion_r3646981452) (activities #2/#3). `metadata.version` restarts at 1 when a rule is deleted and re-created with the same id — and alerting v2 explicitly supports client-chosen ids (`createRule` `options.id`, and the upsert route). The deletion entry for the old generation carries `sequence: N+1` (`rules_client.ts:484`), so under `getHistory`'s sequence-first sort (`kbn-change-history/src/client.ts:294`) the old generation's entries permanently sort *above* the new generation's — history for a reused id reads interleaved and wrong. The package docs require the sequence to survive "reindexing, upgrades, failovers"; object recreation is an unhandled case. Thread: [author skepticism](https://github.com/elastic/kibana/pull/276947#discussion_r3639341529) → [detection-rules type-change delete+recreate precedent + `initialRevision`](https://github.com/elastic/kibana/pull/276947#discussion_r3646981452) ([#274605](https://github.com/elastic/kibana/pull/274605)/[#275627](https://github.com/elastic/kibana/pull/275627)) → ~~[may be moot in V2 (no rule types)](https://github.com/elastic/kibana/pull/276947#discussion_r3672360055)~~ → **[UPDATE: restore keeps delete→recreate alive](https://github.com/elastic/kibana/pull/276947#discussion_r3672360055)**. Claude re-raised ([T63](https://github.com/elastic/kibana/pull/276947#discussion_r3683011892)); still no seed in code.
   - [Raised with author. Suggestion: let the caller pass `version` on create](https://github.com/elastic/kibana/pull/276947#discussion_r3647075822). Also aligns with [maximpn's earlier ask](https://github.com/elastic/kibana/pull/276947#discussion_r3585246809). Needs either an id-reuse guard, seeding the new counter from the last history entry, caller-supplied initial version, or a generation/epoch tiebreak in the package. Tracked in #797 DoD.

2. **Empty PATCH is now a real mutation** (`rules_client.ts:422`, removed `Object.keys(parsed).length > 0` guard). A body-less/no-op PATCH now bumps the version, rewrites the SO, logs a history entry, *and fires the `alerting.ruleUpdated` workflow trigger*. The test frames the version/history alignment as intentional (`rules_client.test.ts` empty-PATCH emit case), but the workflow side effect is externally observable and wasn't previously there. Guard was dropped to close a sequence gap flagged by Bugbot ([discussion_r3596056367](https://github.com/elastic/kibana/pull/276947#discussion_r3596056367)).
   - [Raised with author](https://github.com/elastic/kibana/pull/276947/changes#r3657535521) why empty `PATCH {}` updates are allowed at all.
   - **Status:** Accepted after author explanation ([T45](https://github.com/elastic/kibana/pull/276947#discussion_r3657535521)) — intentional for version/history alignment.

3. **Deletion history entries carry a stale timestamp.** The subscriber used `rule.updatedAt ?? rule.createdAt`; `deleteRule` bumps the counter on the emitted rule but never touches `updatedAt`. So the `rule_delete` history doc was stamped with the *last update* time, not the deletion time. Ordering survives (reads sort by `object.sequence` first), but anyone rendering the timestamp would show the wrong deletion time. Violates `@kbn/change-history` README guidance (capture `Date.now()` after delete). [@maximpn flagged](https://github.com/elastic/kibana/pull/276947#discussion_r3585278875) pre-write timestamps; [author addressed it](https://github.com/elastic/kibana/pull/276947#discussion_r3638832044) by wiring `RuleResponse.updatedAt` in `c5a0e7e` — which for deletes was still the last edit.
   - [Raised with author](https://github.com/elastic/kibana/pull/276947/changes#r3657808923): delete `@timestamp` should be confirm-time; with `object.sequence` as primary order, omit the override and let `logRuleChanges` default to `new Date()` for create/update/delete.
   - **Status: Fixed** in [`52fa16cb`](https://github.com/elastic/kibana/pull/276947/commits/52fa16cbe4de03cc0cfcbc6ee79a2897a6c288ff). Subscriber omits `timestamp` → `logRuleChanges` defaults to `new Date()`. Unit test: *“omits timestamp so logRuleChanges defaults to now”*. [Confirmed + resolved](https://github.com/elastic/kibana/pull/276947#discussion_r3681148446). Stale AI threads [T43](https://github.com/elastic/kibana/pull/276947#discussion_r3639230460)/[T44](https://github.com/elastic/kibana/pull/276947#discussion_r3639230480)/[T51](https://github.com/elastic/kibana/pull/276947#discussion_r3672423103) still open on GH — safe to resolve.

4. **A failed data-stream init kills history for the process lifetime.** Provisioning is an `optional` resource so rule execution proceeds ([cnasikas](https://github.com/elastic/kibana/pull/276947#discussion_r3622528241)). Init is once per Kibana server start; after retries status sticks on `failed`; subsequent writes warn/error and drop. Restart is the recovery path.
   - **Status: Ignored for this PR — same as V1.** V1 `ChangeTrackingService.initialize()` is also fire-and-forget at plugin start; per-module failures are logged and skipped without blocking Kibana; later writes drop with “not initialized” warns and there is no mid-process re-init. V2 matches that tradeoff.

5. ~~**Self-heal enable/disable / bulk skip asymmetry.**~~ Enabling an already-enabled rule (intentionally not short-circuited) bumps the version and writes a `rule_enable` history entry. [Author restored single-path self-heal](https://github.com/elastic/kibana/pull/276947#discussion_r3644355291). Bulk still skips already-enabled/disabled ([T34](https://github.com/elastic/kibana/pull/276947#discussion_r3623322059); [asked to mirror single/V1](https://github.com/elastic/kibana/pull/276947#discussion_r3665490131)).
   - **Status: Ignored for this PR.** Alerting/RnA ownership — not a Security review blocker.

6. **Bulk operations amplify writes N×.** The publisher emits one event per rule, so a bulk-enable of 100 rules produces 100 single-doc `logBulk` calls (100 ES bulk requests) plus 100 `userProfile.getCurrent` lookups — the batching affordance of `logBulk` goes unused. `correlationId` ties the entries together but doesn't reduce the fan-out. Fine at current scale; a cost concern if bulk ops grow.
   - **Status: Ignored for this PR** — [nudged on PR](https://github.com/elastic/kibana/pull/276947#discussion_r3690146438); will be addressed later.

7. **`metadata.version` is now required in the public response schema.** Any consumer doing strict equality on `metadata` breaks — the PR itself had to touch ~15 test fixtures. Low blast radius since alerting v2 is new, but it's a contract change.

8. **Two different "version" fields on one response**: top-level `version` (SO OCC token, string) vs `metadata.version` (change counter, int). The descriptions were improved, but the collision is a standing confusion hazard for API consumers.
   - **Status: Tabled.** Naming/architecture call for ResponseOps ([Maxim](https://github.com/elastic/kibana/pull/276947#discussion_r3681296701); Christos keep `metadata.version` this PR; [prefer `sequence`](https://github.com/elastic/kibana/pull/276947#discussion_r3689255530)). Not a Security blocker for merge.

9. **Deletion change-history snapshot is synthetic** (see activity #7a). On delete, `metadata.version` is bumped to N+1 on a rule that is never persisted, and that fabricated value is stored inside `object.snapshot.metadata.version` — so the deletion entry claims a version the rule never had. Separating ordering (`object.sequence: N+1`) from the snapshot (true pre-delete rule, version N) would keep the stored state faithful. Same synthetic object originally drove the stale-timestamp Risk #3.
   - **Status: Ignored** — nit. Ordering via bumped sequence is intentional; Scout documents current behavior. Not worth blocking.

10. **Change-history wiring lacks integration coverage** (see activity #9). The transformation logic is well covered seam-by-seam (subscriber 12 tests, service 10, rules_client 42 emit assertions) with type-checked mocks, and `@kbn/change-history` tests its own write — so most breaks are caught. Residual gaps: DI wiring + resource registration are unexercised (no test references the tokens / `createChangeHistoryClient` / `RULE_CHANGES_HISTORY_RESOURCE_KEY`); the initializer test is shallow (1 delegating test, no failed-init path per Risk #4); and `service.test.ts:135` claims "logs a warning" but only asserts it doesn't throw, so the sole silent-failure signal is untested.
    - **Status: Partially addressed** (see activity #16). Scout [`rule_history.spec.ts`](x-pack/platform/plugins/shared/alerting_v2/test/scout_alerting_v2/api/tests/rule_history.spec.ts) (+ helper) asserts action, sequence, module/dataset/objectType, and snapshot shape for create/update/upsert/enable/disable/delete. Residual gaps above remain; no delete→recreate sequence continuity test; route specs only assert `metadata.version` (history docs live in the dedicated spec — placement mismatch vs [T48](https://github.com/elastic/kibana/pull/276947#discussion_r3665151799)).

11. **`create_no_data_events_step` still hardcodes `ruleVersion: 1`.** Alert and recovery steps use `rule.metadata.version`; no-data and continued-breach events did not (`create_no_data_events_step.ts:161,174`). After a rule has been updated past version 1, those event types carried a stale `rule.version`. Looked like an incomplete sweep — and there was no test asserting the real version on that step.
    - **Status: Fixed.** Step removed / folded into `classify_absent_groups_step.ts`, which stamps `rule.metadata.version` for no-data and continued-breach events (same as alert/recovery).

12. **UI enable/disable is recorded as `rule_update`, not `rule_enable`/`rule_disable`** (see activity #6). `useToggleRuleEnabled` previously PATCHed via `rulesApi.updateRule(id, { enabled })`. Dedicated enable/disable endpoints exist and map to the right change-history actions, but the UI never called them. Related: `updateRule` uses `checkLimit: existingAttrs.enabled`, so enabling a disabled rule through that PATCH also skipped the schedule-limit check that `enableRule` enforces.
    - **Status: Fixed.** `useToggleRuleEnabled` now calls `rulesApi.enableRule` / `disableRule` (`use_toggle_rule_enabled.ts:21`).

13. **Bulk delete can omit history entries.** If pre-delete `bulkGetByIds` misses a rule, emit is a bare `{ ruleId, spaceId }` and the subscriber skips it. Workflow `ruleDeleted` still fires; change history does not.
    - **Status: Ignored.** Edge case with a good reason — miss means the rule wasn’t found, so there’s nothing meaningful to snapshot/track.

14. ~~**No caller override for change-history `event.action` — potential blocker for Security / V1 UI portability**~~ **Deferred to follow-up — see activity #12 / [rna-program#797](https://github.com/elastic/rna-program/issues/797).** Originally [raised as 🔴 Blocker](https://github.com/elastic/kibana/pull/276947#discussion_r3659296272) (activities #10/#11). V1 lets callers pass `changeTracking.action` on create/update/bulkCreate so a create can be logged as `rule_install`, `rule_duplicate`, `rule_import`, etc. ([`createPrebuiltRule` → `rule_install`](https://github.com/elastic/kibana/blob/db177565d4ff1477ac4cc9787f6f0751793496dc/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.ts#L140-L143); [bulk duplicate → `rule_duplicate`](https://github.com/elastic/kibana/blob/db177565d4ff1477ac4cc9787f6f0751793496dc/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/bulk_actions/route.ts#L390-L396)). V2 has no equivalent: `CreateRuleParams` only accepts `data` + `options.id`, lifecycle events carry no action override, and [`RULE_LIFECYCLE_TO_CHANGES_HISTORY_MAP`](https://github.com/elastic/kibana/blob/dc6ac5a24cacb9a600ddfb0a129b9f75936ce543/x-pack/platform/plugins/shared/alerting_v2/server/lib/events/rule_changes_history_subscriber/mappings.ts#L35-L41) hard-maps `rule.created` → `rule_create`. The V2 action enum is also narrower (create/update/delete/enable/disable only). Until this exists, the existing Security rule-changes-history UI (which keys labels/filters/icons off install/duplicate/import/upgrade/restore actions) is not really portable from V1 to V2 — every install/duplicate would show up as a plain create.
    - **Status:** Still deferred / unchanged in code. Live create-path comparison posted in activity #19.

15. **Broader V1↔V2 change-tracking / RulesClient parity gaps** — ~~same blocker thread~~ **also deferred to [rna-program#797](https://github.com/elastic/rna-program/issues/797)** (see activities #11/#12). Beyond action override, V2 is missing several contracts Security and the V1 UI already depend on:
    - **No `changeTracking.metadata`** — V1 logs `bulkCount`, `originalRuleSoId`, `restoredFromChangeId`, `restoredFromRevision` into the history doc ([duplicate passes `bulkCount` + `originalRuleSoId`](https://github.com/elastic/kibana/blob/db177565d4ff1477ac4cc9787f6f0751793496dc/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/bulk_actions/route.ts#L390-L396)); V2 `LogRuleChangesParams` has no metadata field at all.
    - **No `changeTracking.refresh`** — V1 can `wait_for` so restore/refetch sees the new entry immediately ([`restore_deleted_rule`](https://github.com/elastic/kibana/blob/db177565d4ff1477ac4cc9787f6f0751793496dc/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/restore_rule_from_history/restore_deleted_rule.ts#L70-L74); [`restore_rule_state`](https://github.com/elastic/kibana/blob/db177565d4ff1477ac4cc9787f6f0751793496dc/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/restore_rule_from_history/restore_rule_state.ts#L71-L75)); V2 never passes `refresh` to `logBulk`.
    - **No `getHistory` on RulesClient / HTTP API** — V1 exposes [`RulesClient.getHistory`](https://github.com/elastic/kibana/blob/db177565d4ff1477ac4cc9787f6f0751793496dc/x-pack/platform/plugins/shared/alerting/server/rules_client/rules_client.ts#L208) (authz, deleted-rule fallback, snapshot rehydration). V2 only writes; nothing reads history back through the plugin.
    - **No create-time sequence seed** — V1 [`options.initialRevision`](https://github.com/elastic/kibana/blob/db177565d4ff1477ac4cc9787f6f0751793496dc/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/create/create_rule.ts#L52-L55) (also used on restore); V2 `getNextVersion()` always starts at 1 (ties to Risk #1).
    - **No `bulkCreateRules`** — V1 bulk-create accepts `changeTracking` (install batches); V2 is single-create / upsert only.
    - **Module/dataset mismatch** — V1 scopes by `ruleType.solution` + dataset `alerting-rules`; V2 hardcodes module [`alerting-v2`](https://github.com/elastic/kibana/blob/dc6ac5a24cacb9a600ddfb0a129b9f75936ce543/x-pack/platform/plugins/shared/alerting_v2/server/lib/rule_changes_history/constants.ts#L10-L14) / dataset `rules`. Shared Security history UI / aggregations keyed on V1 module won't see V2 entries without a dual-read or remap.
    - **Write timing** — V1 `await`s `logRuleChanges` in the mutation path; V2 publishes fire-and-forget on the domain bus (caller can't rely on history being searchable after create returns — compounds the missing `refresh`; restore flows need both).
    - **Gating polarity flipped** — V1 off by default (`ruleChangeTracking.enabled` + scope + Security advanced setting); V2 always on for every rule.
    - Note: V2 *does* track single enable/disable (V1 only logs those via bulk enable/disable / snooze paths) — not a gap, just asymmetry the other way. Rule-level snooze / `updateApiKey` actions exist in V1 but map to different V2 concepts (action policies / episodes), so treat as model divergence not a missing emit.
    - **Status updates:** #797 expanded Jul 31 (activity #17) — solution segregation still open DoD; **V1→V2 history continuity** accepted as intentional break (migration keeps a separate V1 copy; [thread](https://github.com/elastic/kibana/pull/276947#discussion_r3674089728)). Live payload comparison in activity #19 confirms partitioning / sequence / snapshot-shape gaps in the wild.

16. **Half-dead `scope` on the change-history service** (see activity #13). `RuleChangesHistoryService` stores `{ module, dataset, objectType }` but only ever reads `objectType`; module/dataset are already owned by the DI `ChangeHistoryClient`. Misleading dead state + unused `RuleChangesHistoryScope` fields — cleanup, not a runtime bug.
    - **Status: Ignored for this PR** — cleanup later ([T53](https://github.com/elastic/kibana/pull/276947#discussion_r3673436805) can stay open as a nit).

### Open questions

- How do we ensure future rule mutations are also tracked? Tracking today is opt-in per mutation path: each `RulesClient` method must call `getNextVersion` and emit a lifecycle event ([rules_client.ts](x-pack/platform/plugins/shared/alerting_v2/server/lib/rules_client/rules_client.ts) — create/update/delete/enable/disable/bulk/upsert each do it by hand; see activity #7b). The subscriber only reacts to those events; there is no SO-layer interceptor or lint that forces new methods to participate. Unit tests assert emits for *existing* paths (`rules_client.test.ts`), but a new mutation that forgets bump+emit would silently skip history. Is the intended guarantee “remember to wire it + add a test”, or should architecture make omission hard?
  - *Note:* Scout `rule_history.spec.ts` now covers the current paths end-to-end; a new untested mutation path would still silently skip.
- Is the stale deletion timestamp (Risk #3) intentional? Stamping `updatedAt: nowIso` on the emitted (never persisted) rule in `deleteRule`/`bulkDeleteRules` would fix it cheaply ([maximpn's timestamp concern](https://github.com/elastic/kibana/pull/276947#discussion_r3585278875)).
  - **Answered — fixed:** omit override → `logRuleChanges` defaults to `new Date()`.
- Was firing workflow `ruleUpdated` triggers on an empty PATCH considered, or is it an accepted side effect of aligning version and history (Risk #2)? A guard could still bump/persist the version while skipping the workflow projection.
  - **Answered — accepted** for version/history alignment ([T45](https://github.com/elastic/kibana/pull/276947#discussion_r3657535521)).
- Should a no-transition enable/disable write history at all, or write it with a distinguishable action so consumers can filter self-heal noise (Risk #5)?
  - *Related:* ~~Should bulk enable/disable mirror single-path self-heal?~~ **Ignored** — Alerting concern ([T34](https://github.com/elastic/kibana/pull/276947#discussion_r3623322059)).
- If data-stream provisioning fails at startup (optional resource), does anything retry initialization, or is change history dead until restart (Risk #4)?
  - **Ignored for this PR** — optional init preferred over failing Kibana; failures are logged; restart is recovery.
- ~~For bulk-delete rules whose pre-read failed…?~~ **Ignored** — miss means not found; nothing meaningful to track (Risk #13).
- `RULE_VERSION_FALLBACK` lives in `lib/rule_changes_history/constants.ts` but is consumed by `rules_client/utils.ts` for the API response — it's really a rule-schema concern; consider relocating. **Confirmed as a layering finding — see activity #7c.**
- Is change history intended to be unconditionally on for every v2 rule, or should it inherit v1's flag+scope gating (`xpack.alerting.ruleChangeTracking.enabled` / `scope`)? Currently there's no opt-out — see activity #8 / [PR #276307](https://github.com/elastic/kibana/pull/276307).
- Is delete→recreate with the same client-chosen id a supported v2 flow (Risk #1)? If yes, should create accept an initial `version` ([maximpn](https://github.com/elastic/kibana/pull/276947#discussion_r3585246809) / [follow-up](https://github.com/elastic/kibana/pull/276947#discussion_r3647075822)), or seed from the last history entry?
  - **Answered — yes for restore** ([UPDATE](https://github.com/elastic/kibana/pull/276947#discussion_r3672360055)); seed/`initialRevision` deferred to #797. No Scout test for same-id continuity yet.
- Is `create_no_data_events_step` still on `1` an oversight (Risk #11)?
  - **Answered — fixed** (uses `rule.metadata.version` via `classify_absent_groups_step`).
- Should the UI toggle call `enableRule`/`disableRule` instead of PATCH `updateRule` (Risk #12)?
  - **Answered — fixed** (`useToggleRuleEnabled` calls enable/disable APIs).
- Any planned integration/Scout coverage that mutates a rule and reads `.kibana_change_history` back (Risk #10)?
  - **Answered — yes**, `rule_history.spec.ts` (residual gaps in Risk #10 remain).
- ~~Is a V1-style `changeTracking.action` (and metadata) override planned for V2 mutation APIs / lifecycle events (Risk #14)?~~ **Answered — deferred to [rna-program#797](https://github.com/elastic/rna-program/issues/797); see activity #12.** Original blocker: [discussion_r3659296272](https://github.com/elastic/kibana/pull/276947#discussion_r3659296272).
- Will V2 expose a `getHistory` (or equivalent) read path with authz + snapshot rehydration, or is history write-only for now (Risk #15)? *(partially in #797 DoD via restore/sync UX; read-path itself may still be separate)*
- Should V2 history keep writing under module `alerting-v2` / dataset `rules`, or align with V1's solution-scoped `alerting-rules` so shared consumers can query one place (Risk #15)?
  - **Answered — intentional break OK** for V1→V2 migration model (separate rule copy); **solution segregation** (security/obs/stack) still needed → #797 DoD. Confirmed live in activity #19.
- ~~Is fire-and-forget (bus) vs V1's awaited write intentional for callers that need post-mutation history visibility?~~ **Answered — deferred to [rna-program#797](https://github.com/elastic/rna-program/issues/797) DoD** (await/`refresh: 'wait_for'` vs accepted UX alternative); see activity #12 / [discussion_r3659296272](https://github.com/elastic/kibana/pull/276947#discussion_r3659296272).
- Prefer `metadata.sequence` over `metadata.version` ([comment](https://github.com/elastic/kibana/pull/276947#discussion_r3689255530))? Christos leaning keep `version` for this PR.

### Notes for your codebase map

- alerting_v2 is inversify-DI: `server/setup/bind_*.ts`, tokens via `Symbol.for(...)`, singletons vs request-scope at bind time.
- Domain event bus is fire-and-forget (publish returns sync; handlers isolated). Subscribers start from `initSubscribers` on plugin start.
- `ResourceManager` supports `optional: true` resources (init failure does not block readiness); retries via `RetryService`, then permanent `failed` unless `ensureResourceReady` is called again.
- `@kbn/change-history` writes `.kibana_change_history`, scoped by `module`/`dataset`; `object.sequence` beats `@timestamp` on read; package docs say delete timestamps should be wall-clock after delete.
- Two "version" fields on the API response: top-level `version` (OCC string) vs `metadata.version` (change counter int). History snapshots strip OCC (`RuleChangesHistorySnapshot = Omit<RuleResponse, 'version'>`).
- SO schema files (`v1.ts`/`v2.ts`) are versioned separately from the model-version map — model version `3` uses schema `v2`.
- V2 rule SO has **no** execution `apiKey` (lives on TM task via `cloneApiKey`); safer for change-history snapshots. Action policies still encrypt `auth.apiKey`.
- V1→V2 rule migration is copy-then-delete (not same-uuid continuity) — separate history streams are acceptable by design; solution segregation (security/obs/stack) is still unresolved.

### Review activities

1. **Examined the PR from the `@kbn/change-history` package-owner perspective.** Findings:

   - Sequence restarts on rule-ID reuse (delete → re-create same id resets `metadata.version` to 1; `getHistory` sequence-sort interleaves generations).
   - `LogChangeHistoryOptions['data']` typing forced an `as` cast — `data.event` typed as the full object but `logBulk` only honors `type`/`reason`.
   - Per-rule fan-out: bulk ops make N single-doc `logBulk` calls; batch affordance unused.
   - Failed `initialize()` has no re-init path, `isInitialized()` unused.
   - `_id` = uuidv7 per write → retries duplicate docs; a derived `_id` would be idempotent.

2. **Dug further into the sequence-restart-on-ID-reuse problem (delete `N+1` vs create-at-1).** Confirmed the mechanics end to end: `createRule` calls `getNextVersion()` with no argument (`rules_client.ts:322`), the upsert create path delegates there (`rules_client.ts:973`), the deletion bump produces `sequence: N+1` (`rules_client.ts:484`), and `getHistory`'s sequence-first sort (`kbn-change-history/src/client.ts:294`) is what makes the two generations interleave on read. A viable fix would be seeding the counter from the last history entry (`getHistory` with `size: 1`, falling back to 0 when there is no history) when the caller supplies an id — noting that read depends on the data stream being initialized (see Risk #4).

3. **Conversation with the author about id reuse / create restarting at 1.** [Author: "IDK if a delete-then-recreate of the same id scenario is realistic."](https://github.com/elastic/kibana/pull/276947#discussion_r3639341529) Replied with the detection-rules precedent (type-change upgrades delete and recreate by the same id, which is why v1 added `initialRevision` to `createRule()` in [#274605](https://github.com/elastic/kibana/pull/274605)/[#275627](https://github.com/elastic/kibana/pull/275627)): [discussion_r3646981452](https://github.com/elastic/kibana/pull/276947#discussion_r3646981452). Follow-up suggestion: [let the caller pass `version` (→ `object.sequence`) on create](https://github.com/elastic/kibana/pull/276947#discussion_r3647075822), same shape as v1 `revision` — awaiting author's call on approach.

4. **Investigated the alerting_v2 plugin architecture** — produced a high-level report and manual testing instructions: [`kibana-knowledge/architecture/kibana-v2-high-level-architecture.md`](../architecture/kibana-v2-high-level-architecture.md).

5. **Ran the code locally to debug both flows.** Enabled the feature flags (`alerting:v2:enabled` advanced setting + the `xpack.alerting_v2` config), created/updated a rule, and traced both the V2 alerting operation and the change-history flow end to end — confirming the rule SO carries `metadata.version` and that mutations write ordered snapshots to `.kibana_change_history`.

6. **Found via manual testing: enabling a stack rule via the UI logs the wrong change-history action.** Caught by toggling a rule in the running UI and inspecting `.kibana_change_history` — not visible from the diff alone. The UI toggle calls `PATCH /{ruleId}` with `{ enabled: true }` (`use_toggle_rule_enabled.ts:21`, `rulesApi.updateRule`) instead of the dedicated enable endpoint, so the change-history entry is recorded as `rule_update` rather than `rule_enable`. Fix belongs elsewhere (client should call the appropriate enable/disable method), not in this PR's mapping.

7. **Focused review — architecture** (module boundaries, dependency direction, scope). Three findings:

   **(a) Delete paths fabricate a snapshot and embed change-history sequencing** (new — raised as Risk #9):
   - `deleteRule` (`rules_client.ts:480-486`) and `executeBulkDelete` (`:677`) build a `RuleResponse` whose `metadata.version` is bumped to N+1 — a value never persisted (the SO is being deleted).
   - That bumped version travels both as `object.sequence` (ordering) and inside `object.snapshot.metadata.version`, so the stored deletion snapshot claims a version the rule never had. Ordering and snapshot fidelity are conflated; passing `sequence: N+1` while snapshotting the true pre-delete rule (version N) would separate them.
   - The "+1 so the deletion orders after the last change" rule is change-history domain knowledge hardcoded in the core mutation path, duplicated across both delete sites. (Same synthetic object is the root of the stale-timestamp Risk #3.)

   **(b) Version-stamping responsibility is half-centralized, half-inlined**:
   - create/update/upsert route `version` through the transform helpers (`transformCreateRuleBodyToRuleSoAttributes`, `buildUpdateRuleAttributes` take it as a serverField).
   - enable (`:507`), disable (`:554`), bulkEnable (`:726`), bulkDisable (`:830`), delete (`:484`), bulkDelete (`:677`) each inline the same `metadata: { ...metadata, version: getNextVersion(...) }` spread.
   - Same responsibility expressed two ways across ~8 sites; a single `bumpVersion(attrs)` helper (or routing enable/disable through `buildUpdateRuleAttributes`) would centralize it.

   **(c) `RULE_VERSION_FALLBACK` inverts dependency direction**:
   - `rules_client/utils.ts:232`, the core rule→API-response transform, imports the constant from the `rule_changes_history` feature module; the baseline version is a rule-model concern (the SO `v2.ts` comment already owns the "readers fall back to `RULE_VERSION_FALLBACK`" semantics).
   - The barrel re-exports runtime values (`RuleChangesHistoryService`, `createChangeHistoryClient`, `RuleChangesHistoryInitializer`), so a pure attribute transform transitively loads the whole feature module. Fix: move the constant to the rule schema / `saved_objects` layer.

8. **Confirmed change history is unconditionally on for every v2 rule** (raised as Open question) — no config flag or scope (`init_subscribers.ts:24` starts the subscriber unconditionally; `@kbn/change-history` hardcodes `FEATURE_ENABLED: true`), unlike v1 which gates behind `xpack.alerting.ruleChangeTracking.enabled` (default false) + `scope`. Relevant to storage growth and the bulk write-amplification cost (Risk #6).

9. **Focused review — test coverage.** Assessed the server-side unit tests before judging the gap. Transformation logic is well covered seam-by-seam (subscriber 12 tests incl. the failure path asserting `mockLogger.error`; service 10; rules_client 42 emit assertions) with type-checked mocks, and `@kbn/change-history` tests its own write — so the "headline feature untested" framing was overstated. Real residual gaps (raised as Risk #10): DI wiring + resource registration unexercised; initializer test shallow (no failed-init path, relevant to Risk #4); `service.test.ts:135` asserts only "does not throw", not the warning its title claims.

10. **Checked whether V2 supports overriding the change-tracking action (V1 parity) — gap / potential blocker** (raised as Risk #14; **[posted blocker on PR](https://github.com/elastic/kibana/pull/276947#discussion_r3659296272)**). V1 `createRule` / `bulkCreateRules` / `updateRule` accept `changeTracking?: RuleChangeTracking` and default only when omitted (`action: changeTracking?.action ?? RuleChangeTrackingAction.ruleCreate`). Security relies on this — e.g. [`DetectionRulesClient.createPrebuiltRule` forces `rule_install`](https://github.com/elastic/kibana/blob/db177565d4ff1477ac4cc9787f6f0751793496dc/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.ts#L140-L143); [bulk duplicate forces `rule_duplicate`](https://github.com/elastic/kibana/blob/db177565d4ff1477ac4cc9787f6f0751793496dc/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/bulk_actions/route.ts#L390-L396); import/upgrade/restore do the same with their own actions. V2 path: `CreateRuleParams` has no `changeTracking`; `emitRuleCreated` payload is `{ ruleId, spaceId, rule }`; subscriber always takes [`RULE_CHANGES_HISTORY_MAPPINGS[event.type]`](https://github.com/elastic/kibana/blob/dc6ac5a24cacb9a600ddfb0a129b9f75936ce543/x-pack/platform/plugins/shared/alerting_v2/server/lib/events/rule_changes_history_subscriber/mappings.ts#L35-L41) (`rule.created` → `rule_create`); V2 `RuleChangesHistoryAction` has no install/duplicate/import variants. Consequence: existing Security changes-history UI (action-specific labels/filters) is not portable to V2 until callers can override the logged action (and ideally pass metadata like `originalRuleSoId` / `bulkCount`).

11. **Audited broader V1↔V2 RulesClient change-tracking parity** (raised as Risk #15; same [blocker comment](https://github.com/elastic/kibana/pull/276947#discussion_r3659296272) also calls out metadata / refresh / awaited write). Compared V1 methods that call `logRuleChanges` / accept `changeTracking` / expose `getHistory` against V2 `RulesClient` + `RuleChangesHistoryService`. Extra gaps beyond action override:
    - **Caller context:** V1 [`RuleChangeTracking`](https://github.com/elastic/kibana/blob/db177565d4ff1477ac4cc9787f6f0751793496dc/src/platform/packages/shared/kbn-alerting-types/rule_types.ts#L61-L80) carries `action` + `metadata` (`bulkCount`, `originalRuleSoId`, `restoredFromChangeId`, `restoredFromRevision`) + `refresh`. Accepted on create / update / bulkCreate / bulkEdit / bulkEditParams; bulkDelete accepts metadata only. V2 mutation params have none of this; `LogRuleChangesParams` has no metadata/refresh. Production examples: [duplicate metadata](https://github.com/elastic/kibana/blob/db177565d4ff1477ac4cc9787f6f0751793496dc/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/bulk_actions/route.ts#L390-L396); [`refresh: 'wait_for'` on restore](https://github.com/elastic/kibana/blob/db177565d4ff1477ac4cc9787f6f0751793496dc/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/restore_rule_from_history/restore_deleted_rule.ts#L70-L74).
    - **Read path:** V1 [`RulesClient.getHistory`](https://github.com/elastic/kibana/blob/db177565d4ff1477ac4cc9787f6f0751793496dc/x-pack/platform/plugins/shared/alerting/server/rules_client/rules_client.ts#L208) (module-scoped, authz, deleted-rule fallback, rehydrates snapshot → `Rule`). V2: write-only service; no RulesClient method, no HTTP route.
    - **Sequence seed:** V1 [`options.initialRevision`](https://github.com/elastic/kibana/blob/db177565d4ff1477ac4cc9787f6f0751793496dc/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/create/create_rule.ts#L52-L55) on create; V2 always `getNextVersion()` → 1.
    - **Bulk create:** V1 `bulkCreateRules({ changeTracking })` (Security install batches); V2 has single `createRule` + `upsertRule` only.
    - **Indexing scope:** V1 `module = ruleType.solution`, dataset `alerting-rules`; V2 hardcoded [`alerting-v2` / `rules`](https://github.com/elastic/kibana/blob/dc6ac5a24cacb9a600ddfb0a129b9f75936ce543/x-pack/platform/plugins/shared/alerting_v2/server/lib/rule_changes_history/constants.ts#L10-L14) — different query surface from the Security UI / usage aggregations.
    - **Durability vs latency:** V1 awaits the history write inside the mutation; V2 emits on the async domain bus (no caller-visible completion / refresh) — restore needs both await + [`refresh: 'wait_for'`](https://github.com/elastic/kibana/blob/db177565d4ff1477ac4cc9787f6f0751793496dc/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/restore_rule_from_history/restore_rule_state.ts#L71-L75).
    - **Gating:** V1 config flag (default false) + scope + per-type `trackChanges` + Security advanced setting; V2 unconditional.
    - **Not a gap / model divergence:** V2 logs single enable/disable (V1 only does bulk enable/disable for those actions). V1 `snooze` / `unsnooze` / `updateApiKey` rule actions don't map 1:1 onto V2 rule mutations (snooze lives on action policies / episodes).

12. **Created follow-up [rna-program#797](https://github.com/elastic/rna-program/issues/797)** — *[Alerting v2] Address portability gap for detection rule change history `V1` → `V2`* — so Security/V1 parity work does not block this PR. Issue captures: action override (`rule_install` / `duplicate` / `import` / …), change-tracking `metadata`, await/`refresh: 'wait_for'` vs async-bus restore UX, delete→recreate `object.sequence` ordering, and a documented A (pass-through options) vs B (dedicated `installRule`/`duplicateRule` methods) decision. Risks #14/#15 (and the related open questions) are deferred there.

   Relevant PR thread:
   - [Blocker: need action/metadata/refresh override](https://github.com/elastic/kibana/pull/276947#discussion_r3659296272) (sdesalas)
   - [cnasikas: start simple; prefer dedicated RulesClient methods; defer](https://github.com/elastic/kibana/pull/276947#discussion_r3665509622)
   - [adcoelho: OK as follow-up to unblock RnA UI versioning](https://github.com/elastic/kibana/pull/276947#discussion_r3666448220)
   - [sdesalas: prefer pass-through `action` over dedicated methods (`rule_install` is Security-foreign)](https://github.com/elastic/kibana/pull/276947#discussion_r3667323337)
   - [Ticket created → #797](https://github.com/elastic/kibana/pull/276947#discussion_r3667730520) (sdesalas)
   - Related sequence / id-reuse: [detection-rules delete+recreate + `initialRevision`](https://github.com/elastic/kibana/pull/276947#discussion_r3646981452), [caller-supplied `version` on create](https://github.com/elastic/kibana/pull/276947#discussion_r3647075822), [may be moot in V2 — no rule types](https://github.com/elastic/kibana/pull/276947#discussion_r3672360055) (points at #797)

13. **Focused review — dead / orphaned code.** Three findings:

   **(a) Half-dead `scope` on `RuleChangesHistoryService`** (new — raised as Risk #16):
   - Constructor builds `this.scope = { module, dataset, objectType }` (`rule_changes_history_service.ts:47-51`), but only `this.scope.objectType` is ever read (`:69`).
   - `module` / `dataset` already live on the DI-scoped `ChangeHistoryClient` via `createChangeHistoryClient` — duplicating them on the service is dead state that suggests the service owns scoping when it doesn't.
   - Fix: drop `RuleChangesHistoryScope` (or shrink it to `objectType`), keep a private `objectType` constant.

   **(b) Barrel re-exports with zero external importers** (nit):
   - `index.ts` re-exports `RULE_CHANGES_HISTORY_MODULE` / `DATASET` / `OBJECT_TYPE` and types `LogRuleChangesParams` / `RuleChangesHistoryAuthor` / `RuleChangesHistoryEntry` / `RuleChangesHistoryScope`, but every consumer either imports from a relative file or doesn't need them. Trim the public surface to what's actually imported (`RuleChangesHistoryAction*`, tokens, service, client factory, initializer, resource key, `RULE_VERSION_FALLBACK`).
   - Same class: `RuleChangesHistoryMapping` is exported from `mappings.ts` and never imported outside that file — can stay file-private.

   **(c) Sole-caller dead branches in the service** (nit / overlaps over-engineering):
   - Production has one caller (`RuleChangesHistorySubscriber`), which always passes `entries: [one]` and a defined `eventType`. The `entries.length === 0` early-return and the `!eventType → omit data` path are unreachable in prod (only exercised by unit tests). Fine as a general service API, but today they're dead weight relative to the actual wiring.

   **Checked clean:** all five `RuleChangesHistoryAction` values are mapped + tested; tokens / initializer / `createChangeHistoryClient` are wired; SO schema v1+v2 both used by model versions; no commented-out blocks or leftover rename files. `stop()` is prod-unwired but matches sibling subscribers. `isInitialized()` / `getHistory()` unused on the package client — already covered by Risks #4 / #15.

14. **Researched change-history snapshots as domain `RuleResponse` vs SO attrs.** Wrote [`alerting-v2-change-history-domain-vs-so.md`](../reports/alerting-v2-change-history-domain-vs-so.md). Confirms history is append-only and must follow the API shape (SO migrations never rewrite old snapshots); restore needs a reverse transform + sequence seed that do not exist yet. Gaps that mattered for this PR: snapshot typed as `Record<string, unknown>`, OCC `version` inconsistent across emit paths, no reverse map, no generation marker. Posted typing ask ([T62](https://github.com/elastic/kibana/pull/276947#discussion_r3681845394)) — landed in [`1ba05180`](https://github.com/elastic/kibana/pull/276947/commits/1ba05180b3): `RuleChangesHistorySnapshot = Omit<RuleResponse, 'version'>`, `sequence` required, subscriber `toRuleChangesHistorySnapshot()` strips OCC.

15. **Researched V1 vs V2 API-key placement** (side quest from domain-vs-SO). Wrote [`alerting-v1-vs-v2-api-keys.md`](../reports/alerting-v1-vs-v2-api-keys.md). V2 rules store no `apiKey` on the rule SO (execution identity lives on the Task Manager task via `cloneApiKey: true`); only action-policy `auth.apiKey` is encrypted. Consequence for this PR: logging `RuleResponse` snapshots cannot accidentally persist rule execution secrets the way dumping V1 SO attrs could. Also strengthens why single enable self-heal matters (re-schedules task + key), not just flips `enabled`.

16. **Full comment triage of all 63 review threads** (verified against code, not GH resolve flags). Wrote [`pr-276947-comment-triage.md`](../reports/pr-276947-comment-triage.md) @ PR tip `1758357668`. ~40 addressed · ~7 not addressed · ~8 unsure/trap/deferred. Punch list still open on this PR: bulk self-heal ([T34](https://github.com/elastic/kibana/pull/276947#discussion_r3623322059)), `RuleChangesHistoryScope` ([T53](https://github.com/elastic/kibana/pull/276947#discussion_r3673436805)), delete→recreate / overrides deferred to #797, optional Scout placement nits. GH traps: stale AI timestamp threads; several “resolved” threads that are only ticketed not implemented.

17. **Updated [rna-program#797](https://github.com/elastic/rna-program/issues/797)** (Jul 31). Expanded beyond the original action/metadata/refresh blocker: solution segregation in `.kibana_change_history` (security vs obs vs stack), restore as the live delete→recreate path, A vs B decision (pass-through options vs dedicated RulesClient methods), and explicitly marked V1→V2 history continuity as *not* needing addressing (migration keeps a separate V1 copy). DoD checklist still open; no comments on the issue yet.

18. **Re-verified open risks against current branch** (`alerting-v2-rule-versioning` @ `98ba7625`, one trivial commit behind PR tip `17583576`). Status:
    - **Fixed since last review doc:** Risk #3 (timestamp → now), #11 (no-data uses `metadata.version`), #12 (UI toggle → enable/disable APIs), #10 partially (Scout `rule_history.spec.ts`), snapshot typing (domain report gap / T62).
    - **Accepted / deferred:** #2 (empty PATCH), #1/#14/#15 → #797, #5 single-path OK.
    - **Still open in this PR:** none for Security review.
    - **Ignored / tabled:** #4 (optional init — V1 parity); #5 (bulk self-heal — Alerting); #6 (bulk N× — later / TODO); #8 (naming — RnA / TODO); #9 (synthetic delete — nit, not on TODO); #13 (bulk-delete miss — not found); #16 (`RuleChangesHistoryScope` — TODO).
    - **New comments since activities #12–13:** module/dataset/objectType continuity threads → #797 then accepted intentional break; naming preference for `sequence` ([r3689255530](https://github.com/elastic/kibana/pull/276947#discussion_r3689255530)); bulk fan-out nudge ([r3690146438](https://github.com/elastic/kibana/pull/276947#discussion_r3690146438)).

19. **Local create-path test — captured live V1 vs V2 change-history payloads** and [posted on the PR](https://github.com/elastic/kibana/pull/276947#issuecomment-5142325831). Side-by-side confirms the contract gaps in the wild:
    - **Partitioning:** V1 `event.module=stack` / `dataset=alerting-rules` / `object.type=alert` vs V2 `alerting-v2` / `rules` / `alerting_rule` — separate streams (Risk #15 / #797).
    - **Sequence:** V2 has `object.sequence: 1` (= `snapshot.metadata.version`); V1 create has **no** `object.sequence` (uses `revision: 0` inside the snapshot instead).
    - **ECS type:** V1 create logged as `event.type: change`; V2 as `creation`.
    - **Secrets:** V1 hashes `apiKey` (`object.fields.hashed: ["apiKey"]`, truncated value still in snapshot); V2 hashes nothing — no rule apiKey on the domain snapshot (matches API-keys report / activity #15).
    - **Snapshot shape:** V1 is the classic rule SO/API blob (`alertTypeId`, `params`, `revision`, …); V2 is `RuleResponse`-shaped (`kind`, `metadata.*`, `query`, …) with OCC stripped.

### Follow-up TODO (slipped from this PR)

Items Steven wants tracked after #276947.

1. **Create-time sequence seed / delete→recreate ordering** — restore (and same-id recreate) must continue `object.sequence`, not restart at 1. Documented under [rna-program#797](https://github.com/elastic/rna-program/issues/797).
2. **Caller overrides: `action` / `metadata` / `refresh` + await** — V1-style `changeTracking` so Security can log install/duplicate/import/restore, pass metadata, and wait for history visibility. Documented under [rna-program#797](https://github.com/elastic/rna-program/issues/797).
3. **Solution segregation in change history** — distinguish security / observability / stack (e.g. `event.module`), not one hard-coded `alerting-v2` stream. Documented under [rna-program#797](https://github.com/elastic/rna-program/issues/797).
4. **`getHistory` (or equivalent) read path** — RulesClient/HTTP read with authz + snapshot rehydration. Future PR (not blocking #797 write-time gaps).
5. **Bulk history write fan-out** — batch N rule changes into one `logBulk` (and avoid N× `userProfile.getCurrent`). Future performance-optimization PR. PR nudge: [r3690146438](https://github.com/elastic/kibana/pull/276947#discussion_r3690146438).
6. **Naming: `metadata.version` vs `sequence`** — discuss with RnA / ResponseOps first (architecture call), then any rename. Thread: [r3689255530](https://github.com/elastic/kibana/pull/276947#discussion_r3689255530).
7. **`RuleChangesHistoryScope` cleanup** — drop/shrink half-dead scope type (only `objectType` used). Nit / cleanup. [T53](https://github.com/elastic/kibana/pull/276947#discussion_r3673436805).
8. **Make forgetting bump+emit hard for future mutators** — today each `RulesClient` path must manually `getNextVersion` + emit (open question / activity #7b). Want a better guarantee; approach TBD (no preferred design yet).
