# Elasticsearch calls made by `install_large_bundled_package.ts`

**Test under analysis:**
`x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/prebuilt_rules_package/air_gapped/install_large_bundled_package.ts`

This report lists every Elasticsearch operation that one full execution of this test produces, broken down into:

1. **Direct ES calls** — issued by the test helpers themselves through the FTR `es` service (`@elastic/elasticsearch` client).
2. **Indirect ES calls** — issued by Kibana plugin code when the test hits a Kibana HTTP endpoint. These are routed through the `SavedObjectsClient` (`.kibana*` indices), `RulesClient` (`.kibana_alerting_cases`), or Fleet/EPM services.

Each call has a citation pointing at where the call site lives in the Kibana codebase.

---

## Test outline

```24:60:x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/prebuilt_rules_package/air_gapped/install_large_bundled_package.ts
  describe('@ess @serverless @skipInServerlessMKI Install large bundled package', () => {
    beforeEach(async () => {
      await deleteAllRules(supertest, log);
      await deleteAllPrebuiltRuleAssets(es, log);
      await deletePrebuiltRulesFleetPackage({ supertest, retryService, log, es });
    });

    it('should install a package containing 15000 prebuilt rules without crashing', async () => {
      const statusBeforePackageInstallation = await getPrebuiltRulesAndTimelinesStatus(es, supertest);
      ...
      await installPrebuiltRulesAndTimelines(es, supertest);
      ...
      const statusAfterPackageInstallation = await getPrebuiltRulesAndTimelinesStatus(es, supertest);
      ...
    });
  });
```

Execution order per iteration:

1. `beforeEach` → `deleteAllRules` (HTTP)
2. `beforeEach` → `deleteAllPrebuiltRuleAssets` (direct ES)
3. `beforeEach` → `deletePrebuiltRulesFleetPackage` (HTTP + direct ES)
4. `it` → `getPrebuiltRulesAndTimelinesStatus` (direct ES + HTTP)
5. `it` → `installPrebuiltRulesAndTimelines` (HTTP + direct ES)
6. `it` → `getPrebuiltRulesAndTimelinesStatus` (direct ES + HTTP)

---

## 1. Direct ES calls (test helpers using the `es` service)

These calls are emitted directly by the test code and never go through a Kibana HTTP endpoint.

### 1.1 `es.deleteByQuery` — wipe prebuilt rule assets

Called once per `beforeEach` from `deleteAllPrebuiltRuleAssets`.

```16:29:x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/utils/rules/prebuilt_rules/delete_all_prebuilt_rule_assets.ts
export const deleteAllPrebuiltRuleAssets = async (
  es: Client,
  logger: ToolingLog
): Promise<void> => {
  await retryIfDeleteByQueryConflicts(logger, deleteAllPrebuiltRuleAssets.name, async () => {
    return await es.deleteByQuery({
      index: SECURITY_SOLUTION_SAVED_OBJECT_INDEX,
      q: 'type:security-rule',
      wait_for_completion: true,
      refresh: true,
      body: {},
    });
  });
};
```

| Field | Value |
|---|---|
| ES API | `POST /<index>/_delete_by_query` |
| Index | `SECURITY_SOLUTION_SAVED_OBJECT_INDEX` (typically `.kibana_security_solution`) |
| Query | `q=type:security-rule` |
| Refresh | `true` |
| Conflict handling | Wrapped in `retryIfDeleteByQueryConflicts` for version-conflict retries |

### 1.2 `es.indices.refresh` + `es.indices.clearCache` — refresh SO indices

Called by `refreshSavedObjectIndices`, which is invoked from `getPrebuiltRulesAndTimelinesStatus` (twice), `installPrebuiltRulesAndTimelines` (once), and `deletePrebuiltRulesFleetPackage` (once) — so **4 invocations** per test iteration, each producing 2 ES calls (= 8 ES calls total).

