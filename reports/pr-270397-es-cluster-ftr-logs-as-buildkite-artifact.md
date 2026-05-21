# PR #270397 — Uploading `.es/cluster-ftr/logs/*` as a Buildkite artifact

- **PR:** [elastic/kibana#270397 — `[Security Solution] Enable ES query debug logging for large bundled package test`](https://github.com/elastic/kibana/pull/270397)
- **Author:** @steliosmavro
- **Reviewer comment by @sdesalas:**
  > Instead of this approach, do you think it is possible to modify the pipeline to allow downloading `.es/cluster-ftr/logs/*` folder in zip format as an artifact. I think the elasticsearch team will be a lot more familiar with this output, otherwise the kibana logs will be mixed in, and it will be a bit confusing.

## TL;DR

**Yes — this is straightforward and arguably the right approach.** The Buildkite glue that Kibana already uses to upload ES logs is a single shared shell script (`.buildkite/scripts/lifecycle/post_command.sh`). It runs on every test step and currently uploads `.es/es*.log` and `.es/uiam*.log` (Docker stdout files) but **not** the native ES log directory (`.es/<cluster-name>/logs/`). Adding the ES native log folder as an artifact is a one-line change to the artifact glob list. Buildkite stores it as ordinary artifacts (downloadable individually or via the CLI / UI as a folder); if a single zipped download is desired, we can `tar -czf` the folder before upload.

There is also one nuance worth flagging: in CI the actual on-disk path is **not** `.es/cluster-ftr/logs/*`. The `kbn-test-es-server` cluster name is prefixed with `CI_PARALLEL_PROCESS_PREFIX`, so on CI runners the path is closer to `.es/job-<JOB>-worker-<N>-cluster-ftr/logs/*`. The glob has to account for that.

## Where these files come from

When Kibana runs FTR tests, the ES test cluster is created by `createTestEsCluster` in `@kbn/test-es-server`:

```222:243:src/platform/packages/shared/kbn-test-es-server/src/test_es_cluster.ts
  const clusterName = `${CI_PARALLEL_PROCESS_PREFIX}${customClusterName}`;

  const defaultEsArgs = [
    `cluster.name=${clusterName}`,
    `transport.port=${transportPort ?? esTestConfig.getTransportPort()}`,
    // ...
  ];

  const config = {
    version: esVersion,
    installPath: Path.resolve(basePath, clusterName),
```

The FTR helper sets `clusterName: 'cluster-${name}'` (`name` defaults to `'ftr'`), so the install path is:

```141:153:src/platform/packages/shared/kbn-test/src/functional_tests/lib/run_elasticsearch.ts
  const cluster = createTestEsCluster({
    clusterName: `cluster-${name}`,
    // ...
    writeLogsToPath: logsDir ? resolve(logsDir, `es-cluster-${name}.log`) : undefined,
    basePath: resolve(REPO_ROOT, '.es'),
```

That gives:

- **Locally:** `installPath = .es/cluster-ftr/`
- **On CI (parallel):** `installPath = .es/job-<JOB>-worker-<N>-cluster-ftr/` (because of `CI_PARALLEL_PROCESS_PREFIX`).

Elasticsearch writes its native logs to `${installPath}/logs/` by default — `kbn-es` does **not** override `path.logs`. That's the folder @sdesalas wants:

- `gc.log*` (JVM GC log)
- `<cluster>.log` / `<cluster>_server.json` (the structured ES server log — this is what shows `elasticsearch.query` traces)
- `<cluster>_index_search_slowlog.json`, `<cluster>_index_indexing_slowlog.json`
- audit logs when enabled

`writeLogsToPath` is a separate stream that captures ES's `stdout`/`stderr` to `.es/<logsDir>/es-cluster-<name>.log` — it is not the same as the native log folder, and it does not include the per-logger output (e.g. `elasticsearch.query`).

## What Buildkite already uploads

Artifact upload is centralised here and runs after **every** test step in **every** Kibana pipeline (including `kibana-elasticsearch-snapshot-verify`):

```9:50:.buildkite/scripts/lifecycle/post_command.sh
IS_TEST_EXECUTION_STEP="$(buildkite-agent meta-data get "${BUILDKITE_JOB_ID}_is_test_execution_step" --default '')"

if [[ "$IS_TEST_EXECUTION_STEP" == "true" ]]; then
  echo "--- Upload Artifacts"

  ARTIFACT_PATTERNS=(
    # ...
    '.es/**/*.hprof'
    'data/es_debug_*.tar.gz'
    '.es/es*.log'
    '.es/uiam*.log'
  )

  buildkite-agent artifact upload "$(printf '%s;' "${ARTIFACT_PATTERNS[@]}")"
```

The flag `IS_TEST_EXECUTION_STEP` is set by the FTR / Jest / functional helpers (`is_test_execution_step` in `.buildkite/scripts/common/util.sh`, called from `.buildkite/scripts/steps/functional/common.sh`, `.../test/jest.sh`, `.../test/jest_integration.sh`, etc.), so the same logic already covers the `kibana-elasticsearch-snapshot-verify` pipeline (`verify.yml` invokes `pick_test_group_run_order.sh` which schedules the standard FTR / Jest scripts).

## Pipeline `kibana-elasticsearch-snapshot-verify` is just a wrapper

The pipeline definition in `.buildkite/pipeline-resource-definitions/kibana-es-snapshots.yml` (`bk-kibana-elasticsearch-snapshot-verify`) points at `.buildkite/pipelines/es_snapshots/verify.yml`, which simply runs the standard FTR / scout test ordering steps:

```41:57:.buildkite/pipelines/es_snapshots/verify.yml
  - command: .buildkite/scripts/steps/test/pick_test_group_run_order.sh
    label: 'Pick Test Group Run Order'
    # ...
    env:
      JEST_UNIT_SCRIPT: '.buildkite/scripts/steps/test/jest.sh'
      JEST_INTEGRATION_SCRIPT: '.buildkite/scripts/steps/test/jest_integration.sh'
      FTR_CONFIGS_SCRIPT: '.buildkite/scripts/steps/test/ftr_configs.sh'
      LIMIT_CONFIG_TYPE: integration,functional
```

There is nothing special in this pipeline that would prevent or require pipeline-specific artifact handling. Whatever we add to `post_command.sh` will run for `kibana-elasticsearch-snapshot-verify` jobs as well as for `kibana-pull-request`, `kibana-on-merge`, etc.

## Recommended change

There are two viable approaches.

### Option A — add the folder to the existing artifact glob (simplest)

Add a single line to `ARTIFACT_PATTERNS` in `.buildkite/scripts/lifecycle/post_command.sh`:

```bash
ARTIFACT_PATTERNS=(
  # ...existing entries...
  '.es/es*.log'
  '.es/uiam*.log'
  '.es/*cluster-ftr*/logs/**/*'   # native ES log dir for FTR clusters
)
```

Notes:

- Glob is `*cluster-ftr*` rather than `cluster-ftr` to also match the CI-prefixed name (`job-<JOB>-worker-<N>-cluster-ftr`).
- Optionally extend to `.es/*/logs/**/*` to capture every test cluster (e.g. `cluster-ftr-remote`, `cluster-ftr-local` for CCS) and any future `clusterName` we introduce.
- These end up as **individual** Buildkite artifacts (Buildkite does not auto-zip). They can still be downloaded as a folder using:
  - the Buildkite UI's "Download all" on the artifacts pane, or
  - the agent CLI: `buildkite-agent artifact download '.es/*cluster-ftr*/logs/**/*' . --build <build-id>`.
- This is the lowest-risk change, mirrors how `.es/es*.log` is already shipped, and makes ES logs available for **every** failing FTR config (not just the large-bundled-package test), which is generally useful for ES-heavy investigations.

### Option B — produce a single zip per job (matches @sdesalas' "zip format" wording)

If we want one self-contained archive per failing job (which is what the comment literally asks for), tar/zip the folder before upload:

```bash
if compgen -G '.es/*cluster-ftr*/logs' > /dev/null; then
  ARCHIVE=".es/cluster-ftr-logs-${BUILDKITE_JOB_ID}.tar.gz"
  tar -czf "$ARCHIVE" .es/*cluster-ftr*/logs 2>/dev/null || true
  buildkite-agent artifact upload "$ARCHIVE"
fi
```

Place this just after the existing `buildkite-agent artifact upload` call (or list `'.es/cluster-ftr-logs-*.tar.gz'` in `ARTIFACT_PATTERNS`). This produces one artifact per job, which is friendlier for the ES team to download and share — they get a single tarball rather than dozens of files spread across the artifact pane.

### Pipeline-specific gating (optional)

If we want this only on the snapshot-verify pipeline (to avoid noise / artifact storage cost on every PR build), gate by pipeline slug:

```bash
if [[ "${BUILDKITE_PIPELINE_SLUG:-}" == "kibana-elasticsearch-snapshot-verify" ]]; then
  # ...tar + upload...
fi
```

In practice I would not gate it. ES logs are already small relative to the screenshots/videos we routinely upload, and having them on PR builds would short-circuit a lot of cross-team debugging.

## Compared to the change in the PR

The current PR enables `elasticsearch.query: debug` only inside Kibana's logging config:

```36:44:x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/configs/edge_cases/ess_air_gapped_with_bundled_large_package.config.ts
        `--xpack.fleet.isAirGapped=true`,
        `--xpack.fleet.developer.bundledPackageLocation=${BUILDKITE_BUILD_DIR}`,
        `--logging.loggers=${JSON.stringify([
          ...LOGGING_CONFIG,
          { name: 'elasticsearch.query', level: 'debug' },
        ])}`,
```

That captures the queries Kibana **issues** (from the Kibana process), interleaved with all other Kibana log lines, in Kibana's log format. The reviewer's point is correct: the ES team usually wants the **server-side** view (the `elasticsearch.query` logger lives on the ES side too, and the native ES JSON log format is what they triage daily). Surfacing `.es/<cluster>/logs/` as an artifact gives them exactly that, without the large bundled-package test having to opt in to anything special, and without requiring future tests to wire up logging config of their own.

## Risks / things to watch

- **Volume.** Native ES logs include `gc.log` and the structured server log; on a slow / failing run they can be tens of MB per job. On heavy parallel CI it's still small relative to screenshots/videos but worth keeping an eye on artifact storage.
- **Path drift.** `cluster-ftr` is the current default name (`name = 'ftr'`). CCS configs use `cluster-ftr-local` / `cluster-ftr-remote`. Future test setups could pick other names. A `*` glob (`.es/*/logs/**/*`) is more durable than hard-coding `cluster-ftr`.
- **Docker / serverless ES.** When ES is run via Docker (serverless test configs), kbn-es uses `extractAndArchiveLogs` to capture container `docker logs` to `.es/<container-name>-<id>.log` — already partially covered by the existing `.es/es*.log` glob. Native log files are inside the container in that case and are not on the host filesystem, so the new glob would simply produce no matches for serverless runs (safe).
- **Permissions.** `kibana-elasticsearch-snapshot-verify` grants `BUILD_AND_READ` to `everyone`, so the ES team already has access to download artifacts from those builds.

## Suggested response on the PR

> Yes, this is straightforward — `post_command.sh` already uploads `.es/es*.log`; we'd just add a glob for the native ES log directory (`.es/*cluster-ftr*/logs/**/*`, or `.es/*/logs/**/*` to also cover CCS/multi-node cases). The CI-side cluster name has a `CI_PARALLEL_PROCESS_PREFIX`, so the glob has to accept `job-…-cluster-ftr` as well as bare `cluster-ftr`. If you want a single tarball per job (the "zip format" you mentioned), I'd add a small `tar -czf .es/cluster-ftr-logs-${BUILDKITE_JOB_ID}.tar.gz .es/*cluster-ftr*/logs` step right next to the existing artifact upload. Happy to land this as a separate PR so it benefits every FTR run, not just this one — and then we can drop the `elasticsearch.query` Kibana-side logger from this config.

## File references

- `.buildkite/pipeline-resource-definitions/kibana-es-snapshots.yml` — pipeline definitions (`bk-kibana-elasticsearch-snapshot-verify` block).
- `.buildkite/pipelines/es_snapshots/verify.yml` — verify pipeline steps.
- `.buildkite/scripts/lifecycle/post_command.sh` — shared per-step artifact upload (this is where the change goes).
- `.buildkite/scripts/common/util.sh` — `is_test_execution_step` helper that gates artifact upload.
- `src/platform/packages/shared/kbn-test/src/functional_tests/lib/run_elasticsearch.ts` — sets `clusterName: 'cluster-${name}'`, `basePath: .es/`.
- `src/platform/packages/shared/kbn-test-es-server/src/test_es_cluster.ts` — composes `installPath = basePath/${CI_PARALLEL_PROCESS_PREFIX}clusterName`.
- `src/platform/packages/shared/kbn-test-es-server/src/ci_parallel_process_prefix.ts` — defines the `job-…-worker-…-` prefix used in CI.
- `src/platform/packages/shared/kbn-es/src/utils/extract_and_archive_logs.ts` — Docker stdout extraction (already covered by existing `.es/es*.log` glob).
