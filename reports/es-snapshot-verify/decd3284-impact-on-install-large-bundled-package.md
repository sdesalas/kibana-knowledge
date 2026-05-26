# Impact of commit `decd3284` on `install_large_bundled_package.ts`

**Commit:** `decd3284407eeccc6f35d198a22688bb970ddb31` — *[Security Solution] Make performance optimizations to Prebuilt Rules API endpoints (#263759)*

**Test under analysis:**
`x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/prebuilt_rules_package/air_gapped/install_large_bundled_package.ts`

**Test fixture size (from `ess_air_gapped_with_bundled_large_package.config.ts`):**
- `NUM_OF_RULE_IN_MOCK_LARGE_PKG = 3000` unique rules
- `PREBUILT_RULE_VERSIONS_COUNT = 10` historical versions per rule
- → 30,000 `PrebuiltRuleAsset` saved objects in the bundled Fleet package

## TL;DR

The change to `review_rule_installation_handler.ts` (`Promise.all` → sequential `await`) does **not** affect this test, because the test never hits `POST /internal/detection_engine/prebuilt_rules/installation/_review`.

Two *other* changes in the same commit do touch code paths this test exercises, but the net impact on wall-clock runtime is small and likely a slight increase, not a decrease:

1. `legacyCreatePrepackagedRules` now performs **one extra `fetchLatestAssets()` round-trip** during installation.
2. `ensureLatestRulesPackageInstalled()` no longer materialises 30,000 assets in memory — it only fetches one bucket — but in the legacy install path that memory was already going to be re-loaded immediately afterwards anyway.

The status endpoint hit by this test (`GET ${LEGACY_BASE_URL}/_status`) was **not** modified by this commit and behaves identically.

---

## What the test actually does

```31:46:x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/prebuilt_rules_package/air_gapped/install_large_bundled_package.ts
    it('should install a package containing 15000 prebuilt rules without crashing', async () => {
      const statusBeforePackageInstallation = await getPrebuiltRulesAndTimelinesStatus(...);
      ...
      await installPrebuiltRulesAndTimelines(es, supertest);
      const statusAfterPackageInstallation = await getPrebuiltRulesAndTimelinesStatus(...);
```

Endpoint mapping:

| Helper | HTTP | Endpoint | Server entry |
|---|---|---|---|
| `getPrebuiltRulesAndTimelinesStatus` | `GET` | `/api/detection_engine/rules/prepackaged/_status` (`PREBUILT_RULES_STATUS_URL` = `${LEGACY_BASE_URL}/_status`) | `getPrebuiltRulesAndTimelinesStatusRoute` |
| `installPrebuiltRulesAndTimelines` | `PUT` | `/api/detection_engine/rules/prepackaged` (`PREBUILT_RULES_URL` = `LEGACY_BASE_URL`) | `legacyCreatePrepackagedRules` |

Where (from `x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/prebuilt_rules/urls.ts`):

```13:17:x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/prebuilt_rules/urls.ts
const LEGACY_BASE_URL = `${RULES}/prepackaged` as const;
const BASE_URL = `${INTERNAL}/prebuilt_rules` as const;

export const PREBUILT_RULES_URL = LEGACY_BASE_URL;
export const PREBUILT_RULES_STATUS_URL = `${LEGACY_BASE_URL}/_status` as const;
```

Neither of these is `reviewRuleInstallationHandler`, which serves `POST /internal/detection_engine/prebuilt_rules/installation/_review` (`REVIEW_RULE_INSTALLATION_URL` = `${BASE_URL}/installation/_review`).

### Full HTTP traffic per single test iteration

Tracing through every helper used in `beforeEach` and the test body, one full execution of this test produces the following Kibana HTTP requests:

| # | Phase | Method | Endpoint | Helper / Constant | Notes |
|---|---|---|---|---|---|
| 1 | `beforeEach` | `POST` | `/api/detection_engine/rules/_bulk_action` | `deleteAllRules` → `DETECTION_ENGINE_RULES_BULK_ACTION` | Body: `{ action: 'delete', query: '' }`. Wrapped in `countDownTest` (up to 50 attempts, 1 s apart) |
| 2 | `beforeEach` | `GET` | `/api/detection_engine/rules/_find?page=1&per_page=1` | `deleteAllRules` → `DETECTION_ENGINE_RULES_URL_FIND` | Verifies `total === 0` after deletion |
| 3 | `beforeEach` | `DELETE` | `/api/fleet/epm/packages/security_detection_engine` | `deletePrebuiltRulesFleetPackage` → `epmRouteService.getRemovePath(PREBUILT_RULES_PACKAGE_NAME)` | Body: `{ force: true }`. Wrapped in `retryService.tryWithRetries` (up to 3 attempts, 3 min total) |
| 4 | `it` (pre) | `GET` | `/api/detection_engine/rules/prepackaged/_status` | `getPrebuiltRulesAndTimelinesStatus` → `PREBUILT_RULES_STATUS_URL` | First call; verifies status is empty |
| 5 | `it` (install) | `PUT` | `/api/detection_engine/rules/prepackaged` | `installPrebuiltRulesAndTimelines` → `PREBUILT_RULES_URL` | The heavy one — installs the 3,000-rule bundled package |
| 6 | `it` (post) | `GET` | `/api/detection_engine/rules/prepackaged/_status` | `getPrebuiltRulesAndTimelinesStatus` → `PREBUILT_RULES_STATUS_URL` | Second call; verifies post-install status |

Plus direct ES traffic (no Kibana HTTP endpoint involved):

- `deleteAllPrebuiltRuleAssets(es, log)` — ES `deleteByQuery` against `SECURITY_SOLUTION_SAVED_OBJECT_INDEX` filtered by `type:security-rule`, with `wait_for_completion: true` and `refresh: true`.
- `refreshSavedObjectIndices(es)` — called from `getPrebuiltRulesAndTimelinesStatus`, `installPrebuiltRulesAndTimelines`, and `deletePrebuiltRulesFleetPackage` to force a refresh on the security-solution and alerting SO indices.

Notably **absent** from this test:

- `POST /internal/detection_engine/prebuilt_rules/installation/_review` (`REVIEW_RULE_INSTALLATION_URL`) — handled by `reviewRuleInstallationHandler`, which is the file changed by `decd3284`.
- `POST /internal/detection_engine/prebuilt_rules/installation/_perform` (`PERFORM_RULE_INSTALLATION_URL`).
- `POST /internal/detection_engine/prebuilt_rules/upgrade/_review` and `_perform` (`REVIEW_RULE_UPGRADE_URL`, `PERFORM_RULE_UPGRADE_URL`).
- Any other endpoint under `BASE_URL = /internal/detection_engine/prebuilt_rules`.

This is why the `Promise.all` → sequential change in `review_rule_installation_handler.ts` cannot affect this test.

---

## Files in `decd3284` and their relevance

### 1. `review_rule_installation_handler.ts` — IRRELEVANT

```diff
-    const [rules, stats] = await Promise.all([
-      fetchRules({...}),
-      fetchStats({...}),
-    ]);
+    const rules = await fetchRules({...});
+    const stats = await fetchStats({...});
```

This handler is never invoked by the test. No impact.

(Aside: even on the `_review` endpoint this is a small effect. Both `fetchRules` and `fetchStats` internally call `getInstallableRuleVersions` → `ruleAssetsClient.fetchLatestVersions(...)`. With `Promise.all` the two `fetchLatestVersions` queries — one with the user filter, one without — were issued concurrently. Now they're serialised, costing ~one extra ES round-trip per call.)

### 2. `legacy_create_prepackaged_rules.ts` — RELEVANT (slight slowdown)

```diff
-  const latestPrebuiltRules = await ensureLatestRulesPackageInstalled(
-    ruleAssetsClient, context, logger
-  );
+  await ensureLatestRulesPackageInstalled(ruleAssetsClient, context, logger);
+  const latestPrebuiltRules = await ruleAssetsClient.fetchLatestAssets();
```

Before the commit, `ensureLatestRulesPackageInstalled` returned the full asset list and that same array was reused for `getRulesToInstall`/`getRulesToUpdate`.

After the commit, the install path makes **two** SO `find()` calls instead of one:
1. Inside `ensureLatestRulesPackageInstalled` → `fetchLatestAssets({ size: 1 })` (cheap, single bucket).
2. Then explicitly `ruleAssetsClient.fetchLatestAssets()` (full aggregation over 30,000 assets).

The full aggregation is the same one that was already being performed before, so the *additional* cost is just the small `size: 1` query — typically a few ms against ES. For the large-package test the heavy work (`createPrebuiltRules` over 3,000 rules, alerting SO inserts, task scheduling) dominates total runtime by orders of magnitude, so this is unlikely to be measurable.

### 3. `ensure_latest_rules_package_installed.ts` — RELEVANT (memory; runtime largely unchanged)

```diff
-  let latestPrebuiltRules = await ruleAssetsClient.fetchLatestAssets();
+  const latestPrebuiltRules = await ruleAssetsClient.fetchLatestAssets({ size: 1 });
   if (latestPrebuiltRules.length === 0) {
     await installPrebuiltRulesPackage(securityContext, logger);
-    latestPrebuiltRules = await ruleAssetsClient.fetchLatestAssets();
   }
-  return latestPrebuiltRules;
+  // returns void
```

Two functional changes:

- **Memory:** Previously this function held all 30,000 latest-version assets in memory just to check `length === 0`. Now it holds 1 bucket (≈ 1 asset). For the large-package test, the bundled package is already installed by the FTR fixture before each test, so the `length === 0` branch (which would re-run `installPrebuiltRulesPackage` and re-fetch) is not hit. The memory savings here apply mostly to *callers other than* `legacyCreatePrepackagedRules`, since that caller now does its own full `fetchLatestAssets()` afterwards.
- **Branch difference (subtle):** Previously, after installing the package, `ensureLatestRulesPackageInstalled` re-fetched the full asset list. Now it does not — the caller is responsible. In `legacyCreatePrepackagedRules` the next line is exactly that full fetch, so behaviour is preserved. *But* if the package has to be installed during this call, the second fetch happens via the caller rather than internally; net round-trips are the same in that branch.

For this specific test, the package is pre-installed, so this branch is never hit and the only observable change is the extra `size: 1` query noted above.

### 4. `prebuilt_rule_assets_client/index.ts` and `methods/fetch_latest_assets.ts` — wiring

These add the `FetchLatestAssetsOptions { size: number }` plumbing. No standalone behaviour change for this test beyond what's described above; the default `size = MAX_PREBUILT_RULES_COUNT` keeps the un-optioned call site identical.

### 5. `methods/fetch_deprecated_rules.ts` — IRRELEVANT

Renames `validateDeprecatedRuleAsset` → `validateDeprecatedRuleAssets` and switches from a per-SO map to a batch validate. Only used by the deprecation review endpoint. Not called by this test.

### 6. `upgrade_prebuilt_rules.ts` — IRRELEVANT

Pure formatting change (`{ ruleAsset: rule }` reformatted across multiple lines).

---

## Code paths in the large-package test, before vs after

### Phase A — `GET /api/detection_engine/rules/prepackaged/_status` (called twice)

Implementation in `getPrebuiltRulesAndTimelinesStatusRoute`:

```58:84:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/api/get_prebuilt_rules_and_timelines_status/get_prebuilt_rules_and_timelines_status_route.ts
          const latestPrebuiltRules = await ruleAssetsClient.fetchLatestAssets();
          const customRules = await findRules({...});
          const installedPrebuiltRules = rulesToMap(
            await getExistingPrepackagedRules({ rulesClient, logger })
          );
          const rulesToInstall = await getRulesToInstall(...);
          const rulesToUpdate = await getRulesToUpdate(...);
```

**Unchanged by the commit.** `fetchLatestAssets()` still aggregates over all 3,000 rule_ids and returns 3,000 `PrebuiltRuleAsset` objects.

### Phase B — `PUT /api/detection_engine/rules/prepackaged` (called once)

Before the commit, `legacyCreatePrepackagedRules` did:
1. `ensureLatestRulesPackageInstalled` → `fetchLatestAssets()` (full, 3,000 buckets) → returned to caller.
2. `getExistingPrepackagedRules` (alerting SO find).
3. `getRulesToInstall` / `getRulesToUpdate`.
4. `createPrebuiltRules` (the heavy work for 3,000 rules).
5. `performTimelinesInstallation`, `upgradePrebuiltRules`.

After the commit:
1. `ensureLatestRulesPackageInstalled` → `fetchLatestAssets({ size: 1 })` (1 bucket).
2. **New:** `fetchLatestAssets()` (full, 3,000 buckets).
3. `getExistingPrepackagedRules`.
4. `getRulesToInstall` / `getRulesToUpdate`.
5. `createPrebuiltRules` (unchanged — the dominant cost).
6. `performTimelinesInstallation`, `upgradePrebuiltRules`.

**Net delta:** one extra ES SO `find()` with a tiny aggregation. Step 5 (`createPrebuiltRules` writing 3,000 alerting SOs and scheduling 3,000 tasks) is the actual hot path and is untouched.

---

## Will this measurably change test runtime?

**Probably not.** For the large-package test specifically:

- `+1` ES round-trip at install time (the new `size: 1` aggregation).
- No memory reduction in the install path (the second `fetchLatestAssets()` re-loads everything).
- Status endpoint unchanged.
- The dominant cost (`createPrebuiltRules` writing 3,000 rule SOs and scheduling 3,000 alerting tasks via Task Manager) is unchanged.

If timing comparisons before/after `decd3284` show a noticeable runtime increase for this test, the cause is more likely environmental (Task Manager queue contention, SO index health, `wait_for` on alerting SO refresh during 3,000 inserts) than this commit. The commit's own design goal — reducing memory in `ensureLatestRulesPackageInstalled` — primarily benefits callers that *don't* immediately re-load the full asset list (e.g. anywhere that only needs to gate on "is the package installed?"). The legacy install path is not one of those callers.

## Recommendations if investigating perceived slowdown

1. Confirm with `git bisect` against `decd3284` and the immediately surrounding commits before assigning blame to this PR — the heavy lifting in this test is unrelated to the changed files.
2. Check whether the test's `beforeEach` (`deleteAllRules`, `deleteAllPrebuiltRuleAssets`, `deletePrebuiltRulesFleetPackage`) became more expensive — those touch alerting SOs and Fleet packages and are typically responsible for variance.
3. If you do want to remove the extra round-trip introduced in `legacyCreatePrepackagedRules`, the cleanest fix is to keep `ensureLatestRulesPackageInstalled` returning the full asset list as a side benefit when it had to fetch them anyway, or have the caller skip step 1 entirely (since step 2 would also reveal an empty package).
