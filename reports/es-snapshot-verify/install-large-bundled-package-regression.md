# `kibana-elasticsearch-snapshot-verify` regression — `install_large_bundled_package`

**Status:** Reproducible locally, root cause **not yet identified**. Suspected to be an Elasticsearch change that landed between the 11 May and 12 May 2026 daily ES snapshots.

**First failing pipeline:** `kibana-elasticsearch-snapshot-verify`, starting **12 May 2026**.

**Failing job / test:**

```24:60:x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/prebuilt_rules_package/air_gapped/install_large_bundled_package.ts
  describe('@ess @serverless @skipInServerlessMKI Install large bundled package', () => {
    beforeEach(async () => {
      await deleteAllRules(supertest, log);
      await deleteAllPrebuiltRuleAssets(es, log);
      await deletePrebuiltRulesFleetPackage({ supertest, retryService, log, es });
    });

    it('should install a package containing 15000 prebuilt rules without crashing', async () => {
      const statusBeforePackageInstallation = await getPrebuiltRulesAndTimelinesStatus(
        es,
        supertest
      );
      ...
      await installPrebuiltRulesAndTimelines(es, supertest); // <-- regresses here
      ...
    });
  });
```

The specific operation that became extremely slow (or hangs past Mocha's 360 000 ms timeout) is the legacy `PUT /api/detection_engine/rules/prepackaged` call inside `installPrebuiltRulesAndTimelines`:

```30:44:x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/utils/rules/prebuilt_rules/install_prebuilt_rules_and_timelines.ts
export const installPrebuiltRulesAndTimelines = async (
  es: Client,
  supertest: SuperTest.Agent
): Promise<InstallPrebuiltRulesAndTimelinesResponse> => {
  const response = await supertest
    .put(PREBUILT_RULES_URL)
    .set('kbn-xsrf', 'true')
    .set('elastic-api-version', '2023-10-31')
    .send()
    .expect(200);

  await refreshSavedObjectIndices(es);

  return response.body;
};
```

## TL;DR

- Pinning Kibana to the **11 May 2026** ES snapshot, the test passes in ~30 s.
- Pinning Kibana to the **12 May 2026** ES snapshot, the test reliably exceeds Mocha's 360 s timeout (≥ 12× slower).
- The Kibana code is identical between the two runs; only the Elasticsearch binary differs.
- Therefore the regression sits somewhere in this ES commit range:
  - **From (good, 11 May snapshot):** [`32342fb5bfd04a6b04ba17f609cb82228c318bca`](https://github.com/elastic/elasticsearch/commit/32342fb5bfd04a6b04ba17f609cb82228c318bca)
  - **To (bad, 12 May snapshot):** [`3cd6e1f7737a51fe53134a0abf61fc29797d48e7`](https://github.com/elastic/elasticsearch/commit/3cd6e1f7737a51fe53134a0abf61fc29797d48e7)
  - **GitHub compare URL (use this to bisect / browse the offending commits):**
    <https://github.com/elastic/elasticsearch/compare/32342fb5bfd04a6b04ba17f609cb82228c318bca...3cd6e1f7737a51fe53134a0abf61fc29797d48e7>

Both snapshots are tagged against `main` of `elastic/elasticsearch` and built as ES `9.5.0-SNAPSHOT`.

---

## Context

### Fixture size

The "large bundled package" config materialises a synthetic Fleet package on disk before the test runs:

- `NUM_OF_RULE_IN_MOCK_LARGE_PKG = 3 000` unique `PrebuiltRuleAsset`s
- `PREBUILT_RULE_VERSIONS_COUNT = 10` historical versions per rule
- → **30 000 `PrebuiltRuleAsset` saved objects** in the bundled Fleet package
- → On install, Kibana ends up bulk-creating **3 000 detection rules** (one per unique `rule_id`) in `.kibana_alerting_cases`.

(The test name says "15000 prebuilt rules"; that text is historical and was never updated when the constant was bumped to 30 000 assets.)

The config also flips Kibana into "air-gapped" mode and points Fleet at a local zip:

```27:40:x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/configs/edge_cases/ess_air_gapped_with_bundled_large_package.config.ts
    kbnTestServer: {
      ...functionalConfig.get('kbnTestServer'),
      serverArgs: [
        ...functionalConfig.get('kbnTestServer.serverArgs'),
        `--xpack.fleet.isAirGapped=true`,
        `--xpack.fleet.developer.bundledPackageLocation=${BUNDLED_PACKAGE_DIR}`,
      ],
    },
```

So the test exercises a real Fleet/EPM install of a 30 000-asset package, followed by the legacy "install prepackaged rules" code path that copies each unique asset into `.kibana_alerting_cases` as a detection rule.

### Why this points at Elasticsearch and not Kibana

The pipeline `kibana-elasticsearch-snapshot-verify` re-runs Kibana's CI against the **latest ES snapshot** without changing Kibana's source. The first failing run picked up a new ES binary; the previous day's run (with the previous day's ES binary, same Kibana commits) was green. Locally we confirmed the same: same Kibana checkout, different `ES_SNAPSHOT_MANIFEST`, opposite outcomes.

### Adjacent / pre-existing reports in this repo

- `decd3284-impact-on-install-large-bundled-package.md` — investigates a Kibana-side commit suspected to slow the same test; conclusion was "not the cause".
- `es-calls-install-large-bundled-package.md` — full inventory of every ES call this test emits, both direct (via FTR `es` service) and indirect (via Kibana plugin code). Useful when narrowing down which ES API is regressing.
- `pr-270397-es-cluster-ftr-logs-as-buildkite-artifact.md` — PR adding the ES `cluster-ftr` logs as a Buildkite artifact, useful for capturing slow-query / merge logs from the failing CI job.

---

## Local reproduction

Tested on macOS (Apple Silicon, `darwin-aarch64`), Node 24.14.1, Kibana `main` at `0b13de4978c1`. Same approach works on Linux; just substitute the per-platform tarball in the manifest.

The runtime difference is so large (≤ 35 s vs ≥ 360 s) that any modern dev laptop should reproduce it within one or two runs.

### One-time prerequisites

```bash
cd <path-to-kibana-checkout>
yarn kbn bootstrap     # only needed if you haven't bootstrapped this branch
```

### Step 1 — boot the FTR test server against an ES snapshot

Run this in **terminal A** and leave it running. Pick the snapshot you want to test by exporting `ES_SNAPSHOT_MANIFEST` *before* launching the server (the runner does not need this env var):

```bash
# Good snapshot (11 May 2026): test passes in ~30 s
export ES_SNAPSHOT_MANIFEST="https://storage.googleapis.com/kibana-ci-es-snapshots-daily/9.5.0/archives/20260511-022512_32342fb5/manifest.json"

# Bad snapshot (12 May 2026): test hangs past Mocha's 360 s timeout
# export ES_SNAPSHOT_MANIFEST="https://storage.googleapis.com/kibana-ci-es-snapshots-daily/9.5.0/archives/20260512-022202_3cd6e1f7/manifest.json"

export NODE_OPTIONS=--max-old-space-size=8192

node scripts/functional_tests_server \
  --config x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/configs/edge_cases/ess_air_gapped_with_bundled_large_package.config.ts
```

The FTR server downloads the ES tarball into `.es/cache/`, extracts it into `.es/cluster-ftr/`, then starts ES on `:9220` and Kibana on `:5620`. Wait until the log line:

```
[INFO ][status] Kibana is now available
```

is printed before continuing.

### Step 2 — run the failing test against the running server

In **terminal B** (the env var is *not* required here):

```bash
cd <path-to-kibana-checkout>
export NODE_OPTIONS=--max-old-space-size=8192

time node scripts/functional_test_runner \
  --bail \
  --config x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/configs/edge_cases/ess_air_gapped_with_bundled_large_package.config.ts
```

Repeat 2–3× back-to-back to confirm the timing is stable. The same server can be reused across runs.

### Step 3 — read the right number

Mocha prints two timings per run; the one to look at is the **per-test runtime in `(...)` next to the pass/fail line**:

```
└- ✓ pass  (33.1s)      <-- THIS is the actual it() body runtime; this is the regression metric
1 passing (35.5s)        <-- This is Mocha total: it() + beforeEach + afterEach
```

Wall-clock from `time` includes `node` startup + FTR config loading and is the most pessimistic number.

### Step 4 — flip snapshots and repeat

To switch snapshots:

1. In terminal A, press `Ctrl-C` to stop the FTR server. **Confirm both `java` (ES) and `node` (Kibana) processes are actually gone** before restarting — `Ctrl-C` does *not* always reap them, and the next `functional_tests_server` invocation will then fail with:
   ```
   Lock held by another program: .../.es/cluster-ftr/data/_state/write.lock
   ```
   If you see that, do:
   ```bash
   # On macOS / Linux
   lsof -i :9220 -i :5620 -n -P | awk 'NR>1 && /LISTEN/ {print $2}' | xargs -r kill -9
   ps -ef | grep -E 'cluster-ftr|controller.app|functional_tests_server' | grep -v grep | awk '{print $2}' | xargs -r kill -9
   ```
2. `export` the *other* `ES_SNAPSHOT_MANIFEST` URL.
3. Re-run the step 1 command. The next startup wipes `.es/cluster-ftr/` and re-extracts the new tarball, so cached state from the previous snapshot is not a concern.

### Local results (reference)

Captured against Kibana `main` @ `0b13de4978c1`, with the same checkout and shell session, only `ES_SNAPSHOT_MANIFEST` flipped between runs.

| Snapshot                                  | Run | Test runtime (`it` block) | Mocha total | Wall-clock (`time`) | Status |
| ----------------------------------------- | --- | ------------------------- | ----------- | ------------------- | ------ |
| **11 May** `20260511-022512_32342fb5`     | 1   | 33.1 s                    | 35.5 s      | 43.6 s              | pass   |
| 11 May                                    | 2   | 30.5 s                    | 48.5 s      | 56.1 s              | pass   |
| 11 May                                    | 3   | 32.3 s                    | 49.9 s      | 58.4 s              | pass   |
| **12 May** `20260512-022202_3cd6e1f7`     | 1   | **> 360 s (timeout)**     | 6.0 m       | 6 m 10.9 s          | **fail** |
| 12 May                                    | 2   | **> 360 s (timeout)**     | 6.0 m       | 6 m 11.8 s          | **fail** |
| 12 May                                    | 3   | **> 360 s (timeout)**     | 6.0 m       | 6 m 12.0 s          | **fail** |

The variance between 11 May runs 2/3 vs run 1 in the *Mocha total* column is explained by `beforeEach` having to delete the 3 000 rules left behind by the previous run; the `it`-block number stays in the 30 s range.

---

## What the failing call actually does inside Kibana / ES

The slow call is `PUT /api/detection_engine/rules/prepackaged` (constant `PREBUILT_RULES_URL`, server handler `legacyCreatePrepackagedRules`). End-to-end it:

1. Ensures the prebuilt-rules Fleet package is installed (in this config, from the bundled zip — no EPR HTTP traffic).
2. Reads all 30 000 `security-rule` saved objects out of `.kibana_security_solution` via paginated SO finds.
3. Materialises one detection rule per unique `rule_id` (3 000 rules) and bulk-creates them in `.kibana_alerting_cases` via `RulesClient.bulkCreate`.
4. Returns counts and refreshes SO indices.

Most of the ES work concentrates on:

- Bulk `index` / `update` against `.kibana_alerting_cases-*` (3 000 documents, each with multiple fields and a backing alerts-as-data mapping).
- Paginated `_search` against `.kibana_security_solution` (30 000 `security-rule` SOs).
- Mapping / template / ILM bootstrap on first install of the package.

See `.knowledge/reports/es-calls-install-large-bundled-package.md` for the exhaustive list of calls and citations to the call sites.

The CI failure timeline (12 May onwards) and the local reproduction both point at one or a handful of these ES operations becoming dramatically slower. Capturing slow-query logs from the failing run would identify which one — see "Next steps".

---

## Next steps for the investigator

1. **Bisect the ES commit range** linked above. The range is `main` between the two snapshot SHAs and is small enough to skim diffs by hand (start with anything touching bulk indexing, mappings on `.kibana_alerting_cases`, security plugin, ILM, or analyzer/lucene upgrade-the-data flows). If you want to bisect by running ES locally, build ES from each candidate SHA and point the FTR config at the resulting tarball (see `src/platform/packages/shared/kbn-es` for how `ES_SNAPSHOT_MANIFEST` is consumed).
2. **Capture ES slow logs** for the bad run by enabling `index.search.slowlog.threshold.query.warn` and `index.indexing.slowlog.threshold.index.warn` on `.kibana_alerting_cases-*` before invoking the test. The PR in `.knowledge/reports/pr-270397-es-cluster-ftr-logs-as-buildkite-artifact.md` (`#270397`) adds those logs as a Buildkite artifact, so once it lands, the CI runs themselves will surface the culprit.
3. **Profile the bad run** with `node --prof` against the Kibana node process, or use the FTR `apm` instrumentation that's already enabled in the runner output to see where wall-clock time concentrates.
4. **Open an Elasticsearch GitHub issue** (see template in the GitHub issue companion to this report) tagging the elastic core / security teams with the bisect range above.

---

## Quick reference — exact commands (no aliases)

```bash
# === Terminal A (server) — 11 May (good) ===
export ES_SNAPSHOT_MANIFEST="https://storage.googleapis.com/kibana-ci-es-snapshots-daily/9.5.0/archives/20260511-022512_32342fb5/manifest.json"
export NODE_OPTIONS=--max-old-space-size=8192
node scripts/functional_tests_server \
  --config x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/configs/edge_cases/ess_air_gapped_with_bundled_large_package.config.ts

# === Terminal A (server) — 12 May (bad) ===
export ES_SNAPSHOT_MANIFEST="https://storage.googleapis.com/kibana-ci-es-snapshots-daily/9.5.0/archives/20260512-022202_3cd6e1f7/manifest.json"
export NODE_OPTIONS=--max-old-space-size=8192
node scripts/functional_tests_server \
  --config x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/configs/edge_cases/ess_air_gapped_with_bundled_large_package.config.ts

# === Terminal B (runner) — same for both snapshots ===
export NODE_OPTIONS=--max-old-space-size=8192
time node scripts/functional_test_runner \
  --bail \
  --config x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/configs/edge_cases/ess_air_gapped_with_bundled_large_package.config.ts

# === Cleanup between snapshots (if Ctrl-C didn't kill ES/Kibana) ===
lsof -i :9220 -i :5620 -n -P | awk 'NR>1 && /LISTEN/ {print $2}' | xargs -r kill -9
ps -ef | grep -E 'cluster-ftr|controller.app|functional_tests_server' | grep -v grep | awk '{print $2}' | xargs -r kill -9
```
