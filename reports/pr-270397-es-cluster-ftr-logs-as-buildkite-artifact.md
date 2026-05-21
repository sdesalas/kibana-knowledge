# PR #270397 — Uploading `.es/cluster-ftr/logs/*` as a Buildkite artifact

- **PR:** [elastic/kibana#270397 — `[Security Solution] Enable ES query debug logging for large bundled package test`](https://github.com/elastic/kibana/pull/270397)
- **Author:** @steliosmavro
- **Reviewer comment by @sdesalas:**
  > Instead of this approach, do you think it is possible to modify the pipeline to allow downloading `.es/cluster-ftr/logs/*` folder in zip format as an artifact. I think the elasticsearch team will be a lot more familiar with this output, otherwise the kibana logs will be mixed in, and it will be a bit confusing.

## TL;DR

**Yes — this is straightforward, and the change should be scoped to `kibana-elasticsearch-snapshot-verify` only.** That pipeline is the right home for it: it is the snapshot integration-testing pipeline whose entire purpose is to validate a candidate ES snapshot against Kibana's FTR/Jest suites, so leaking the ES server logs to the ES team is genuinely useful there. On the regular PR / on-merge pipelines we have no signal-to-noise need for native ES logs and no reason to pay the artifact-storage cost.

The mechanical change is small: produce `.es/cluster-ftr/logs/` as a single tarball at the end of test execution and upload it as a Buildkite artifact, gated on the pipeline slug. We do **not** want to add this to the shared `.buildkite/scripts/lifecycle/post_command.sh` artifact glob list, because that script runs after every test step in every Kibana pipeline.

One nuance worth flagging: in CI the actual on-disk path is **not** `.es/cluster-ftr/logs/*`. The `kbn-test-es-server` cluster name is prefixed with `CI_PARALLEL_PROCESS_PREFIX`, so on CI runners the path is closer to `.es/job-<JOB>-worker-<N>-cluster-ftr/logs/*`. The glob/tar source has to account for that.

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

Artifact upload for test steps is centralised in `.buildkite/scripts/lifecycle/post_command.sh`, which runs after every test step in **every** Kibana pipeline. Today it uploads `.es/es*.log` and `.es/uiam*.log` (Docker stdout files), but **not** the native ES log directory (`.es/<cluster-name>/logs/`):

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

Because this script is shared across all Kibana pipelines, **adding the new pattern to `ARTIFACT_PATTERNS` is the wrong place**: it would upload the ES native log folder for every PR, on-merge, periodic, flaky-test-runner, and quality-gate run. We want this only on `kibana-elasticsearch-snapshot-verify`.

## Pipeline `kibana-elasticsearch-snapshot-verify`

The pipeline definition in `.buildkite/pipeline-resource-definitions/kibana-es-snapshots.yml` (`bk-kibana-elasticsearch-snapshot-verify`) points at `.buildkite/pipelines/es_snapshots/verify.yml`, which runs the standard FTR / scout test ordering steps:

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

Those scripts (`ftr_configs.sh`, `jest_integration.sh`, etc.) are also shared across pipelines, so we cannot simply edit them either without affecting other pipelines.

## Recommended change

Gate the upload on the pipeline slug, and produce a single tarball per job. Two equally-valid implementations:

### Option A — gate inside `post_command.sh` (smallest diff)

Add a snapshot-verify-only block near the end of the existing test-execution branch:

```bash
if [[ "$IS_TEST_EXECUTION_STEP" == "true" ]]; then
  # ...existing buildkite-agent artifact upload...

  if [[ "${BUILDKITE_PIPELINE_SLUG:-}" == "kibana-elasticsearch-snapshot-verify" ]]; then
    if compgen -G '.es/*cluster-ftr*/logs' > /dev/null; then
      ARCHIVE=".es/cluster-ftr-logs-${BUILDKITE_JOB_ID}.tar.gz"
      tar -czf "$ARCHIVE" .es/*cluster-ftr*/logs 2>/dev/null || true
      buildkite-agent artifact upload "$ARCHIVE"
    fi
  fi
fi
```

Notes:

- The glob is `*cluster-ftr*` rather than `cluster-ftr` to match the CI-prefixed cluster name (`job-<JOB>-worker-<N>-cluster-ftr`); see "Where these files come from" above.
- Bash brace-expanding `.es/*cluster-ftr*/logs` into the `tar` argv is fine — there is one such directory per job (parallelism is at the Buildkite-job level, not within a job). If we ever start launching multiple ES clusters per job, the tar will simply pack all of them.
- Using `BUILDKITE_JOB_ID` in the archive name keeps artifacts unique per parallel job in the Buildkite UI.
- Empty/no-match cases are handled gracefully (`compgen -G` short-circuits).

### Option B — keep the gate out of the shared script

If we want to keep `post_command.sh` strictly pipeline-agnostic, drive the upload from the snapshot-verify pipeline instead. Add a small `post-command` hook (or a wrapper script invoked by it) that lives under `.buildkite/scripts/pipelines/es_snapshots/` and is wired into `verify.yml`'s test steps via an `env:` flag, e.g. `UPLOAD_ES_NATIVE_LOGS=true`. Then `post_command.sh` only acts on that flag:

```bash
if [[ "${UPLOAD_ES_NATIVE_LOGS:-}" == "true" ]] && compgen -G '.es/*cluster-ftr*/logs' > /dev/null; then
  ARCHIVE=".es/cluster-ftr-logs-${BUILDKITE_JOB_ID}.tar.gz"
  tar -czf "$ARCHIVE" .es/*cluster-ftr*/logs 2>/dev/null || true
  buildkite-agent artifact upload "$ARCHIVE"
fi
```

…and the env var is set only by `verify.yml` (top-level `env:` block, or per-step), not by any other pipeline. This is a touch more code but keeps the shared script free of pipeline-slug `if`s. Either approach satisfies the "snapshot-verify only" constraint; Option A is the smaller change.

### Why not "individual files via glob"

Buildkite does not auto-zip artifacts. We could list `'.es/*cluster-ftr*/logs/**/*'` instead of tarring, but per-file uploads create dozens of artifacts per job spread across the UI, and the ES team explicitly asked for "zip format" — a single tarball per job matches that request and is the friendlier handoff.

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

- **Scope.** The change must be scoped to `kibana-elasticsearch-snapshot-verify` only. Editing the shared `ARTIFACT_PATTERNS` list directly would leak ES log uploads into every PR, on-merge, flaky-test-runner, and quality-gate run, which is not what we want.
- **Path drift.** `cluster-ftr` is the current default name (`name = 'ftr'` in `run_elasticsearch.ts`). CCS configs use `cluster-ftr-local` / `cluster-ftr-remote`. The `*cluster-ftr*` glob covers all of these without picking up unrelated `.es/` subfolders.
- **Docker / serverless ES.** When ES is run via Docker (serverless configs), kbn-es uses `extractAndArchiveLogs` to capture container `docker logs` to `.es/<container-name>-<id>.log` — already partially covered by the existing `.es/es*.log` glob. Native log files are inside the container in that case and are not on the host filesystem, so the new tar would simply produce no matches for serverless runs (safe — `compgen -G` short-circuits).
- **Permissions.** `kibana-elasticsearch-snapshot-verify` grants `BUILD_AND_READ` to `everyone`, so the ES team can download artifacts from those builds.
- **Volume.** Native ES logs (`gc.log`, structured server log, slow logs) can be tens of MB per job under load. Tarring keeps it to one compressed artifact per job; on a snapshot-verify run that's acceptable.

## Suggested response on the PR

> Yes, this is straightforward — but I'd scope it to `kibana-elasticsearch-snapshot-verify` only, not to every FTR run. The plan: gate on `BUILDKITE_PIPELINE_SLUG == 'kibana-elasticsearch-snapshot-verify'` and `tar -czf .es/cluster-ftr-logs-${BUILDKITE_JOB_ID}.tar.gz .es/*cluster-ftr*/logs` next to the existing artifact upload (the `*cluster-ftr*` glob is needed because CI prefixes the cluster name with `job-<JOB>-worker-<N>-`). That gives the ES team a single zipped artifact per job from the snapshot-verify pipeline, without changing artifact behaviour anywhere else. If we land that, we can drop the `elasticsearch.query` Kibana-side logger from this config — the native ES server log inside that tarball gives the same information in the format the ES team is already used to.

## File references

- `.buildkite/pipeline-resource-definitions/kibana-es-snapshots.yml` — pipeline definitions (`bk-kibana-elasticsearch-snapshot-verify` block).
- `.buildkite/pipelines/es_snapshots/verify.yml` — verify pipeline steps.
- `.buildkite/scripts/lifecycle/post_command.sh` — shared per-step artifact upload (this is where the change goes).
- `.buildkite/scripts/common/util.sh` — `is_test_execution_step` helper that gates artifact upload.
- `src/platform/packages/shared/kbn-test/src/functional_tests/lib/run_elasticsearch.ts` — sets `clusterName: 'cluster-${name}'`, `basePath: .es/`.
- `src/platform/packages/shared/kbn-test-es-server/src/test_es_cluster.ts` — composes `installPath = basePath/${CI_PARALLEL_PROCESS_PREFIX}clusterName`.
- `src/platform/packages/shared/kbn-test-es-server/src/ci_parallel_process_prefix.ts` — defines the `job-…-worker-…-` prefix used in CI.
- `src/platform/packages/shared/kbn-es/src/utils/extract_and_archive_logs.ts` — Docker stdout extraction (already covered by existing `.es/es*.log` glob).
