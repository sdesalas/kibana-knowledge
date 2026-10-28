# `kibana-elasticsearch-snapshot-verify` regression — `install_large_bundled_package`

**Status:** Reproducible locally, root cause **not yet identified**. Suspected to be an Elasticsearch change that landed between the 11 May and 12 May 2026 daily ES snapshots.

**First failing pipeline:** [`kibana-elasticsearch-snapshot-verify`](https://buildkite.com/elastic/kibana-elasticsearch-snapshot-verify/builds?branch=main), starting **12 May 2026**.

**Tracking issue:** [`elastic/kibana#270748`](https://github.com/elastic/kibana/issues/270748).

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

## Raw ES HTTP calls and expected timings (normal / 11 May snapshot)

This is the wire-level view: every HTTP request Kibana (or the FTR `es` service) makes to Elasticsearch during one iteration of the test, with payload shape and the per-call wall-clock you should expect on the **good** (11 May) snapshot. The good-snapshot baseline for the whole `it` block is ~30 s; the numbers below add up to roughly that.

`{id}` is a typed SO id (e.g. `alert:9c1a…`, `security-rule:abc…`), `{ts}` is an ISO timestamp.
All SO writes go through the SavedObjects API which uses `?refresh=wait_for` by default — that puts a floor of one ES refresh interval (`index.refresh_interval`, default 1 s; lower on `.kibana*` system indices) on each write batch.

Numbers are order-of-magnitude estimates from a quiet Apple Silicon laptop with a single-node cluster on local SSD; CI is usually within 2–3× of these.

### Phase A — `beforeEach`

| # | Method + URL | Payload sketch | Normal-case latency |
|---|---|---|---|
| A1 | `POST /.kibana_alerting_cases/_search?size=10000` (via `deleteAllRules` → `bulk_actions/route.ts` → `fetchRulesByQueryOrIds`) | `{ "query": { "bool": { "filter": [{ "term": { "type": "alert" } }, { "term": { "alert.alertTypeId": "siem.<ruleType>" } } ] } }, "_source": [...] }` — empty result on first iter | 10–30 ms |
| A2 | *(skipped first iter; otherwise `POST /_bulk?refresh=wait_for` with up to N delete ops for `.kibana_alerting_cases` + `.kibana_task_manager`)* | n/a | n/a here |
| A3 | `POST /.kibana_security_solution/_delete_by_query?wait_for_completion=true&refresh=true` | `{ "query": { "query_string": { "query": "type:security-rule" } } }` — first iter matches 0 docs | 50–200 ms (empty); seconds when populated |
| A4 | `POST /.kibana_alerting_cases/_search?size=1` (Fleet/SO find for `epm-packages` precursor — varies) | minimal | 5–20 ms |
| A5 | `GET /.kibana/_doc/epm-packages:security_detection_engine` (Fleet `getInstallation`) | none | 5–20 ms |
| A6 | If pkg installed: a fan-out of `DELETE /_ingest/pipeline/<id>`, `DELETE /_index_template/<id>`, `DELETE /_component_template/<id>`, `DELETE /_ilm/policy/<id>`, plus SO `delete`s for `epm-packages-assets` and `kibana_assets` (`security-rule`, dashboards, lens, etc.) | empty bodies; tens to low hundreds of small requests | 1–5 s total (mostly no-op since A3 already emptied `security-rule`) |
| A7 | `POST /.kibana,.kibana_alerting_cases,.kibana_security_solution,.kibana_task_manager,.kibana_ingest,…/_refresh?ignore_unavailable=true` (via `refreshSavedObjectIndices`, ×4 across the iteration) | none | 50–200 ms each → ~0.3–0.8 s aggregate |
| A8 | `POST /.kibana,…/_cache/clear?ignore_unavailable=true` (×4) | none | 20–100 ms each → ~0.1–0.4 s aggregate |

**Phase A subtotal: ~2–6 s** (dominated by Fleet remove fan-out).

### Phase B — pre-install `GET /api/detection_engine/rules/prepackaged/_status`

After A3 the package zip is still on disk and gets re-installed lazily by `ensureLatestRulesPackageInstalled` once during the install handler (Phase C). For the **pre-install** status call here, only the SO finds run; the `security-rule` index is empty so most aggregations return 0 buckets.

| # | Method + URL | Payload sketch | Normal-case latency |
|---|---|---|---|
| B1 | `POST /.kibana_security_solution/_search?size=0` (`fetchLatestAssets` aggregation) | `{ "query": { "bool": { "filter": [{ "term": { "type": "security-rule" } }, { "bool": { "must_not": [{ "term": { "security-rule.attributes.deprecated": true } }] } } ] } }, "aggs": { "rules": { "terms": { "field": "security-rule.attributes.rule_id", "size": 10000 }, "aggs": { "latest_version": { "top_hits": { "size": 1, "sort": [{ "security-rule.version": "desc" }] } } } } } }` — 0 buckets pre-install | 20–80 ms |
| B2 | `POST /.kibana_alerting_cases/_search?size=1` (`findRules` with `params.immutable: false`) | `{ "query": { "bool": { "filter": [{ "term": { "type": "alert" } }, { "term": { "alert.attributes.params.immutable": false } } ] } } }` | 10–30 ms |
| B3 | `POST /.kibana_alerting_cases/_search?size=10000` (`getExistingPrepackagedRules`, `params.immutable: true`) | same shape with `immutable: true`; 0 hits pre-install | 10–40 ms |
| B4 | `POST /.kibana/_search?size=10000` (`checkTimelinesStatus`, `siem-ui-timeline` immutable templates) | `{ "query": { "bool": { "filter": [{ "term": { "type": "siem-ui-timeline" } }, { "term": { "siem-ui-timeline.attributes.timelineType": "template" } }, { "term": { "siem-ui-timeline.attributes.status": "immutable" } } ] } } }` | 10–40 ms |

**Phase B subtotal: ~50–200 ms.**

### Phase C — install `PUT /api/detection_engine/rules/prepackaged` (the slow one)

This is where ≥ 95 % of the iteration's wall-clock lives even on the good snapshot.

| # | Method + URL | Payload sketch | Normal-case latency |
|---|---|---|---|
| C1 | `POST /.kibana/_create/exception-list:endpoint_list` (idempotent; conflict → ignored) | endpoint-list SO body, ~1 KB | 10–40 ms (or 5–10 ms with conflict short-circuit) |
| C2 | `POST /.kibana_security_solution/_search?size=0` (`ensureLatestRulesPackageInstalled` → `fetchLatestAssets({ size: 1 })`) | same agg as B1 but `terms.size: 1` — still 0 buckets at this point | 20–80 ms |
| C3 | **Fleet install of bundled package** (triggered by C2 returning 0). Bundled mode → no EPR HTTP, but heavy local-zip → ES asset install. Issues many requests against `.kibana`: bulk_create of `epm-packages` + `epm-packages-assets` SOs, plus PUT of index templates, component templates, ingest pipelines, ILM policy, and ~30 000 `security-rule` SO writes via SO `bulk_create`. | Many `POST /_bulk?refresh=wait_for` chunks (default chunk = 1 000 SOs) against `.kibana_security_solution`; each chunk body is JSON ND, ~1–3 MB per chunk. Plus `PUT /_index_template/...`, `PUT /_component_template/...`, `PUT /_ingest/pipeline/...`, `PUT /_ilm/policy/...` — single-shot, small. | **~10–20 s** (≈30 chunks × 300–600 ms each, gated by `refresh=wait_for`). This is the second-heaviest contributor to the 30 s baseline. |
| C4 | `POST /.kibana_security_solution/_search?size=0` (`fetchLatestAssets()` full) | same agg as B1, `terms.size: 10 000`, now matches **30 000 docs** and returns **3 000 buckets**, each with a `top_hits.size:1` document (~2–4 KB per hit) — total response ~10–20 MB | **1–5 s** on the good snapshot. *Prime suspect for the regression: a slowdown in `terms` + `top_hits` aggregation on this index can directly explain the ≥ 12× cliff.* |
| C5 | `POST /.kibana_alerting_cases/_search?size=10000` (`getExistingPrepackagedRules`) | same as B3; still 0 hits | 10–40 ms |
| C6 | **`POST /.kibana_alerting_cases/_create/alert:{uuid}?refresh=wait_for` × 3 000** (issued through `initPromisePool`, `concurrency = MAX_RULES_TO_UPDATE_IN_PARALLEL = 20`) | per request: `{ "type": "alert", "alert": { "name": ..., "alertTypeId": "siem.queryRule" / siem.<type>, "consumer": "siem", "params": { ...rule params... , "immutable": true, "ruleId": "..." }, "schedule": { "interval": "5m" }, "actions": [], "enabled": false, "tags": [...], "createdBy": "...", "updatedBy": "...", "apiKey": null, ... }, "references": [], "coreMigrationVersion": "...", "typeMigrationVersion": "10.x.x", "updated_at": "{ts}", "created_at": "{ts}" }` — ~2–6 KB per body | per-request 30–150 ms (dominated by `refresh=wait_for` waiting on the next 1 s refresh window). At concurrency 20 → ~3 000 / 20 = 150 sequential waves × 80–120 ms ≈ **12–18 s** total. **Heaviest single contributor** to the 30 s baseline. |
| C7 | *(skipped — prebuilt rules install with `enabled: false`, so no Task Manager scheduling)*  Would otherwise be `POST /.kibana_task_manager/_create/task:{uuid}?refresh=wait_for` × N. | n/a | 0 ms here |
| C8 | `POST /.kibana/_search` + a small handful of `POST /.kibana/_create/siem-ui-timeline:{id}` for the bundled timeline templates (and any `siem-ui-timeline-note` / `…-pinned-event` they reference) | ~5–20 small SO writes, ~1–2 KB each | 50–300 ms aggregate |
| C9 | `upgradePrebuiltRules` — no-op on a fresh install (all rules came in via C6) | none | 0 ms |
| C10 | `POST /.kibana*/_refresh?ignore_unavailable=true` + `POST /.kibana*/_cache/clear?ignore_unavailable=true` (called from `installPrebuiltRulesAndTimelines` test helper after the HTTP response) | none | ~100–300 ms aggregate |

**Phase C subtotal: ~25–35 s on the good snapshot.** On the bad snapshot this balloons past 360 s and the test is killed by Mocha.

### Phase D — post-install `GET /api/detection_engine/rules/prepackaged/_status`

Same shape as Phase B but with populated indices.

| # | Method + URL | Payload sketch | Normal-case latency |
|---|---|---|---|
| D1 | `POST /.kibana_security_solution/_search?size=0` (full `fetchLatestAssets()` agg) | as C4 — 3 000 buckets, ~10–20 MB response | **1–5 s** (same prime-suspect call as C4) |
| D2 | `POST /.kibana_alerting_cases/_search?size=1` (`findRules` `immutable: false`) | as B2; 0 hits (we only installed immutable rules) | 10–30 ms |
| D3 | `POST /.kibana_alerting_cases/_search?size=10000` (`getExistingPrepackagedRules`) | as B3; now returns **3 000 alert SOs** (~2–6 KB each, ~10 MB response) | 100–500 ms |
| D4 | `POST /.kibana/_search?size=10000` (`checkTimelinesStatus`) | as B4 | 10–40 ms |
| D5 | `POST /.kibana*/_refresh` + `POST /.kibana*/_cache/clear` (×2, from the helper) | none | ~150–400 ms |

**Phase D subtotal: ~1.5–6 s.**

### Roll-up

| Phase | Calls per iteration | Expected ES wall-clock (good snapshot) |
|---|---|---|
| A — `beforeEach` | ~50–200 (mostly Fleet fan-out) | 2–6 s |
| B — `_status` pre-install | 4 | 50–200 ms |
| C — `PUT prepackaged` install | ~3 050 (3 000 of them are C6) | 25–35 s |
| D — `_status` post-install | 5 | 1.5–6 s |
| **Total** | **~3 100** | **~30–45 s** (matches observed ~30 s `it` runtime) |

### Where the time most plausibly leaks on the bad snapshot

Two calls dominate the budget and are the only places a single-call slowdown can credibly cost the ≥ 330 s the test loses:

1. **C6 (`_create alert` × 3 000 with `refresh=wait_for`)** — anything that lengthens the per-write critical path (translog fsync, refresh, validation, mapping update, security/audit) by even 30–50 ms per write turns the ~15 s budget into >300 s at concurrency 20.
2. **C4 / D1 (`terms` + `top_hits` agg on `.kibana_security_solution`)** — a regression in terms/top_hits or in the underlying doc-values reads on a 30 000-doc system index could push these from ~1–5 s to tens of seconds each, repeated 2× (C4 + D1, plus the smaller C2 and B1 variants).

C3 (Fleet bulk SO install) is also a candidate (~10–20 s of writes against `.kibana_security_solution`), but its dominant primitive is `_bulk` with the SO `bulk_create` chunker, so a regression there should affect a much wider set of Kibana ESS tests — making C4/D1 (aggregation regression) or C6 (single-doc `_create` with `refresh=wait_for`) the more parsimonious explanations for a regression that only this test trips so hard.

---

## HAR captures of Kibana → ES traffic

Two scrubbed HAR captures of the Kibana → Elasticsearch wire traffic for one full iteration of the test are committed next to this report:

| File | Size | HAR entries (`log.entries.length`) | Test outcome |
| --- | --- | --- | --- |
| [`may11.scrubbed.har.zip`](./may11.scrubbed.har.zip) | 8.3 MB zipped (283 MB raw) | **24 048** | passes in ~38 s |
| [`may12.scrubbed.har.zip`](./may12.scrubbed.har.zip) | 2.4 MB zipped (72 MB raw)  | **1 520**  | times out at 360 s |

### How they were captured

A reverse-proxy mitmdump was inserted between Kibana and Elasticsearch:

- ES kept running on `:9220` (FTR default), under HTTPS with the FTR self-signed cert.
- `mitmdump --mode reverse:https://localhost:9220 --listen-port 9221 --ssl-insecure --set http2=false --set hardump=<path>.har` listened on `:9221` and forwarded to `:9220`.
- Kibana was pointed at `https://localhost:9221` with `--elasticsearch.ssl.verificationMode=none`, leaving the FTR `es` service still talking to `:9220` directly (so direct ES calls made by FTR helpers do *not* appear in these HARs — only the calls Kibana itself makes).
- During Kibana startup, mitmdump ran with `hardump` unset, then was `SIGINT`ed and restarted with `--set hardump=...` immediately before launching the FTR runner. This deliberately excludes Kibana startup / plugin bootstrap traffic from the capture so the file represents only the test iteration. Each capture covers exactly one `it('should install a package containing 15000 prebuilt rules without crashing')` execution including its `beforeEach` / `afterEach` hooks.
- mitmdump flushes the HAR on `SIGINT`. Both files were then run through `./scrub_har.py` (in this same folder) which redacts `Authorization` header values and removes `traceparent` / `tracestate` headers (everything else, including timings, URLs, payloads, response bodies, is preserved). Finally `zip` was used since HAR JSON compresses ~35×.

The plumbing for re-capturing these is in-tree and disabled-only:

- `x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/configs/edge_cases/ess_air_gapped_with_bundled_large_package.proxied.config.ts` — a thin wrapper config that filters out the inherited `--elasticsearch.hosts=...` arg and re-adds it pointing at `https://localhost:${ES_PROXY_PORT:-19220}`.
- Listed under `disabled:` in `.buildkite/ftr-manifests/ftr_security_stateful_configs.yml` so `functional_tests_server` will load it locally but it never runs on CI.

### What the entry counts already tell us

**1 520 entries vs 24 048 entries in the same 6-minute wall-clock window is a ~16× reduction in completed Kibana → ES round-trips.** mitmdump only emits a HAR entry when the *response* is received, so any request still in-flight when the timeout fires (and mitm is killed) is silently dropped from the file. That makes the May 12 HAR a snapshot of "everything Kibana managed to actually finish talking to ES about before the test was killed".

This is consistent with the C6 + C4/D1 hypothesis above and is *inconsistent* with a uniform per-request slowdown:

- A uniform 10–20× per-call slowdown would give us roughly the same number of entries, just with each entry's `time` field much larger.
- A small number of long-pole calls hanging for tens of seconds each, holding up the remainder, would give us **far fewer** completed entries — which is what we see.

The most likely "long pole" candidates are still the same two from the wire-level analysis above:

1. **C6** — `_create alert` × 3 000 with `refresh=wait_for`. If a handful of these stall at the refresh step or the security/audit pipeline, the `initPromisePool(concurrency=20)` wave queues up behind them and no further C6 entries land in the HAR.
2. **C4 / D1** — `terms` + `top_hits` aggregation on `.kibana_security_solution`. If this single call goes from ~1–5 s to >360 s, the test never even gets to start C6, and the HAR would only contain phases A + B + the front portion of C up to the hung agg.

The exact shape of the May 12 HAR (does it include any C6 entries at all? does C4 appear with a `time` close to 360 000 ms?) immediately distinguishes between these two hypotheses.

### Suggested analysis pass on the HARs

Quick ways to extract the diagnostic signal without loading the full file into a browser (the raw 283 MB May 11 HAR will stall most HAR viewers — work with the scrubbed zips or unzip into a tmp dir):

```bash
# Unzip into a scratch dir (raw .har is .gitignored)
mkdir -p .knowledge/reports/es-snapshot-verify/har && \
  unzip -p .knowledge/reports/es-snapshot-verify/may12.scrubbed.har.zip > \
            .knowledge/reports/es-snapshot-verify/har/may12.scrubbed.har

# Top 20 slowest requests with method + URL
jq -r '.log.entries
  | sort_by(-.time)
  | .[0:20]
  | .[]
  | "\(.time | tostring | .[:8])ms  \(.request.method) \(.request.url)"' \
  .knowledge/reports/es-snapshot-verify/har/may12.scrubbed.har

# Count requests by method + URL-stem (drop query strings + numeric ids)
jq -r '.log.entries
  | map(.request.url
        | sub("\\?.*$"; "")
        | sub("/[0-9a-f]{8}-[0-9a-f-]+"; "/{uuid}")
        | sub("/_create/[a-z\\-]+:.*$"; "/_create/{soid}"))
  | group_by(.)
  | map({ url: .[0], count: length })
  | sort_by(-.count)
  | .[]
  | "\(.count)  \(.url)"' \
  .knowledge/reports/es-snapshot-verify/har/may12.scrubbed.har

# Show the timing of the LAST entry in the bad-run HAR (i.e. the last thing Kibana
# heard back from ES before the test gave up):
jq '.log.entries[-1] | { time: .time, method: .request.method, url: .request.url, status: .response.status }' \
  .knowledge/reports/es-snapshot-verify/har/may12.scrubbed.har
```

The same queries run against `may11.scrubbed.har` give the baseline shape; diffing the top-slowest lists between the two HARs is the most direct way to pin the regressing ES call.

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
lsof -i :9220 -i :5620 -i :9221 -n -P | awk 'NR>1 && /LISTEN/ {print $2}' | xargs -r kill -9
ps -ef | grep -E 'cluster-ftr|controller.app|functional_tests_server' | grep -v grep | awk '{print $2}' | xargs -r kill -9
```

### Re-capturing a HAR (Kibana → ES traffic via mitmdump)

Three terminals: mitm, FTR server, FTR runner. Replace the manifest URL to flip snapshots; everything else stays identical.

```bash
# === Terminal A (mitm warm-up; NOT recording yet) ===
# Lets Kibana boot and talk to ES, but does not pollute the HAR with startup traffic.
mitmdump \
  --mode reverse:https://localhost:9220 \
  --listen-port 9221 \
  --ssl-insecure \
  --set http2=false \
  --set flow_detail=0 \
  -q

# === Terminal B (FTR server, proxied) ===
export ES_SNAPSHOT_MANIFEST="https://storage.googleapis.com/kibana-ci-es-snapshots-daily/9.5.0/archives/20260511-022512_32342fb5/manifest.json"   # or the 12 May URL
export NODE_OPTIONS=--max-old-space-size=8192
export ES_PROXY_PORT=9221
node scripts/functional_tests_server \
  --config x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/configs/edge_cases/ess_air_gapped_with_bundled_large_package.proxied.config.ts
# Wait for: [INFO ][status] Kibana is now available

# === Back to Terminal A — Ctrl-C, then relaunch WITH HAR capture ===
# Kibana's ES client will reconnect through the new mitm within ~1 s.
mitmdump \
  --mode reverse:https://localhost:9220 \
  --listen-port 9221 \
  --ssl-insecure \
  --set http2=false \
  --set flow_detail=0 \
  --set hardump=$PWD/.knowledge/reports/es-snapshot-verify/may11.har \
  -q

# === Terminal C (runner — uses the proxied config so the URL discovery matches) ===
export NODE_OPTIONS=--max-old-space-size=8192
time node scripts/functional_test_runner \
  --bail \
  --config x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/configs/edge_cases/ess_air_gapped_with_bundled_large_package.proxied.config.ts

# When the runner finishes (pass or timeout):
#   1. Ctrl-C terminal A — mitmdump flushes the HAR on SIGINT.
#   2. Scrub + zip:
python3 .knowledge/reports/es-snapshot-verify/scrub_har.py \
  .knowledge/reports/es-snapshot-verify/may11.har
zip -j .knowledge/reports/es-snapshot-verify/may11.scrubbed.har.zip \
       .knowledge/reports/es-snapshot-verify/may11.scrubbed.har
rm .knowledge/reports/es-snapshot-verify/may11.har \
   .knowledge/reports/es-snapshot-verify/may11.scrubbed.har
```