```37:45:x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/utils/refresh_index.ts
export const refreshSavedObjectIndices = async (es: Client) => {
  // Refresh indices to prevent a race condition between a write and subsequent read operation. To
  // fix it deterministically we have to refresh saved object indices and wait until it's done.
  await es.indices.refresh({ index: ALL_SAVED_OBJECT_INDICES, ignore_unavailable: true });

  // Additionally, we need to clear the cache to ensure that the next read operation will
  // not return stale data.
  await es.indices.clearCache({ index: ALL_SAVED_OBJECT_INDICES, ignore_unavailable: true });
};
```

| Field | Value |
|---|---|
| ES APIs | `POST /<indices>/_refresh` and `POST /<indices>/_cache/clear` |
| Indices | `ALL_SAVED_OBJECT_INDICES` (all `.kibana*` indices) |
| Options | `ignore_unavailable: true` |

---

## 2. Indirect ES calls (issued by Kibana endpoints invoked by the test)

The test makes 6 HTTP requests against Kibana per iteration. Each Kibana handler then talks to Elasticsearch via the SavedObjectsClient or the Alerting `RulesClient`. The tables below list the actual call sites in the Kibana code that produce ES traffic.

### Endpoint map

| # | Phase | Method | URL | Server handler |
|---|---|---|---|---|
| 1 | `beforeEach` | `POST` | `/api/detection_engine/rules/_bulk_action` | `performBulkActionRoute` |
| 2 | `beforeEach` | `GET` | `/api/detection_engine/rules/_find?page=1&per_page=1` | `findRulesRoute` |
| 3 | `beforeEach` | `DELETE` | `/api/fleet/epm/packages/security_detection_engine` | Fleet EPM remove package |
| 4, 6 | `it` | `GET` | `/api/detection_engine/rules/prepackaged/_status` | `getPrebuiltRulesAndTimelinesStatusRoute` |
| 5 | `it` | `PUT` | `/api/detection_engine/rules/prepackaged` | `installPrebuiltRulesAndTimelinesRoute` → `legacyCreatePrepackagedRules` |

### 2.1 `POST /api/detection_engine/rules/_bulk_action` (action `delete`)

Path: `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/bulk_actions/route.ts`.

Two ES-touching call sites are reached for the `{ action: 'delete', query: '' }` body used by the test:

```235:246:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/bulk_actions/route.ts
          const fetchRulesOutcome = await fetchRulesByQueryOrIds({
            rulesClient,
            query,
            ids: body.ids,
            maxRules:
              body.action === BulkActionTypeEnum.edit
                ? MAX_RULES_TO_BULK_EDIT
                : MAX_RULES_TO_PROCESS_TOTAL,
            ...
          });
```

```290:295:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/bulk_actions/route.ts
              const ruleIds = rules.map((rule) => rule.id);
              const bulkDeleteResult = await detectionRulesClient.bulkDeleteRules({ ruleIds });

              errors.push(...bulkDeleteResult.errors);
              deleted = bulkDeleteResult.rules;
```

Resulting ES traffic:

| ES op (logical) | Index | Source |
|---|---|---|
| `rulesClient.find` (paginated) — resolves the set of rules to delete | `.kibana_alerting_cases` (alerting SOs of type `alert`) | `fetchRulesByQueryOrIds` |
| `rulesClient.bulkDeleteRules` — per-rule `delete` + Task Manager task deletion | `.kibana_alerting_cases`, `.kibana_task_manager` | `detectionRulesClient.bulkDeleteRules` → `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/bulk_delete_rules.ts` |

For the first iteration the index is empty, so the find returns `total: 0` and the delete is a no-op. After the package has been installed in test 5 (3,000 rules), subsequent runs would delete 3,000 alerting SOs — but the test only runs once per `it`.

### 2.2 `GET /api/detection_engine/rules/_find`

Path: `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/find_rules/route.ts`.

```116:122:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/find_rules/route.ts
          const rules = await findRules({
            rulesClient,
            perPage: query.per_page,
            page: query.page,
            sortField: query.sort_field,
            sortOrder: query.sort_order,
```

`findRules` calls `rulesClient.find(...)`:

