# `kibana-elasticsearch-snapshot-verify` — change history system data stream test failures

**Date:** 2026-07-21  
**Pipeline:** [`kibana-elasticsearch-snapshot-verify`](https://buildkite.com/elastic/kibana-elasticsearch-snapshot-verify)  
**Branch / checkout:** `main` on `kibana-5th`  
**ES under test:** unverified daily snapshot `9.6.0-SNAPSHOT` (`20260721-022000_899296de`)

**Related:** [.knowledge/reports/kibana-change-history-system-datastream.md](./kibana-change-history-system-datastream.md) (incident-3371 — ES registered `.kibana_change_history` as a system data stream). This report covers **verify-pipeline test failures** that showed up once that ES change landed in the daily unverified snapshot. Kibana itself starts and runs against this snapshot; the breakage is in CI tests, not the product boot path.

---

## Summary

Elasticsearch [#154113](https://github.com/elastic/elasticsearch/pull/154113) registered `.kibana_change_history` as a `SystemDataStreamDescriptor`. On the unverified daily ES snapshot, create/access without system/product-origin privileges is rejected:

```
illegal_argument_exception: Data stream(s) [.kibana_change_history] use and access is reserved for system operations
```

That error fails Jest integration and FTR tests in `kibana-elasticsearch-snapshot-verify`.

**Important:** Kibana started locally against the same snapshot does **not** fail. Using `asInternalUser` (product-origin path), change tracking initializes, creates the stream, and writes history successfully. This is a **test-client / privilege** mismatch with the new system data stream, not a Kibana startup regression.

---

## Kibana starts fine locally (same failing snapshot)

Verified 2026-07-21 on `kibana-5th` against the unverified ES build that breaks the tests (`899296de…`). ES was started as:

```bash
KBN_ES_SNAPSHOT_USE_UNVERIFIED=1 yarn es snapshot --license trial \
  -E xpack.security.authc.api_key.enabled=true \
  -E path.data=(local data path) \
  -E http.port=9204 \
  -E transport.port=9304
```

| Check | Result |
|---|---|
| Kibana status | `available` — “All services and plugins are available” |
| Change tracking init | Succeeded (`Change tracking initialized for [security, alerting-rules]`) |
| Data stream after boot | Exists, `"system": true`, GREEN |
| Runtime writes | Observed (`Logged 20 change/s to history stream…`) |

### Boot logs (same run)

No change-history / `reserved for system` errors in ES or Kibana. Unrelated noise only: reserved `viewer`/`editor` roles skipped in `roles.yml`; ELSER scale/download hiccups; workflows rollover `index_not_found` on `.workflows-events` / `.workflows-execution-data-stream-logs` (sibling system DSs); Fleet GPG / sample-data import conflicts; cold-start event-loop warnings.

---

## Failing tests

### Confirmed same root cause (reproduced locally with `KBN_ES_SNAPSHOT_USE_UNVERIFIED=1`)

#### Jest Integration — `kbn-change-history`

Config: `x-pack/platform/packages/shared/kbn-change-history/jest.integration.config.js`  
File: `integration_tests/client.test.ts`

| Test | Local |
|---|---|
| `ChangeHistoryClient › initialize › should initialize the data stream` | ❌ |
| `ChangeHistoryClient › initialize › enrolls the data stream in DSL lifecycle without ILM or data_retention` | ❌ |
| `ChangeHistoryClient › log and getHistory › should log one change and return it via getHistory` | ❌ |
| `ChangeHistoryClient › logBulk and getHistory › should log multiple changes…` | ❌ |
| `ChangeHistoryClient › logBulk and getHistory › should not throw on partial success…` | ❌ |
| `ChangeHistoryClient › masking selected fields › should hash and redact…` | ❌ |

Passed (no ES create): invalid module/dataset; log/getHistory before initialize (3 tests).

These fail because the Jest ES test-cluster client calls `createDataStream` without system/product-origin access.

#### FTR — Rules Management change history

| CI job | Test | Config / file | Local |
|---|---|---|---|
| FTR Configs #70 | `history API returns the rule_create record for a newly-created rule` | `…/configs/ess.config.ts` → `change_tracking.ts` | ❌ |
| FTR Configs #182 | `writes no records to the change history data stream on rule create` (setting disabled) | `…/configs/ess.rule_changes_history_disabled.config.ts` → `change_tracking_disabled.ts` | ❌ |

Both failed with the same reserved-system-operations error.

**FTR #182 note:** This is not a “writes when it shouldn’t” assertion miss. Rule create succeeds; the test then hits `.kibana_change_history` via the FTR ES client (`refresh` / `count`, after optional `deleteByQuery` in `clearHistory`). That client call is what ES rejects.

### Likely unrelated (not investigated / not reproduced)

- FTR Configs #75 — CSP graph visualization expanded flyout filter by node
- Scout Lane #1 — Discover tabs sharing unsaved tab

Treat as noise unless they persist after the change-history test fix.

---

## Root cause

### What changed in ES

[elasticsearch#154113](https://github.com/elastic/elasticsearch/pull/154113) (merged 2026-07-16, in 9.5.1 / 9.6.0 snapshots):

- Registers `.kibana_change_history` as `SystemDataStreamDescriptor` (`Type.EXTERNAL`) in `KibanaPlugin`
- Ships composable template from `modules/kibana/.../kibana-change-history.json`
- Narrows the broad `.kibana_*` system index descriptor so it no longer overlaps the data stream
- Mirrors the workflows pattern from [elasticsearch#145822](https://github.com/elastic/elasticsearch/pull/145822)

Review feedback on that PR called out removing competing template installation from Kibana once ES owns the descriptor. Kibana’s privileged boot path still succeeds today; the pain is mainly tests (and any non-product-origin clients).

### What `ChangeHistoryClient` does today

Current `initialize` in `x-pack/platform/packages/shared/kbn-change-history/src/client.ts` (no ILM):

1. Builds a `DataStreamDefinition` for `.kibana_change_history` (version `3`, `hidden: true`, **DSL lifecycle** `lifecycle: { enabled: true }` — infinite retention by default)
2. Calls `DataStreamClient.initialize({ lazyCreation: false })` → puts index template + `indices.createDataStream`

There is **no** `ensureIlmPolicy` / ILM policy install in this client. Lifecycle is DSL only.

Against the new snapshot:

- **Kibana `asInternalUser`:** create/init succeeds (observed locally).
- **Jest / FTR ES clients** without product-origin / system privileges: `createDataStream` (Jest) or `refresh` / `count` / `deleteByQuery` (FTR) hit `reserved for system operations`.

### Why promoted/local default ES often looked fine before

`@kbn/es` defaults to `manifest-latest-verified.json`. Verify runs against the **unverified** daily build (`manifest-latest.json` / `KBN_ES_SNAPSHOT_USE_UNVERIFIED=1`). Until verify goes green and promote runs, a default local `yarn es snapshot` can still be on a pre-#154113 (or older verified) build — or, once on the new snapshot, Kibana still boots while only the tests fail.

---

## How to reproduce

All local repros used the **unverified** daily ES snapshot (same class of artifact as `kibana-elasticsearch-snapshot-verify`), not the promoted/verified one.

### Key env var

```bash
export KBN_ES_SNAPSHOT_USE_UNVERIFIED=1
```

This makes `@kbn/es` fetch:

`https://storage.googleapis.com/kibana-ci-es-snapshots-daily/<kibana-version>/manifest-latest.json`

instead of `manifest-latest-verified.json`.

Optional — pin the exact build from a failing verify job:

```bash
export ES_SNAPSHOT_MANIFEST='https://storage.googleapis.com/kibana-ci-es-snapshots-daily/9.6.0/archives/<id>/manifest.json'
```

(When set, `ES_SNAPSHOT_MANIFEST` wins over the unverified/verified latest URLs.)

The snapshot we hit on 2026-07-21:

- Version: `9.6.0-SNAPSHOT`
- Archive: `20260721-022000_899296de`
- URL used by `@kbn/es`:  
  `https://storage.googleapis.com/kibana-ci-es-snapshots-daily/9.6.0/manifest-latest.json`  
  → `.../archives/20260721-022000_899296de/elasticsearch-9.6.0-SNAPSHOT-darwin-aarch64.tar.gz`

### Start Elasticsearch + Kibana locally (product path — should succeed)

`kibana-5th` ports from `elastic.zsh` (`start-ces` / `start-kibana` shape), with unverified snapshot:

```bash
# Clean data dir (start-ces) then start ES with unverified snapshot
export KBN_ES_SNAPSHOT_USE_UNVERIFIED=1
rm -rf (local data path)

yarn es snapshot --license trial \
  -E xpack.security.authc.api_key.enabled=true \
  -E path.data=(local data path) \
  -E http.port=9204 \
  -E transport.port=9304
```

```bash
# start-kibana equivalent — point at that ES
yarn start \
  --server.basePath="/kbn" \
  --elasticsearch.hosts="http://localhost:9204" \
  --server.port=5605 \
  --dev.basePathProxyTarget=5615
```

Expect Kibana **available** at http://localhost:5605/kbn and change history usable in the UI.

Generic one-off ES (no custom data dir):

```bash
KBN_ES_SNAPSHOT_USE_UNVERIFIED=1 \
  node scripts/es snapshot \
  --license=trial \
  --port 9200
```

### Run the failing Jest suite

ES is started automatically by `createTestEsCluster` (install path `.es/es-test-cluster`, HTTP `9220` in our run).

```bash
# Full suite — 6 failures matching CI Jest Integration #21
KBN_ES_SNAPSHOT_USE_UNVERIFIED=1 \
  node scripts/jest_integration \
  x-pack/platform/packages/shared/kbn-change-history/integration_tests/client.test.ts

# Single test (faster smoke)
KBN_ES_SNAPSHOT_USE_UNVERIFIED=1 \
  node scripts/jest_integration \
  x-pack/platform/packages/shared/kbn-change-history/integration_tests/client.test.ts \
  --testNamePattern="should initialize the data stream"
```

### Run the failing FTR tests

FTR starts its own ES (`cluster-ftr` on `9220` with HTTP SSL) and Kibana on `5620`. Same unverified env var.

```bash
CONFIG_DIR=x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/rule_management/trial_license_complete_tier/configs

# FTR Configs #182 — disabled setting / no writes
KBN_ES_SNAPSHOT_USE_UNVERIFIED=1 \
  node scripts/functional_tests \
  --config "$CONFIG_DIR/ess.rule_changes_history_disabled.config.ts" \
  --grep "writes no records to the change history data stream on rule create" \
  --bail

# FTR Configs #70 — history API returns rule_create
KBN_ES_SNAPSHOT_USE_UNVERIFIED=1 \
  node scripts/functional_tests \
  --config "$CONFIG_DIR/ess.config.ts" \
  --grep "returns the rule_create record for a newly-created rule" \
  --bail
```

FTR CLI args used:

| Arg | Purpose |
|---|---|
| `--config <file>` | Leaf FTR config (starts ES + Kibana + suite) |
| `--grep "<name>"` | Run only the named test |
| `--bail` | Stop on first failure |

Without `KBN_ES_SNAPSHOT_USE_UNVERIFIED=1`, these commands use the **promoted** snapshot and may pass even while verify is red.

---

## Suggested fix

Focus on **tests and any non-privileged clients**. Kibana’s internal boot path already works against this snapshot.

### 1. Jest integration suite

- Give the test ES client product-origin / system access equivalent to Kibana’s internal user, **or**
- Stop asserting “create from nothing” with a plain client; attach/`fromDefinition` + write/read once a privileged setup exists
- Teardown: clear docs; don’t `deleteDataStream` / `deleteIndexTemplate` without system privileges

### 2. FTR helpers

In `change_tracking.ts` / `change_tracking_disabled.ts`:

- Use a privileged/system client (or `X-Elastic-Product-Origin: kibana`) for any direct ops on `.kibana_change_history`
- Prefer document-level cleanup over deleting the stream/template
- Keep `ignore_unavailable` where appropriate

### 3. Optional Kibana ownership cleanup (longer term)

ES now ships the system descriptor/template. Over time, Kibana may stop competing on template/create and only attach + write via `asInternalUser`. Current client already uses **DSL lifecycle** (not ILM); keep that model aligned with the ES-shipped template. Not required to explain today’s “Kibana won’t start” (it does start).

### 4. Out of scope

CSP #75 and Scout Discover share — leave alone unless they remain red after the above.

---

## Expected outcome

After Jest/FTR talk to the system data stream with the right privileges (and/or stop creating it as a normal user):

- 6 Jest integration failures → green
- FTR #70 and #182 → green
- Snapshot verify can promote again for branches consuming this ES commit
- Kibana local boot remains green (already is)

---

## Links

- ES registration PR: https://github.com/elastic/elasticsearch/pull/154113
- Precedent (workflows system DS): https://github.com/elastic/elasticsearch/pull/145822
- Kibana client: `x-pack/platform/packages/shared/kbn-change-history/src/client.ts`
- Jest suite: `x-pack/platform/packages/shared/kbn-change-history/integration_tests/client.test.ts`
- FTR enabled: `…/change_tracking.ts`
- FTR disabled: `…/change_tracking_disabled.ts`
- Prior incident write-up: `.knowledge/reports/kibana-change-history-system-datastream.md`
