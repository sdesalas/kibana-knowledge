# Code architecture: Detection Rules

Scan date: 2026-06-11
Kibana repo path: /Users/sdesalas/Code/sdesalas/kibana-7th
Paths scanned:

- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/**`
- `x-pack/solutions/security/plugins/security_solution/public/detection_engine/**`
- `x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/**`
- `x-pack/solutions/security/plugins/security_solution/common/detection_engine/**`
- `src/platform/packages/shared/kbn-securitysolution-rules/src/**`
- `x-pack/solutions/security/plugins/lists/**`

---

## File map

Files by kind. List the top 20 per group; add a total count in the heading.

### Components (582 total)

Public `.tsx` components (non-test, non-stories); top 20 alphabetical by basename:

- `alert_suppression_edit.tsx`
- `anomaly_threshold_edit.tsx`
- `create_ml_job_button.tsx`
- `endpoint_exceptions_viewer.tsx`
- `endpoint_response_action.tsx`
- `eql_overview_link.tsx`
- `eql_query_bar.tsx`
- `field_name.tsx`
- `helpers.tsx`
- `index.tsx` (multiple; see Index / entry points section)
- `integration_link.tsx`
- `integration_status_badge.tsx`
- `integration_version_mismatch_icon.tsx`
- `missing_fields_strategy_selector.tsx`
- `osquery_investigation_guide_panel.tsx`
- `osquery_response_action.tsx`
- `osquery_response_action_form_field.tsx`
- `response_action_add_button.tsx`
- `response_actions_form.tsx`
- `response_actions_list.tsx`

(+562 more)

### Hooks (145 total)

Public hook files (`use_*.ts(x)`, `use*.ts(x)`); top 20 alphabetical by basename:

- `use_accordion_styling.ts`
- `use_all_esql_rule_fields.ts`
- `use_async_confirmation.ts`
- `use_bootstrap_ease_rules.ts`
- `use_bulk_actions_confirmation.ts`
- `use_bulk_actions_dry_run.ts`
- `use_bulk_duplicate_confirmation.ts`
- `use_bulk_edit_form_flyout.ts`
- `use_columns.tsx`
- `use_coverage_colors.tsx`
- `use_data_view_list_items.ts`
- `use_esql_fields_options.ts`
- `use_execution_settings.ts`
- `use_expandable_rows.tsx`
- `use_fetch_prebuilt_rules_status_query.ts`
- `use_get_endpoint_exceptions_unavailablle_component.tsx`
- `use_get_rule_health.ts`
- `use_get_saved_query.ts`
- `use_has_actions_privileges.ts`
- `use_has_ml_permissions.ts`

(+125 more)

### Services (1 total)

- `migration_service.ts` — server-side signals index migration orchestration (`server/lib/detection_engine/migrations/migration_service.ts`)

### Routes (78 total)

Server-side HTTP route files under `routes/`; top 20 alphabetical by basename:

- `attacks_route_not_implemented.ts`
- `check_template_version.ts`
- `create_index_route.ts`
- `create_signals_migration_route.ts`
- `delete_index_route.ts`
- `delete_signals_migration_route.ts`
- `finalize_signals_migration_route.ts`
- `get_index_version.ts`
- `get_signals_migration_status_route.ts`
- `get_signals_template.ts`
- `open_close_signals_route.ts`
- `query_signals_route.ts`
- `read_alerts_index_exists_route.ts`
- `read_index_route.ts`
- `read_privileges_route.ts`
- `register_attacks_routes.ts`
- `search_attacks_route.ts`
- `search_route.ts`
- `set_alert_assignees_route.ts` (signals)
- `set_alert_tags_route.ts` (signals)

(+58 more, covering unified_alerts, telemetry, users, and rule_management/prebuilt_rules sub-routes)

### Types / constants (59 total)

Files named `types.ts`, `constants.ts`, or residing under `types/` or `common/`; top 20:

- `configuration_constants.ts` (`kbn-securitysolution-rules/src/`)
- `constants.ts` (`common/detection_engine/`)
- `constants.ts` (`common/detection_engine/rule_management/`)
- `mitre_tactics_techniques.ts`
- `prebuilt_rule_customization_status.ts`
- `rule_alert_type.ts`
- `rule_change_tracking.ts`
- `rule_fields.ts`
- `rule_filtering.ts`
- `rule_schemas.ts` (server rule_schema)
- `rule_type_constants.ts` (`kbn-securitysolution-rules/src/`)
- `rule_type_mappings.ts` (`kbn-securitysolution-rules/src/`)
- `transform_actions.ts`
- `types.ts` (`common/detection_engine/`)
- `types.ts` (MITRE)
- `utils.ts` (`kbn-securitysolution-rules/src/`)

(+43 more)

### Tests (613 total)

`*.test.ts(x)` and `*.spec.ts(x)` across all paths:

- Server detection engine: 273 test files
- Public detection engine: 218 test files
- Common API / common detection engine / lists / kbn-securitysolution-rules: 122 test files

Top 20 representative basenames:

- `api.test.ts` (public rule_management)
- `calculate_rule_diff.test.ts`
- `detection_rules_client.create_custom_rule.test.ts`
- `detection_rules_client.import_rule.test.ts`
- `detection_rules_client.patch_rule.test.ts`
- `detection_rules_client.upgrade_prebuilt_rule.test.ts`
- `extract_rule_data_query.test.ts`
- `extract_rule_schedule.test.ts`
- `normalize_filter_array.test.ts`
- `normalize_query_field.test.ts`
- `normalize_rule_threshold.test.ts`
- `normalize_threat_array.test.ts`
- `perform_rule_installation_handler.test.ts`
- `read_rules.test.ts`
- `route.test.ts` (create_rule)
- `rule_filtering.test.ts`
- `transform_actions.test.ts`
- `utils.test.ts`

(+595 more)

### Index / entry points

- `server/lib/detection_engine/rule_types/index.ts`
- `server/lib/detection_engine/rule_management/index.ts`
- `server/lib/detection_engine/rule_monitoring/index.ts`
- `server/lib/detection_engine/prebuilt_rules/index.ts`
- `server/lib/detection_engine/fleet_integrations/index.ts`
- `server/lib/detection_engine/rule_preview/index.ts`
- `server/lib/detection_engine/rule_schema/index.ts`
- `server/lib/detection_engine/rule_exceptions/index.ts`
- `server/lib/detection_engine/rule_actions_legacy/index.ts`
- `server/lib/detection_engine/rule_monitoring/logic/detection_engine_health/index.ts`
- `server/lib/detection_engine/rule_monitoring/logic/rule_execution_log/index.ts`
- `server/lib/detection_engine/rule_types/utils/index.ts`
- `server/lib/detection_engine/rule_types/factories/index.ts`
- `server/lib/detection_engine/prebuilt_rules/logic/rule_assets/prebuilt_rule_assets_client/index.ts`
- `common/api/detection_engine/index.ts`
- `common/api/detection_engine/prebuilt_rules/index.ts`
- `common/api/detection_engine/rule_management/index.ts`
- `common/api/detection_engine/rule_monitoring/index.ts`
- `common/api/detection_engine/model/index.ts`
- `common/api/detection_engine/model/rule_schema/index.ts`
- `common/api/detection_engine/signals/index.ts`
- `common/api/detection_engine/unified_alerts/index.ts`
- `public/detection_engine/fleet_integrations/index.ts`
- `public/detection_engine/fleet_integrations/api/index.ts`
- `public/detection_engine/rule_creation/components/alert_suppression_edit/index.ts`
- `public/detection_engine/rule_creation/components/eql_query_edit/index.ts`
- `public/detection_engine/rule_creation/components/esql_query_edit/index.ts`
- `lists/common/index.ts`

### Other (320 total)

Files not fitting the above categories; top 20:

- `8_18_alerts_compatibility_mappings.ts` (migration compatibility mapping)
- `aggregate_prebuilt_rule_errors.ts`
- `build_agent_graph.ts` (AI rule creation LangGraph agent)
- `calculate_rule_diff.ts`
- `calculate_three_way_rule_fields_diff.ts`
- `convert_rule_to_diffable.ts`
- `create_migration.ts`
- `create_prebuilt_rules.ts`
- `detection_rules_client.ts`
- `ensure_latest_rules_package_installed.ts`
- `extract_integrations.ts`
- `generate_esql_query.ts` (AI rule creation node)
- `get_fleet_packages.ts`
- `helpers.ts`
- `installed_integration_set.ts`
- `migration_cleanup.ts`
- `query.ts` (query rule executor)
- `queryExecutor` internals
- `rule_management_filters_query.ts`
- `sort_integrations_by_status.ts`

(+300 more)

---

## Entry points

Public exports from the `index.ts` / `index.tsx` files in the scanned paths:

### `server/lib/detection_engine/rule_types/index.ts`

| Export | Kind |
|--------|------|
| `createEqlAlertType` | function |
| `createEsqlAlertType` | function |
| `createIndicatorMatchAlertType` | function |
| `createMlAlertType` | function |
| `createQueryAlertType` | function |
| `createThresholdAlertType` | function |
| `createNewTermsAlertType` | function |

### `server/lib/detection_engine/rule_management/index.ts`

| Export | Kind |
|--------|------|
| `registerRoutes` (via `api/register_routes`) | function |
| `commonParamsCamelToSnake` | function |
| `typeSpecificCamelToSnake` | function |
| `transformFromAlertThrottle` | function |
| `transformToNotifyWhen` | function |

### `server/lib/detection_engine/prebuilt_rules/index.ts`

| Export | Kind |
|--------|------|
| `registerPrebuiltRulesRoutes` | function |
| `prebuiltRuleAssetType` | constant |
| `PrebuiltRuleAsset` | type |

### `server/lib/detection_engine/rule_monitoring/index.ts`

| Export | Kind |
|--------|------|
| `RULE_EXECUTION_LOG_PROVIDER` | constant |
| Detection engine health utilities (via `logic/detection_engine_health`) | re-exports |
| Rule execution log client factories (via `logic/rule_execution_log`) | re-exports |
| `RuleExecutionLogClientForRoutes` / `RuleExecutionLogClientForExecutors` | types |
| `truncateList` | function |
| Service interface (via `logic/service_interface`) | type re-exports |
| Service factory (via `logic/service`) | function re-exports |

### `server/lib/detection_engine/rule_monitoring/logic/rule_execution_log/index.ts`

| Export | Kind |
|--------|------|
| `IRuleExecutionLogForExecutors` | type |
| `IRuleExecutionLogForRoutes` | type |
| `createRuleExecutionSummary` | function |

### `common/api/detection_engine/index.ts`

Barrel re-exports for all sub-namespaces:

| Export group | Kind |
|---|---|
| `alert_assignees` | type + schema re-exports |
| `alert_tags` | type + schema re-exports |
| `attacks` | type + schema re-exports |
| `fleet_integrations` | type + schema re-exports |
| `index_management` | type + schema re-exports |
| `model` (includes `rule_schema`, `alerts`, `rule_response_actions`) | type + schema re-exports |
| `prebuilt_rules` | type + schema re-exports |
| `rule_exceptions` | type + schema re-exports |
| `rule_management` | type + schema re-exports |
| `rule_monitoring` | type + schema re-exports |
| `rule_preview` | type + schema re-exports |
| `signals` | type + schema re-exports |
| `signals_migration` | type + schema re-exports |
| `unified_alerts` | type + schema re-exports |

### `public/detection_engine/fleet_integrations/api/index.ts`

| Export | Kind |
|--------|------|
| `IFleetIntegrationsApiClient` | type |
| `fleetIntegrationsApi` | constant (API client singleton) |

---

## Data flow sketch

Traced through 8 key files (routes, handlers, client interface, alert type factory, prebuilt rules handler, public API client, public mutation hook, and diff engine).

**Data entry:**
- **Server-side CRUD**: HTTP requests arrive at versioned Kibana routes (e.g. `POST /api/detection_engine/rules` version `2023-10-31`). Request bodies are validated with Zod schemas generated from OpenAPI YAML files in `common/api/detection_engine/**/*.schema.yaml`.
- **Server-side rule execution**: The Kibana Alerting framework calls the registered `executor` function on each `SecurityAlertType` on schedule. Execution context arrives as `execOptions` containing `sharedParams`, `services`, and `state`.
- **Public client**: Browser components call functions in `public/detection_engine/rule_management/api/api.ts` via `KibanaServices.get().http.fetch`, which issues `fetch` calls to the versioned Kibana HTTP API.
- **Prebuilt rule assets**: Rule asset package content arrives via Fleet/EPM saved objects. The `PrebuiltRuleAssetsClient` reads from saved objects on demand.

**Layer flow:**

_Rule CRUD (server)_:
Route handler (`create_rule/route.ts`) → validates request body with Zod (`CreateRuleRequestBody`) → resolves `securitySolution` context → calls `IDetectionRulesClient.createCustomRule()` → `detection_rules_client.ts` delegates to method implementations under `methods/` → writes rule via `rulesClient` (Alerting plugin) → returns `RuleResponse`.

_Rule execution (server)_:
Alerting framework scheduler → `createQueryAlertType.executor()` → `queryExecutor()` in `rule_types/query/query.ts` → queries Elasticsearch via `services.scopedClusterClient` → creates alerts via `services.alertsClient` → writes alert documents to the signals/alerts index → optionally logs to `RuleExecutionLog`.

_Prebuilt rule installation (server)_:
`POST /internal/detection_engine/prebuilt_rules/installation/_perform` → `performRuleInstallationRoute` → `performRuleInstallationHandler` → `ensureLatestRulesPackageInstalled()` (Fleet EPM) → `PrebuiltRuleAssetsClient.fetchLatestVersions()` (saved objects) → `createPrebuiltRules()` → `IDetectionRulesClient.createPrebuiltRule()` → `rulesClient` (Alerting) → response with installed/skipped rule counts.

_Prebuilt rule diff/upgrade (server)_:
`review_rule_upgrade` route → fetches current (`RuleResponse`), base (`PrebuiltRuleAsset`), target (`PrebuiltRuleAsset`) versions → `calculateRuleDiff()` in `prebuilt_rules/logic/diff/calculate_rule_diff.ts` → `convertRuleToDiffable()` normalizes all three versions to `DiffableRule` → `calculateThreeWayRuleFieldsDiff()` runs per-field diff algorithms → returns `FullThreeWayRuleDiff` with conflict markers.

_Public API → hook → UI_:
`api.ts` functions (e.g. `createRule`) → consumed by React Query hooks (e.g. `useCreateRuleMutation` in `rule_management/api/hooks/use_create_rule_mutation.ts`) using `useMutation` from `@kbn/react-query` → on settled, invalidates cached queries (`useInvalidateFindRulesQuery`, `useInvalidateFetchRuleManagementFiltersQuery`, `useInvalidateFetchCoverageOverviewQuery`) → UI components reactively re-render.

**Data exit / output:**
- Alert documents written to `.alerts-security.alerts-<space>` index (via `services.alertsClient` inside rule executors).
- Saved object writes for rule definitions (via `rulesClient` — Alerting framework saved objects).
- Rule execution log events written to the Kibana Event Log (`.kibana-event-log-*`).
- HTTP response bodies serialized from `RuleResponse` (via converters in `detection_rules_client/converters/`).
- Public UI renders rule lists, rule details pages, upgrade review tables, and coverage overview maps.

File references (file:line) for each observation:

- Route registers at `DETECTION_ENGINE_RULES_URL` — `server/lib/detection_engine/rule_management/api/rules/create_rule/route.ts:29`
- Zod body validation — `server/lib/detection_engine/rule_management/api/rules/create_rule/route.ts:47`
- `detectionRulesClient.createCustomRule()` called — `server/lib/detection_engine/rule_management/api/rules/create_rule/route.ts:99`
- `IDetectionRulesClient` interface contract — `server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client_interface.ts:26`
- `queryExecutor` invoked inside alert type executor — `server/lib/detection_engine/rule_types/query/create_query_alert_type.ts:70`
- `SecurityAlertType` executor receives `sharedParams`, `services`, `state` — `server/lib/detection_engine/rule_types/query/create_query_alert_type.ts:69`
- Prebuilt assets fetched from saved objects — `server/lib/detection_engine/prebuilt_rules/api/perform_rule_installation/perform_rule_installation_handler.ts:43`
- `ensureLatestRulesPackageInstalled` called — `server/lib/detection_engine/prebuilt_rules/api/perform_rule_installation/perform_rule_installation_handler.ts:55`
- `calculateRuleDiff` normalizes versions to `DiffableRule` — `server/lib/detection_engine/prebuilt_rules/logic/diff/calculate_rule_diff.ts:51`
- Public `createRule` uses `KibanaServices.get().http.fetch` — `public/detection_engine/rule_management/api/api.ts:110`
- `useCreateRuleMutation` invalidates query cache on settled — `public/detection_engine/rule_management/api/hooks/use_create_rule_mutation.ts:35`
- Fleet integrations fetched via `KibanaServices.get().http` — `public/detection_engine/fleet_integrations/api/api_client.ts:25`

---

## External dependencies

Non-relative imports found in the key files read above:

- **Shared Kibana packages:**
  - `@kbn/core/server` — `IKibanaResponse`, `Logger`, `KibanaRequest`, `KibanaResponseFactory`, `SavedObjectsClient`
  - `@kbn/core-application-common` — `DEFAULT_APP_CATEGORIES`
  - `@kbn/alerting-plugin/common` — `SanitizedRuleConfig`, `INTERNAL_ALERTING_API_FIND_RULES_PATH`, `GapFillStatus`
  - `@kbn/alerting-plugin/server` — `BulkOperationError`, `CreateRuleData`, `UpdateRuleData`
  - `@kbn/actions-plugin/common` — `ActionType`, `AsApiContract`, `BASE_ACTION_API_PATH`
  - `@kbn/actions-plugin/server` — `ActionResult`
  - `@kbn/react-query` — `useMutation`, `useQuery`, `UseMutationOptions`
  - `@kbn/security-solution-features/constants` — `RULES_API_ALL`
  - `@kbn/securitysolution-es-utils` — `transformError`
  - `@kbn/securitysolution-io-ts-list-types` — `CreateRuleExceptionListItemSchema`, `ExceptionListItemSchema`
  - `@kbn/securitysolution-rules` — `EQL_RULE_TYPE_ID`, `ESQL_RULE_TYPE_ID`, `QUERY_RULE_TYPE_ID`, and other rule type ID constants
  - `@kbn/zod` / `@kbn/zod/v4` — Zod schema validation
  - `@kbn/zod-helpers/v4` — `buildRouteValidationWithZod`

- **External npm packages:**
  - `lodash` — `pick`, general utilities
  - `rxjs` — used in rule monitoring event streams (referenced indirectly)

- **ES indices / data views:**
  - `.alerts-security.alerts-<space>` — alerts/signals write target (runtime-computed, not hardcoded; pattern surfaced via `AlertsIndex` schema type in `rule_schemas.ts`)
  - `.siem-signals-*` — legacy signals index alias pattern used in migration routes
  - `.kibana-event-log-*` — Kibana event log (via `RULE_EXECUTION_LOG_PROVIDER`)
  - `security_solution-*` — prebuilt rule asset saved object type storage

- **Kibana platform services:**
  - `ctx.alerting.getRulesClient()` — Alerting plugin rules CRUD client
  - `ctx.core.savedObjects.client` — Saved objects access for prebuilt rule assets
  - `ctx.securitySolution.getDetectionRulesClient()` — domain-level rule client factory
  - `ctx.securitySolution.getExceptionListClient()` — exception list integration
  - `ctx.securitySolution.getMlAuthz()` — ML authorization
  - `ctx.securitySolution.getEndpointAuthz()` — Endpoint authorization
  - `ctx.securitySolution.getEndpointService()` — Endpoint response actions validation
  - `KibanaServices.get().http` — browser HTTP client (public side)

---

## Test coverage shape

- Source files (non-test, non-story): ~1,791 (server: 545, public: 989, common+lists+kbn-rules: ~257 estimated non-index)
- Test files: ~613 (server: 273, public: 218, common+lists: 122)
- Coverage ratio: ~25% of total files are test files

Layers with test coverage:
- Server routes (`routes/` subdirectories): 20 test files
- Server rule management logic (`rule_management/`): 67 test files
- Server rule types (executor implementations): 112 test files
- Server prebuilt rules logic (`prebuilt_rules/`): 28 test files
- Public rule management API hooks: 25 test files
- Public rule creation components: 26 test files
- Public rule management UI: 62 test files
- Common API detection engine: part of 122 across common+lists
- Common detection engine (diff normalizers, rule filtering): tested inline (e.g. `normalize_query_field.test.ts`, `rule_filtering.test.ts`)
- Lists plugin: 86 test files

Layers with little or no test coverage:
- Public rule monitoring components: 1 test file found
- `kbn-securitysolution-rules/src/`: no test files found (4 source files, utility/constants only)
- AI rule creation agent nodes (`ai_rule_creation/agent/nodes/`, `sub_graphs/`): no test files found in those directories
- Server fleet integrations logic: minimal (no dedicated test files found under `fleet_integrations/logic/`)