```41:67:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/search/find_rules.ts
export const findRules = ({
  rulesClient,
  ...
}: FindRuleOptions): Promise<FindResult<RuleParams>> => {
  return rulesClient.find({
    options: {
      fields,
      page,
      perPage,
      filter: enrichFilterWithRuleTypeMapping(enrichFilterWithRuleIds(filter, ruleIds)),
      sortOrder,
      sortField: transformSortField(sortField),
      searchAfter,
      hasReference,
      aggs: aggregations,
    },
  });
};
```

| ES op (logical) | Index |
|---|---|
| `rulesClient.find({ page: 1, perPage: 1 })` → SO `find` for alerting rule SOs | `.kibana_alerting_cases` |

### 2.3 `DELETE /api/fleet/epm/packages/security_detection_engine`

Handled by Fleet EPM. The Fleet handler removes the installed `security_detection_engine` Fleet package, which fans out into several ES operations against both `.kibana` and the integration's own ES assets:

| ES op (logical) | Index / target | Source area |
|---|---|---|
| Find installed package SO (`epm-packages`) | `.kibana` (SO `find` / `get`) | `@kbn/fleet-plugin` services/epm/packages |
| Delete the `epm-packages` SO | `.kibana` (SO `delete`) | Fleet EPM remove logic |
| Delete `epm-packages-assets` SO bulk | `.kibana_ingest`/`.kibana` (SO `bulkDelete`) | Fleet package assets cleanup |
| Delete ingest pipelines / index templates / component templates / ILM policies that the package owns | ES ingest/cluster APIs (`DELETE _ingest/pipeline/...`, `DELETE _index_template/...`, etc.) | Fleet ES asset cleanup |
| Delete `kibana_assets` saved objects (dashboards, lens, security-rule, etc.) registered by the package | `.kibana` | Fleet EPM `removeKibanaAssetsAndAddBackOnFailure` |

For the `security_detection_engine` package, the `kibana_assets` cleanup is the big one: it iterates over all `security-rule` SOs that the package registered and deletes them via the SO client. The exact ES API issued per SO is a routed `delete` against the relevant SO index (e.g. `.kibana_security_solution` for `security-rule`).

Note: the test calls `deleteAllPrebuiltRuleAssets` (section 1.1) *before* this endpoint, so by the time Fleet runs cleanup the `security-rule` SO partition is already empty and the per-asset deletes become no-ops.

### 2.4 `GET /api/detection_engine/rules/prepackaged/_status`

Path: `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/api/get_prebuilt_rules_and_timelines_status/get_prebuilt_rules_and_timelines_status_route.ts`.

```57:88:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/api/get_prebuilt_rules_and_timelines_status/get_prebuilt_rules_and_timelines_status_route.ts
        try {
          const latestPrebuiltRules = await ruleAssetsClient.fetchLatestAssets();

          const customRules = await findRules({
            rulesClient,
            perPage: 1,
            page: 1,
            sortField: 'enabled',
            sortOrder: 'desc',
            filter: 'alert.attributes.params.immutable: false',
            fields: undefined,
          });

          const installedPrebuiltRules = rulesToMap(
            await getExistingPrepackagedRules({ rulesClient, logger })
          );

          const rulesToInstall = await getRulesToInstall(...);
          const rulesToUpdate = await getRulesToUpdate(...);

          const frameworkRequest = await buildFrameworkRequest(context, request);
          const prebuiltTimelineStatus = await checkTimelinesStatus(frameworkRequest);
```

