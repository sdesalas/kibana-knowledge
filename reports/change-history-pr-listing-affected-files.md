# Change-history commits / PRs

Inventory for walking [PR 274337](https://github.com/elastic/kibana/pull/274337) against shipped 9.5 behaviour. Dated oldest → newest.

**How this was built**

1. `git log` on Alerting change-tracking + Security Solution history / restore / UI / FTR trees (paths from the 1949 handoff).
2. Every PR **authored by @maximpn and reviewed by @sdesalas**, created or merged **2026-05-01 → 2026-07-15**.
3. Platform `@kbn/change-history` commits that those files also landed in.

`✓` = Steven reviewed. Author is Maxim unless noted.

---

## Walk these (Security Solution + Alerting write path)

These are the feature PRs. Start here when checking the test plan for missed scenarios.

| Date | SHA | PR | Title | Reviewed |
|---|---|---|---|---|
| 2026-03-20 | `7403031042d` | [#256385](https://github.com/elastic/kibana/pull/256385) | Create `@kbn/change-history` package *(sdesalas; the shared client / data stream)* | — |
| 2026-04-28 | `92fb8f8383c` | [#261981](https://github.com/elastic/kibana/pull/261981) | Add core alerting framework capability to support rule change histories *(sdesalas)* | — |
| 2026-05-04 | `626d8b0532e` | [#266096](https://github.com/elastic/kibana/pull/266096) | Add request-scoped change tracking client to the alerting framework *(created 28 Apr, reviewed in May)* | ✓ |
| 2026-05-07 | `238a6fb9029` | [#267350](https://github.com/elastic/kibana/pull/267350) | Instrument RulesClient methods with change tracking | ✓ |
| 2026-05-11 | `07debd7ff7b` | [#268740](https://github.com/elastic/kibana/pull/268740) | Rename `transaction.id` to `span.id` in `@kbn/change-history` | ✓ |
| 2026-05-12 | `a8de3cd4d3e` | [#268894](https://github.com/elastic/kibana/pull/268894) | Add ILM policy for the change history index | ✓ |
| 2026-05-16 | `a0faabae82a` | [#268724](https://github.com/elastic/kibana/pull/268724) | Implement Rule Changes History API | ✓ |
| 2026-05-27 | `ea95b23ea72` | [#270446](https://github.com/elastic/kibana/pull/270446) | Instrument DetectionRulesClient with change tracking | ✓ |
| 2026-05-28 | `08e948e3445` | [#270091](https://github.com/elastic/kibana/pull/270091) | Enable `@kbn/change-history` feature flag | ✓ |
| 2026-05-29 | `cbdf08657d1` | [#271908](https://github.com/elastic/kibana/pull/271908) | Fix rule snooze/unsnooze change history logging | pmuellr only |
| 2026-06-03 | `97ee7f67edb` | [#272552](https://github.com/elastic/kibana/pull/272552) | Fix change tracking for snooze and API key in bulk edit | ✓ |
| 2026-06-17 | `3a59c977fef` | [#269340](https://github.com/elastic/kibana/pull/269340) | Add `rulesClient.bulkCreate()` *(wires change tracking on bulk create)* | — |
| 2026-06-19 | `fb7b562120a` | [#269617](https://github.com/elastic/kibana/pull/269617) | Add MVP UI for rule changes history | ✓ |
| 2026-06-24 | `887935b1f83` | [#273561](https://github.com/elastic/kibana/pull/273561) | Store rule change history snapshots as RuleDomain | ✓ |
| 2026-06-29 | `8673a68d9e4` | [#274605](https://github.com/elastic/kibana/pull/274605) | Implement rule restore from changes history | ✓ |
| 2026-06-30 | `359aa3a158e` | [#274835](https://github.com/elastic/kibana/pull/274835) | Review change history hashing strategy *(sdesalas)* | — |
| 2026-07-02 | `ff3712cfedf` | [#275559](https://github.com/elastic/kibana/pull/275559) | Fix phantom history entries when duplicating rules *(sdesalas)* | — |
| 2026-07-02 | `00f8a7fed8d` | [#275347](https://github.com/elastic/kibana/pull/275347) | Capture rule change timestamp after SO write completes | pmuellr / banderror |
| 2026-07-03 | `97a56f0fe73` | [#275962](https://github.com/elastic/kibana/pull/275962) | Fix misleading change-tracking warning on first-time rule import *(sdesalas)* | maximpn reviewed |
| 2026-07-06 | `15bf28a382a` | [#276307](https://github.com/elastic/kibana/pull/276307) | Add advanced setting to gate rule changes history feature | ✓ |
| 2026-07-08 | `2189628a63f` | [#276163](https://github.com/elastic/kibana/pull/276163) | Add telemetry for rule changes history + restore | denar50 / dejadavi-el |
| 2026-07-10 | `2dc917ca011` | [#276882](https://github.com/elastic/kibana/pull/276882) | Fix rule restore endpoint returning 409 for missing rule | dplumlee |
| 2026-07-13 | `15a69ac3f51` | [#276585](https://github.com/elastic/kibana/pull/276585) | Enable rule changes history feature flags | ✓ |
| 2026-07-14 | `40eda73a6e7` | [#278052](https://github.com/elastic/kibana/pull/278052) | Enable Rule Changes History by default | ✓ |
| 2026-07-15 | `67ce671670d` | [#278353](https://github.com/elastic/kibana/pull/278353) | [Serverless] Fix unresolved usernames in rule changes history | ✓ |
| 2026-07-20 | `bc81ee35436` | [#277380](https://github.com/elastic/kibana/pull/277380) | Add APM instrumentation to read / write / restore *(created 10 Jul, merged after the window)* | ✓ |

---

## Open (not shipped)

| Created | PR | Title | Notes |
|---|---|---|---|
| 2026-06-22 | [#274337](https://github.com/elastic/kibana/pull/274337) | Add test plan for rule changes history | Maxim; Steven pending review `5181813426` |
| 2026-07-14 | [#278197](https://github.com/elastic/kibana/pull/278197) | Remove rule changes history feature flags | Maxim; Steven has not reviewed. Out of scope for plan comments unless the walk says otherwise. |

Closed without merge: [#278094](https://github.com/elastic/kibana/pull/278094) Remove Technical Preview badge *(sdesalas, closed 22 Jul)*.

---

## Platform `@kbn/change-history` (shared; not SS-specific)

Touched the same data stream / client the rule feature uses. Walk only if a plan scenario depends on stream/schema behaviour.

| Date | SHA | PR | Title |
|---|---|---|---|
| 2026-03-20 | `7403031042d` | [#256385](https://github.com/elastic/kibana/pull/256385) | Create `@kbn/change-history` *(same row as the walk table; listed here so the platform sequence is complete)* |
| 2026-04-29 | `a3a99ca08bf` | [#265775](https://github.com/elastic/kibana/pull/265775) | Rename stream to `.kibana_change_history`; snapshots-only schema |
| 2026-05-26 | `050cec40fd0` | [#270637](https://github.com/elastic/kibana/pull/270637) | Map `object.sequence` as long |
| 2026-07-07 | `32ac479a3cb` | [#273498](https://github.com/elastic/kibana/pull/273498) | Drop mappings for unsearched fields |
| 2026-07-10 | `b6483b18220` | [#277413](https://github.com/elastic/kibana/pull/277413) | Serverless: ILM → DSL lifecycle |
| 2026-07-21 | `12a57574e8f` | [#279805](https://github.com/elastic/kibana/pull/279805) | Authorize system data stream test access |
| 2026-07-24 | `794574f13b5` | [#280032](https://github.com/elastic/kibana/pull/280032) | Dedupe product-origin header wiring in tests *(sdesalas)* |
| 2026-07-30 | `469140de257` | [#275846](https://github.com/elastic/kibana/pull/275846) | `getHistoryFieldAggregation` for facets |
| 2026-09-04 | `ca48dfc276c` | [#289303](https://github.com/elastic/kibana/pull/289303) | Preserve snapshot field names containing dots |
| 2026-09-07 | `c53e1c23617` | [#289235](https://github.com/elastic/kibana/pull/289235) | Type write-path action IDs as `ChangeHistoryActionId` |

---

## Do not walk (unless a later pass needs them)

- **Alerting V2** history: `#276947`, `#283373`, `#284942`, `#284976`
- **One Workflow** history UI / client: `#274043`, `#275774`, `#276178`, `#276311`, `#278387`, `#278426`
- **9.5 backports** of the rows above (`#277544`, `#277535`, `#277920`, `#278163`, `#278529`, `#279539`, `#279905`, `#280682`, …)
- **Incidental file hits:** a11y `#280440`, EUI icons `#279452`, OpenAPI `#284885`, Saved Objects bulk types `#274637` / `#277223`, Cloud API keys `#284872`
- **POCs / drafts (not shipped):** `#242589`, `#243218`, `#243221`, `#246920`, `#251471`
- **`#263585`** shows up as the first `git log --diff-filter=A` hit on some alerting / package files. That PR is EDR flaky-test cleanup — a history artifact. Real intro of the package is `#256385`; alerting wiring is `#261981`.

---

## Suggested walk order

For missed test-plan scenarios, go through the first table in date order and ask “what behaviour did this ship that the plan never names?” Highest-yield likely:

1. `#267350` / `#270446` / `#272552` / `#271908` — alerting actions captured (`enable` / `disable` / `snooze` / `unsnooze` / `update_api_key` / bulk edit)
2. `#269617` — shipped UI (auto-select, badges, History *page* not tab)
3. `#274605` / `#276882` — restore identity, 409 cases, deleted-rule recreate
4. `#275559` / `#275962` — duplicate / first import edge cases
5. `#276307` / `#276585` / `#278052` — experimental flag + advanced setting gates
6. `#278353` — serverless username resolution
7. `#273561` / `#274835` — snapshot shape / hashing (upgrade / unreadable snapshot)

---

## Affected files (279 on current `main`)

Union of paths from the walk + platform tables above. Renames resolved to the current path. Deleted files omitted (`ilm_policy.ts`, alerting `change_tracking/disabled.ts`, generated `api_docs/kbn_change_history.*`).

### `@kbn/change-history` (17)

- `x-pack/platform/packages/shared/kbn-change-history/README.md`
- `x-pack/platform/packages/shared/kbn-change-history/index.ts`
- `x-pack/platform/packages/shared/kbn-change-history/integration_tests/client.test.ts`
- `x-pack/platform/packages/shared/kbn-change-history/jest.config.js`
- `x-pack/platform/packages/shared/kbn-change-history/jest.integration.config.js`
- `x-pack/platform/packages/shared/kbn-change-history/kibana.jsonc`
- `x-pack/platform/packages/shared/kbn-change-history/moon.yml`
- `x-pack/platform/packages/shared/kbn-change-history/package.json`
- `x-pack/platform/packages/shared/kbn-change-history/src/client.test.ts`
- `x-pack/platform/packages/shared/kbn-change-history/src/client.ts`
- `x-pack/platform/packages/shared/kbn-change-history/src/constants.ts`
- `x-pack/platform/packages/shared/kbn-change-history/src/mappings.ts`
- `x-pack/platform/packages/shared/kbn-change-history/src/types.ts`
- `x-pack/platform/packages/shared/kbn-change-history/src/utils.test.ts`
- `x-pack/platform/packages/shared/kbn-change-history/src/utils.ts`
- `x-pack/platform/packages/shared/kbn-change-history/test_utils.ts`
- `x-pack/platform/packages/shared/kbn-change-history/tsconfig.json`

### Alerting plugin (60)

- `x-pack/platform/plugins/shared/alerting/common/rule_circuit_breaker_error_message.ts`
- `x-pack/platform/plugins/shared/alerting/moon.yml`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.test.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/index.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/types.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/utils.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_delete/bulk_delete_rules.test.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_delete/bulk_delete_rules.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_delete/types/index.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_disable/bulk_disable_rules.test.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_disable/bulk_disable_rules.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_edit/bulk_edit_rules.test.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_edit/bulk_edit_rules.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_edit/types/bulk_edit_rules_options.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_edit_params/bulk_edit_rule_params.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_edit_params/types/bulk_edit_rule_params_options.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_enable/bulk_enable_rules.test.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_enable/bulk_enable_rules.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/common_utils/log_rule_changes.test.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/common_utils/log_rule_changes.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/create/create_rule.test.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/create/create_rule.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/delete/delete_rule.test.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/delete/delete_rule.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/snooze/snooze_rule.test.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/snooze/snooze_rule.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/unsnooze/unsnooze_rule.test.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/unsnooze/unsnooze_rule.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/update/update_rule.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/update_api_key/update_rule_api_key.test.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/update_api_key/update_rule_api_key.ts`
- `x-pack/platform/plugins/shared/alerting/server/authorization/types.ts`
- `x-pack/platform/plugins/shared/alerting/server/config.test.ts`
- `x-pack/platform/plugins/shared/alerting/server/config.ts`
- `x-pack/platform/plugins/shared/alerting/server/index.ts`
- `x-pack/platform/plugins/shared/alerting/server/plugin.ts`
- `x-pack/platform/plugins/shared/alerting/server/routes/rule/apis/create/create_rule_route.test.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client.mock.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/common/audit_events.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/common/bulk_edit/bulk_edit_rules.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/common/bulk_edit/bulk_edit_rules_occ.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/common/constants.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/index.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/lib/change_tracking/constants.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/lib/change_tracking/index.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/lib/change_tracking/service.test.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/lib/change_tracking/service.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/lib/change_tracking/types.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/lib/index.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/lib/schedule_task.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/methods/get_rule_history.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/rules_client.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/tests/get_history.test.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/types.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client_factory.test.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client_factory.ts`
- `x-pack/platform/plugins/shared/alerting/server/test_utils/index.ts`
- `x-pack/platform/plugins/shared/alerting/server/types.ts`
- `x-pack/platform/plugins/shared/alerting/tsconfig.json`

### Alerting FTR (7)

- `x-pack/platform/test/alerting_api_integration/common/config.ts`
- `x-pack/platform/test/alerting_api_integration/common/plugins/alerts/moon.yml`
- `x-pack/platform/test/alerting_api_integration/common/plugins/alerts/server/plugin.ts`
- `x-pack/platform/test/alerting_api_integration/common/plugins/alerts/tsconfig.json`
- `x-pack/platform/test/alerting_api_integration/spaces_only/tests/alerting/group6/change_tracking/enabled.ts`
- `x-pack/platform/test/alerting_api_integration/spaces_only/tests/alerting/group6/config_with_change_tracking_enabled.ts`
- `x-pack/platform/test/alerting_api_integration/spaces_only/tests/alerting/group6/index.ts`

### Security Solution (149)

- `x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/rule_management/index.ts`
- `x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/rule_management/restore_rule_from_history/restore_rule_from_history_route.gen.ts`
- `x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/rule_management/restore_rule_from_history/restore_rule_from_history_route.schema.yaml`
- `x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/rule_management/rule_history/rule_history_route.gen.ts`
- `x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/rule_management/rule_history/rule_history_route.schema.yaml`
- `x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/rule_management/urls.ts`
- `x-pack/solutions/security/plugins/security_solution/common/api/quickstart_client.gen.ts`
- `x-pack/solutions/security/plugins/security_solution/common/constants.ts`
- `x-pack/solutions/security/plugins/security_solution/common/detection_engine/rule_management/rule_change_tracking.ts`
- `x-pack/solutions/security/plugins/security_solution/common/experimental_features.ts`
- `x-pack/solutions/security/plugins/security_solution/moon.yml`
- `x-pack/solutions/security/plugins/security_solution/public/app/home/global_header/index.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/common/components/header_page/__snapshots__/index.test.tsx.snap`
- `x-pack/solutions/security/plugins/security_solution/public/common/components/header_page/index.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/common/components/link_to/redirect_to_detection_engine.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/common/lib/telemetry/events/rule_changes_history/index.ts`
- `x-pack/solutions/security/plugins/security_solution/public/common/lib/telemetry/events/rule_changes_history/types.ts`
- `x-pack/solutions/security/plugins/security_solution/public/common/lib/telemetry/events/telemetry_events.ts`
- `x-pack/solutions/security/plugins/security_solution/public/common/lib/telemetry/types.ts`
- `x-pack/solutions/security/plugins/security_solution/public/common/utils/route/spy_routes.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/common/utils/timeline/use_show_timeline_for_path.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/common/breadcrumbs.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/common/translations.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_diff/changes_diff.test.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_diff/changes_diff.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_diff/translations.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_diff/utils.test.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_diff/utils.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_history/changes_history.test.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_history/changes_history.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_history/images/no_change_history.png`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_history/index.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_history/rule_restore_conflict_modal.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_history/translations.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_history/use_change_history_auto_selection.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_history/use_rule_restore_conflict.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_history/use_rule_restore_from_history.test.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_history/use_rule_restore_from_history.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_history_timeline/change_history_footer.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_history_timeline/change_history_item.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_history_timeline/change_history_item_popover.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_history_timeline/change_history_timeline.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_history_timeline/constants.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_history_timeline/index.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_history_timeline/rule_change_action_badge.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/components/changes_history_timeline/translations.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/pages/rule_changes_history/index.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/pages/rule_changes_history/rule_change_history_page.test.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/pages/rule_changes_history/rule_change_history_page.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/pages/rule_changes_history/rule_change_history_page_header.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/pages/rule_details/index.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/pages/rule_details/rule_actions_overflow/index.test.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/pages/rule_details/rule_actions_overflow/index.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/utils/extract_changed_field_names.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_management/api/api.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_management/api/hooks/prebuilt_rules/use_perform_rules_upgrade_mutation.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_management/api/hooks/prebuilt_rules/use_revert_prebuilt_rule_mutation.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_management/api/hooks/translations.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_management/api/hooks/use_bulk_action_mutation.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_management/api/hooks/use_infinite_change_history.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_management/api/hooks/use_restore_rule_revision_mutation.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_management/api/hooks/use_update_rule_mutation.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_management/components/rule_details/json_diff/diff_view.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_management/logic/types.ts`
- `x-pack/solutions/security/plugins/security_solution/public/detections/components/rules/rule_info/index.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detections/components/rules/rule_info/rule_revision.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detections/components/rules/rule_info/rule_version.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/detections/components/rules/rule_info/translations.ts`
- `x-pack/solutions/security/plugins/security_solution/public/helpers.tsx`
- `x-pack/solutions/security/plugins/security_solution/public/rules/routes.tsx`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/api/install_prebuilt_rules_and_timelines/legacy_create_prepackaged_rules.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/api/perform_rule_installation/perform_rule_installation_handler.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/api/perform_rule_upgrade/perform_rule_upgrade_handler.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/integrations/install_endpoint_security_prebuilt_rule.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/integrations/install_promotion_rules.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/rule_objects/create_prebuilt_rules.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/rule_objects/revert_prebuilt_rules.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/rule_objects/upgrade_prebuilt_rules.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/routes/__mocks__/test_adapters.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/register_routes.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/bulk_actions/route.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/bulk_actions/route.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/import_rules/route.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/restore_rule_from_history/route.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/restore_rule_from_history/route.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/rule_history/route.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/rule_history/route.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/__mocks__/detection_rules_client.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.bulk_create_prebuilt_rules.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.change_tracking.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.create_custom_rule.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.create_prebuilt_rule.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.delete_rule.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.import_rule.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.import_rules.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.patch_rule.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.restore_rule_from_history.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.revert_prebuilt_rule.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.update_rule.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.upgrade_prebuilt_rule.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client_interface.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/bulk_delete_rules.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/create_rule.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/get_history_for_rule.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/get_history_for_rule.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/get_rule_by_id.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/import_rule.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/import_rules.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/patch_rule.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/rbac_methods/update_rule_with_read_privileges.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/restore_rule_from_history/check_concurrency.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/restore_rule_from_history/fetch_rule_with_history.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/restore_rule_from_history/index.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/restore_rule_from_history/restore_deleted_rule.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/restore_rule_from_history/restore_rule_from_history.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/restore_rule_from_history/restore_rule_from_history.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/restore_rule_from_history/restore_rule_state.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/restore_rule_from_history/types.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/revert_prebuilt_rule.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/update_rule.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/upgrade_prebuilt_rule.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/utils/compute_old_values.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/utils/compute_old_values.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/utils/map_rule_history_item.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/utils/map_rule_history_item.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/restore_telemetry.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/restore_telemetry.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/rule_lifecycle_telemetry.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/rule_lifecycle_telemetry.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/utils.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/import/import_rules.ts`
- `x-pack/solutions/security/plugins/security_solution/server/lib/telemetry/event_based/events.ts`
- `x-pack/solutions/security/plugins/security_solution/server/request_context_factory.ts`
- `x-pack/solutions/security/plugins/security_solution/server/ui_settings.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/ui_settings.ts`
- `x-pack/solutions/security/plugins/security_solution/server/usage/detections/get_initial_usage.ts`
- `x-pack/solutions/security/plugins/security_solution/server/usage/detections/get_metrics.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/usage/detections/get_metrics.ts`
- `x-pack/solutions/security/plugins/security_solution/server/usage/detections/rules/get_initial_usage.ts`
- `x-pack/solutions/security/plugins/security_solution/server/usage/detections/rules/get_metrics.mocks.ts`
- `x-pack/solutions/security/plugins/security_solution/server/usage/detections/rules/get_metrics.ts`
- `x-pack/solutions/security/plugins/security_solution/server/usage/detections/rules/schema.ts`
- `x-pack/solutions/security/plugins/security_solution/server/usage/detections/rules/schemas/changes_history_usage.ts`
- `x-pack/solutions/security/plugins/security_solution/server/usage/detections/rules/types.ts`
- `x-pack/solutions/security/plugins/security_solution/server/usage/queries/get_changes_history_usage.test.ts`
- `x-pack/solutions/security/plugins/security_solution/server/usage/queries/get_changes_history_usage.ts`
- `x-pack/solutions/security/plugins/security_solution/tsconfig.json`
- `x-pack/solutions/security/plugins/security_solution_serverless/server/plugin.ts`

### Security Solution tests (13)

- `x-pack/solutions/security/packages/test-api-clients/supertest/detections.gen.ts`
- `x-pack/solutions/security/test/security_solution_api_integration/config/ess/config.base.ts`
- `x-pack/solutions/security/test/security_solution_api_integration/config/serverless/config.base.ts`
- `x-pack/solutions/security/test/security_solution_api_integration/moon.yml`
- `x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/rule_management/trial_license_complete_tier/change_tracking.ts`
- `x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/rule_management/trial_license_complete_tier/change_tracking_disabled.ts`
- `x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/rule_management/trial_license_complete_tier/configs/ess.rule_changes_history_disabled.config.ts`
- `x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/rule_management/trial_license_complete_tier/index.ts`
- `x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/rule_management/trial_license_complete_tier/restore_rule_from_changes_history.ts`
- `x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/utils/rules/change_history.ts`
- `x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/utils/rules/index.ts`
- `x-pack/solutions/security/test/security_solution_api_integration/tsconfig.json`
- `x-pack/solutions/security/test/serverless/api_integration/test_suites/platform_security/authorization.ts`

### Other (tooling, shared types, incidental hits from listed PRs) (33)

- `.buildkite/ftr-manifests/ftr_platform_stateful_configs.yml`
- `.buildkite/ftr-manifests/ftr_security_stateful_configs.yml`
- `.github/CODEOWNERS`
- `oas_docs/output/kibana.serverless.yaml`
- `oas_docs/output/kibana.yaml`
- `package.json`
- `src/core/packages/data-streams/server/README.md`
- `src/platform/packages/shared/deeplinks/security/deep_links.ts`
- `src/platform/packages/shared/kbn-alerting-types/moon.yml`
- `src/platform/packages/shared/kbn-alerting-types/rule_types.ts`
- `src/platform/packages/shared/kbn-alerting-types/tsconfig.json`
- `src/platform/packages/shared/kbn-es-mappings/src/type.test.ts`
- `src/platform/packages/shared/kbn-es-mappings/src/types.ts`
- `src/platform/packages/shared/kbn-openapi-common/shared/path_params_replacer.test.ts`
- `src/platform/packages/shared/kbn-openapi-common/shared/path_params_replacer.ts`
- `src/platform/plugins/private/kibana_usage_collection/server/collectors/management/schema.ts`
- `src/platform/plugins/private/kibana_usage_collection/server/collectors/management/types.ts`
- `src/platform/plugins/shared/telemetry/schema/oss_platform.json`
- `src/platform/plugins/shared/workflows_management/server/lib/get_workflow_change_history.test.ts`
- `src/platform/plugins/shared/workflows_management/server/lib/map_workflow_history_item.test.ts`
- `src/platform/plugins/shared/workflows_management/server/services/workflow_change_history_service.test.ts`
- `tsconfig.base.json`
- `x-pack/platform/packages/private/security/authorization_core/src/privileges/feature_privilege_builder/alerting.test.ts`
- `x-pack/platform/packages/private/security/authorization_core/src/privileges/feature_privilege_builder/alerting.ts`
- `x-pack/platform/packages/private/security/authorization_core/src/privileges/privileges.test.ts`
- `x-pack/platform/plugins/private/telemetry_collection_xpack/schema/xpack_security.json`
- `x-pack/platform/plugins/shared/alerting_v2/server/lib/rule_changes_history/types.ts`
- `x-pack/platform/plugins/shared/task_manager/server/task_scheduling.test.ts`
- `x-pack/platform/plugins/shared/task_manager/server/task_scheduling.ts`
- `x-pack/platform/test/moon.yml`
- `x-pack/platform/test/tsconfig.json`
- `x-pack/solutions/observability/test/serverless/api_integration/test_suites/platform_security/authorization.ts`
- `yarn.lock`