| # | Logical call | Code | Resulting ES op | Index |
|---|---|---|---|---|
| 1 | `ruleAssetsClient.fetchLatestAssets()` | `fetch_latest_assets.ts` (see 2.5 #1) | SO `find` of type `security-rule` with `terms`+`top_hits` aggregation | `.kibana_security_solution` |
| 2 | `findRules({ ... filter: 'alert.attributes.params.immutable: false', perPage: 1 })` | `find_rules.ts` | `rulesClient.find` → SO `find` of type `alert` | `.kibana_alerting_cases` |
| 3 | `getExistingPrepackagedRules({ rulesClient, logger })` | `get_existing_prepackaged_rules.ts` | `rulesClient.find` (filter `KQL_FILTER_IMMUTABLE_RULES`, `perPage: MAX_PREBUILT_RULES_COUNT`) | `.kibana_alerting_cases` |
| 4 | `checkTimelinesStatus` → `getExistingPrepackagedTimelines` | `check_timelines_status.ts` / `saved_object/timelines/index.ts` | SO `find` of type `siem-ui-timeline` (filter `attributes.timelineType: template ... status: immutable`) | `.kibana` |

`getExistingPrepackagedRules` is:

```78:101:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/search/get_existing_prepackaged_rules.ts
export const getExistingPrepackagedRules = async ({
  rulesClient,
  page,
  perPage,
  logger,
}: { ... }): Promise<RuleAlertType[]> => {
  ...
  const existingPrepackagedRules = await getRules({
    rulesClient,
    page,
    perPage,
    filter: KQL_FILTER_IMMUTABLE_RULES,
  });
  ...
};
```

This endpoint is invoked **twice** per iteration (one pre-install, one post-install), so #1–#4 above happen twice. After install, #1 returns 3,000 rule_id buckets and #3 returns 3,000 alerting SOs.

### 2.5 `PUT /api/detection_engine/rules/prepackaged`

Handler: `legacyCreatePrepackagedRules`.

```36:95:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/api/install_prebuilt_rules_and_timelines/legacy_create_prepackaged_rules.ts
export const legacyCreatePrepackagedRules = async (
  context: SecuritySolutionApiRequestHandlerContext,
  rulesClient: RulesClient,
  logger: Logger,
  exceptionsClient?: ExceptionListClient
): Promise<InstallPrebuiltRulesAndTimelinesResponse> => {
  ...
  if (exceptionsListClient != null) {
    await exceptionsListClient.createEndpointList();
  }

  await ensureLatestRulesPackageInstalled(ruleAssetsClient, context, logger);

  const latestPrebuiltRules = await ruleAssetsClient.fetchLatestAssets();
  const installedPrebuiltRules = rulesToMap(
    await getExistingPrepackagedRules({ rulesClient, logger })
  );
  const rulesToInstall = await getRulesToInstall(...);
  const rulesToUpdate = await getRulesToUpdate(...);

  const ruleCreationResult = await createPrebuiltRules(
    detectionRulesClient,
    rulesToInstall,
    logger
  );

  ...
  const { result: timelinesResult } = await performTimelinesInstallation(context);

  await upgradePrebuiltRules(detectionRulesClient, rulesToUpdate, logger);
  ...
};
```

| # | Logical call | Code | Resulting ES op | Index |
|---|---|---|---|---|
| 1 | `exceptionsListClient.createEndpointList()` | `@kbn/lists-plugin` | Idempotent SO `create` for the endpoint exception list | `.kibana` |
| 2 | `ensureLatestRulesPackageInstalled` → `ruleAssetsClient.fetchLatestAssets({ size: 1 })` | `ensure_latest_rules_package_installed.ts:22` | SO `find` of type `security-rule` with aggregation (`size: 1`) | `.kibana_security_solution` |
| 3 | `ruleAssetsClient.fetchLatestAssets()` (full) | `legacy_create_prepackaged_rules.ts:60` | SO `find` of type `security-rule` with aggregation (`size: MAX_PREBUILT_RULES_COUNT`) — returns 3,000 buckets | `.kibana_security_solution` |
| 4 | `getExistingPrepackagedRules({ rulesClient, logger })` | `get_existing_prepackaged_rules.ts` | `rulesClient.find` with `KQL_FILTER_IMMUTABLE_RULES` | `.kibana_alerting_cases` |
| 5 | `createPrebuiltRules` → `detectionRulesClient.createPrebuiltRule` → `createRule` → `rulesClient.create` (×3,000) | `create_prebuilt_rules.ts` and `create_rule.ts:51` | `rulesClient.create` per rule → SO `create` for type `alert` + Task Manager `schedule` (creates a `task` SO) per enabled rule | `.kibana_alerting_cases`, `.kibana_task_manager` |
| 6 | `performTimelinesInstallation` → `installPrepackagedTimelines` → `getExistingPrepackagedTimelines` + per-timeline SO writes | `perform_timelines_installation.ts`, `check_timelines_status.ts`, `saved_object/timelines/index.ts` | SO `find` + SO `create`/`update` for `siem-ui-timeline` template SOs (and `siem-ui-timeline-note` / `siem-ui-timeline-pinned-event` as applicable) | `.kibana` |
| 7 | `upgradePrebuiltRules` → `detectionRulesClient.upgradePrebuiltRule` (per rule) | `upgrade_prebuilt_rules.ts` and `detection_rules_client.ts` | `rulesClient.update` / `delete + create` per rule when an upgrade is required (no-op for a fresh install, since all rules in #5 are net-new) | `.kibana_alerting_cases` |

`fetchLatestAssets` (calls #2 and #3) is the aggregation query:

```29:65:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/rule_assets/prebuilt_rule_assets_client/methods/fetch_latest_assets.ts
export async function fetchLatestAssets(
  savedObjectsClient: SavedObjectsClientContract,
  options: FetchLatestAssetsOptions = {
    size: MAX_PREBUILT_RULES_COUNT,
  }
): Promise<PrebuiltRuleAsset[]> {
  const findResult = await savedObjectsClient.find<...>({
    type: PREBUILT_RULE_ASSETS_SO_TYPE,
    filter: `NOT ${PREBUILT_RULE_ASSETS_SO_TYPE}.attributes.deprecated: true`,
    aggs: {
      rules: {
        terms: {
          field: `${PREBUILT_RULE_ASSETS_SO_TYPE}.attributes.rule_id`,
          size: options.size,
        },
        aggs: {
          latest_version: {
            top_hits: {
              size: 1,
              sort: {
                [`${PREBUILT_RULE_ASSETS_SO_TYPE}.version`]: 'desc',
              },
            },
          },
        },
      },
    },
  });
```

That single SO `find` translates to an ES `POST .kibana_security_solution/_search` with the `terms` + `top_hits` aggregation shown above.

`createRule` (call #5 in the table) is:

```32:58:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/create_rule.ts
export const createRule = async ({
  actionsClient,
  rulesClient,
  mlAuthz,
  rule,
  ...
}: CreateRuleOptions): Promise<RuleResponse> => {
  await validateMlAuth(mlAuthz, rule.type);

  const ruleWithDefaults = applyRuleDefaults(rule);

  const payload = {
    ...convertRuleResponseToAlertingRule(ruleWithDefaults, actionsClient),
    alertTypeId: ruleTypeMappings[rule.type],
    consumer: SERVER_APP_ID,
    enabled: rule.enabled ?? false,
  };

  const createdRule = await rulesClient.create<RuleParams>({
    data: payload,
    options: { id },
    allowMissingConnectorSecrets,
  });
  ...
};
```

Per rule, `rulesClient.create` issues at minimum:

- One ES `index`/`create` against `.kibana_alerting_cases` (the `alert` SO).
- If the rule is `enabled`, one ES `index`/`create` against `.kibana_task_manager` (the scheduled `task` SO).
- An audit log write (where audit logging is enabled).

For this test, prebuilt rules are created with `enabled: false` (default for prebuilt installs), so the Task Manager write per rule is typically skipped. The dominant cost remains writing 3,000 alerting SOs.

Concurrency: `createPrebuiltRules` parallelises through `initPromisePool` with `MAX_RULES_TO_UPDATE_IN_PARALLEL`:

```15:51:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/rule_objects/create_prebuilt_rules.ts
export const createPrebuiltRules = (
  detectionRulesClient: IDetectionRulesClient,
  rules: PrebuiltRuleAsset[],
  logger?: Logger
) => {
  return withSecuritySpan('createPrebuiltRules', async () => {
    ...
    const result = await initPromisePool({
      concurrency: MAX_RULES_TO_UPDATE_IN_PARALLEL,
      items: rules,
      executor: async (rule) => {
        return detectionRulesClient.createPrebuiltRule({
          params: rule,
        });
      },
    });
    ...
  });
};
```

---

## 3. Summary table — ES operations per single iteration

> Counts assume the package contains `NUM_OF_RULE_IN_MOCK_LARGE_PKG = 3000` unique rules with 10 historical versions each (30,000 `security-rule` SOs), as configured by `ess_air_gapped_with_bundled_large_package.config.ts`.

| # | Source (file:line range) | ES op (logical) | ES API | Index | Count per iteration |
|---|---|---|---|---|---|
| 1 | `delete_all_prebuilt_rule_assets.ts:21-28` | Delete by query (type:security-rule) | `POST /_delete_by_query` | `.kibana_security_solution` | 1 |
| 2 | `refresh_index.ts:40` | Refresh all SO indices | `POST /_refresh` | All `.kibana*` SO indices | 4 |
| 3 | `refresh_index.ts:44` | Clear cache all SO indices | `POST /_cache/clear` | All `.kibana*` SO indices | 4 |
| 4 | `bulk_actions/route.ts:235` → `rulesClient.find` | SO `find` of type `alert` | `POST /.kibana_alerting_cases/_search` | `.kibana_alerting_cases` | 1 |
| 5 | `bulk_actions/route.ts:291` → `rulesClient.bulkDeleteRules` | SO `delete` per matched rule (+ task SO deletion) | `POST /_bulk` | `.kibana_alerting_cases`, `.kibana_task_manager` | 0 (no rules to delete in this test) |
| 6 | `find_rules/route.ts:116` → `rulesClient.find` | SO `find` of type `alert` | `POST /.kibana_alerting_cases/_search` | `.kibana_alerting_cases` | 1 |
| 7 | Fleet EPM remove package handler | SO `find`/`get`/`delete` for `epm-packages`, `epm-packages-assets`, `security-rule`, dashboards, etc.; ES ingest/cluster `DELETE` for owned assets | mixed | `.kibana*`, ES `_ingest`/`_index_template`/etc. | 1 endpoint call producing many ops |
| 8 | `fetch_latest_assets.ts:35` (via `_status` pre-install) | SO `find` of `security-rule` with `terms`+`top_hits` aggregation | `POST /.kibana_security_solution/_search` | `.kibana_security_solution` | 2 (once per `_status` call) |
| 9 | `find_rules.ts:54` (via `_status` `findRules`) | SO `find` of `alert` (`perPage: 1`) | `POST /.kibana_alerting_cases/_search` | `.kibana_alerting_cases` | 2 |
| 10 | `get_existing_prepackaged_rules.ts:90` (via `_status` and `_install`) | SO `find` of `alert` with `KQL_FILTER_IMMUTABLE_RULES`, `perPage: 10000` | `POST /.kibana_alerting_cases/_search` | `.kibana_alerting_cases` | 3 (`_status` ×2, install ×1) |
| 11 | `saved_object/timelines/index.ts:185` (via `_status` `checkTimelinesStatus`) | SO `find` of `siem-ui-timeline` (immutable templates) | `POST /.kibana/_search` | `.kibana` | 2 |
| 12 | `legacy_create_prepackaged_rules.ts:55` → `exceptionsListClient.createEndpointList()` | Idempotent SO `create` for endpoint list | `POST /.kibana/_create` | `.kibana` (lists) | 1 |
| 13 | `ensure_latest_rules_package_installed.ts:22` → `fetchLatestAssets({ size: 1 })` | SO `find` of `security-rule` (aggregation, `size: 1`) | `POST /.kibana_security_solution/_search` | `.kibana_security_solution` | 1 |
| 14 | `legacy_create_prepackaged_rules.ts:60` → `fetchLatestAssets()` (full) | SO `find` of `security-rule` (aggregation, `size: 10000`) | `POST /.kibana_security_solution/_search` | `.kibana_security_solution` | 1 |
| 15 | `create_rule.ts:51` → `rulesClient.create` (×`rulesToInstall`) | SO `create` of `alert` per rule | `POST /.kibana_alerting_cases/_create` (one per rule) | `.kibana_alerting_cases` | 3,000 |
| 16 | `create_rule.ts:51` → Task Manager `schedule` (per *enabled* rule) | SO `create` of `task` | `POST /.kibana_task_manager/_create` | `.kibana_task_manager` | 0 (prebuilt installs default to `enabled: false`) |
| 17 | `perform_timelines_installation.ts` → `installPrepackagedTimelines` | SO `find` + per-timeline SO writes for `siem-ui-timeline` (+ related notes/pinned events) | mixed | `.kibana` | a handful (small fixed timelines) |
| 18 | `upgrade_prebuilt_rules.ts` (per rule needing update) | `rulesClient.update` (or delete+create) | mixed | `.kibana_alerting_cases` | 0 on a fresh install in this test |

### Where each call site lives in the codebase (compact index)

- **Test helpers**
  - `x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/utils/rules/prebuilt_rules/delete_all_prebuilt_rule_assets.ts`
  - `x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/utils/refresh_index.ts`
  - `x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/utils/rules/prebuilt_rules/delete_fleet_packages.ts`
  - `x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/utils/rules/prebuilt_rules/get_prebuilt_rules_and_timelines_status.ts`
  - `x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/utils/rules/prebuilt_rules/install_prebuilt_rules_and_timelines.ts`
  - `x-pack/solutions/security/test/security_solution_api_integration/config/services/detections_response/rules/delete_all_rules.ts`

- **Kibana handlers and logic**
  - `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/bulk_actions/route.ts`
  - `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/find_rules/route.ts`
  - `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/api/get_prebuilt_rules_and_timelines_status/get_prebuilt_rules_and_timelines_status_route.ts`
  - `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/api/install_prebuilt_rules_and_timelines/legacy_create_prepackaged_rules.ts`
  - `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/integrations/ensure_latest_rules_package_installed.ts`
  - `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/rule_assets/prebuilt_rule_assets_client/methods/fetch_latest_assets.ts`
  - `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/search/find_rules.ts`
  - `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/search/get_existing_prepackaged_rules.ts`
  - `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/create_rule.ts`
  - `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/bulk_delete_rules.ts`
  - `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/rule_objects/create_prebuilt_rules.ts`
  - `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/rule_objects/upgrade_prebuilt_rules.ts`
  - `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/perform_timelines_installation.ts`
  - `x-pack/solutions/security/plugins/security_solution/server/lib/timeline/utils/check_timelines_status.ts`
  - `x-pack/solutions/security/plugins/security_solution/server/lib/timeline/saved_object/timelines/index.ts`

- **Outside the security_solution plugin**
  - `@kbn/alerting-plugin/server` — `RulesClient.find` / `create` / `bulkDeleteRules` (these are the layer that actually emits the SO operations against `.kibana_alerting_cases` and schedules tasks in `.kibana_task_manager`).
  - `@kbn/lists-plugin/server` — `ExceptionListClient.createEndpointList` for call #12.
  - `@kbn/fleet-plugin/server` — EPM package removal in section 2.3.
  - `@kbn/core-saved-objects-api-server` — every `SavedObjectsClient.find/create/get/delete` ultimately compiles to ES `_search`/`_create`/`_index`/`_delete`/`_bulk` against the corresponding `.kibana*` SO indices.

---

## 4. Hot spots / where the time goes

- **Heaviest single contributor:** call #15 (`rulesClient.create` × 3,000) — 3,000 SO writes against `.kibana_alerting_cases`. This is sequenced through `initPromisePool` with `MAX_RULES_TO_UPDATE_IN_PARALLEL` concurrency, but each create still incurs an audit log entry and the alerting `validate`/`extractReferences` pipeline.
- **Second heaviest:** the `fetchLatestAssets` aggregations (#8, #13, #14). Each one runs a `terms` aggregation with up to 10,000 buckets and a `top_hits` sub-aggregation across all 30,000 `security-rule` SOs. There are **four** of these per iteration (2 from `_status` calls + 1 from `ensureLatestRulesPackageInstalled` + 1 from the explicit `fetchLatestAssets()` in `legacyCreatePrepackagedRules`).
- **Refresh + clear cache** (#2, #3) — 4 refresh + 4 clear-cache invocations against all `.kibana*` SO indices. Not free, but typically much cheaper than the 3,000-doc create burst.

For the related question of why `decd3284` does *not* materially speed up this test, see `decd3284-impact-on-install-large-bundled-package.md` in this directory.
