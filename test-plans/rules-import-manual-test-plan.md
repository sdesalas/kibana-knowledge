# Rules `_import` API — manual test plan

End-to-end coverage of the `POST /api/detection_engine/rules/_import` endpoint,
run against a local Kibana wired to a local Elasticsearch. Designed to be
executed by an agent (or a human) with a shell.

The plan targets the post-refactor code path where:

- `logic/import/import_rules.ts` chunks at `RULE_IMPORT_BULK_CREATE_BATCH_SIZE`
  and calls `detectionRulesClient.importRules` (bulk).
- `logic/detection_rules_client/methods/import_rules.ts` runs
  `fetchPrebuiltImportContext` + `prepareRules` + `overwriteExisting` +
  `buildBulkInputs`.
- The route (`api/rules/import_rules/route.ts`) owns the full `changeTracking`
  payload and calls `ensureLatestRulesPackageInstalled` once per request.

## 0. Prereqs

- `curl`, `python3` and `jq` on `PATH`.
- `nvm` available and the repo `.nvmrc` node version installed.
- The shell aliases `start-cbes` and `start-kibana` available in the user's zsh
  environment. If they aren't, replace them with the inlined commands below.

### Three-terminal setup

The agent runs **three long-lived terminals** in parallel. All three stay
open for the whole session.

**Terminal 1 — clean ES (background).** Runs `start-cbes`, which is
`clean-es-data && start-bootstrap && start-es`. This:

1. Wipes `$ES_DATA_HOME` (guarantees a clean cluster — no leftover rules,
   saved objects, tasks, api keys from prior runs).
2. Re-bootstraps Kibana deps (`yarn kbn bootstrap` + build platform plugins).
3. Boots an ES snapshot on `${ES_DEV_PORT:-9200}` with trial licence and API
   keys enabled.

Inline equivalent (if the alias isn't available):

```bash
rm -rf "${ES_DATA_HOME:?}"/* && \
NODE_OPTIONS="--max_old_space_size=8192" yarn kbn bootstrap && \
NODE_OPTIONS="--max_old_space_size=8192" node scripts/build_kibana_platform_plugins && \
yarn es snapshot --license trial \
  -E xpack.security.authc.api_key.enabled=true \
  -E path.data="${ES_DATA_HOME}" \
  -E http.port="${ES_DEV_PORT:-9200}" \
  -E transport.port="${ES_TRANSPORT_PORT:-9300}"
```

Wait until ES is ready before starting Kibana. This is ready when the ES
log prints `started` and `/_cluster/health` responds `green` or `yellow`:

```bash
until curl -sS -u elastic:changeme "http://localhost:${ES_DEV_PORT:-9200}/_cluster/health" \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("status",""))' \
  | grep -Eq '^(green|yellow)$'; do
  sleep 5
done
echo "ES ready"
```

Cold `start-cbes` typically takes several minutes on first run (bootstrap
downloads + platform plugin build). Subsequent restarts are much faster
because bootstrap short-circuits when dependencies haven't changed.

**Terminal 2 — Kibana (background).** After ES is ready, runs `start-kibana`,
which is:

```bash
yarn start \
  --server.basePath="/kbn" \
  --elasticsearch.hosts="http://localhost:${ES_DEV_PORT:-9200}" \
  --server.port="${KIBANA_DEV_PORT:-5601}" \
  --dev.basePathProxyTarget="${KIBANA_PROXY_PORT:-5611}"
```

Wait until Kibana reports `available`:

```bash
until curl -sS -u elastic:changeme "http://localhost:${KIBANA_DEV_PORT:-5601}/kbn/api/status" \
  | python3 -c 'import json,sys;
try:
  d=json.load(sys.stdin);print(d["status"]["overall"]["level"])
except Exception:
  print("boot")' \
  | grep -q '^available$'; do
  sleep 5
done
echo "Kibana ready"
```

Cold Kibana boot is 60–120s after bootstrap has already run.

**Terminal 3 — test runner (foreground).** All commands in sections 1–6 of
this plan run here. This terminal does not need to stay in the repo root but
all paths below are relative to it.

### Ports

Defaults from the repo shell env are `KIBANA=5601`, `ES=9200`. If you use
custom ports, set `KIBANA_DEV_PORT` / `ES_DEV_PORT` in all three terminals
**before** starting anything, and mirror them in section 1's `export` block.

## 1. Environment

Export these once at the top of the session — everything below reuses them:

```bash
export KB="${KB:-http://localhost:5601/kbn}"
export AUTH="${AUTH:-elastic:changeme}"
export KBN_VERSION="${KBN_VERSION:-9.6.0}"      # NOT the SNAPSHOT tag; that gets 400
export ES_URL="${ES_URL:-http://localhost:9200}"
export DATA=".knowledge/data/rules-import"

# Also needed by the two check-*.sh scripts (they read the un-prefixed vars)
export KIBANA_DEV_PORT="${KIBANA_DEV_PORT:-5601}"
export ES_DEV_PORT="${ES_DEV_PORT:-9200}"
```

Smoke-check they answer before starting:

```bash
curl -sS -u "$AUTH" -H 'kbn-xsrf: true' "$KB/api/status" \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print("kibana:",d["status"]["overall"]["level"],"|",d.get("version",{}).get("number"))'
curl -sS -u "$AUTH" "$ES_URL/_cluster/health" \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print("es:",d["status"],"nodes:",d["number_of_nodes"])'
ls -la "$DATA" | head
```

Expect: `kibana: available` and `es: green|yellow`.

## 2. Runner helper (inline)

Drop this into `/tmp/kbn_test_import.sh`. It does three things:

- `delete` — bulk-deletes all custom rules (KQL `query=""`).
- `import LABEL FILE [OVERWRITE]` — POSTs the ndjson to `_import` and prints
  `success_count`, `errors[]` (first 3), `exceptions_*`, `action_connectors_*`.
- `reset-and-import LABEL FILE [OVERWRITE]` — delete → 2s pause → import.

```bash
cat > /tmp/kbn_test_import.sh << 'EOF'
#!/usr/bin/env bash
# Usage: kbn_test_import <delete|import LABEL FILE [OVERWRITE]|reset-and-import LABEL FILE [OVERWRITE]>
set -u
KB="${KB:-http://localhost:5601/kbn}"
AUTH="${AUTH:-elastic:changeme}"
KBN_VERSION="${KBN_VERSION:-9.6.0}"

_delete_all() {
  local body
  body=$(curl -sS -u "$AUTH" \
    -H 'kbn-xsrf: true' -H 'content-type: application/json' \
    -H 'elastic-api-version: 2023-10-31' -H "kbn-version: $KBN_VERSION" \
    -X POST "$KB/api/detection_engine/rules/_bulk_action?dry_run=false" \
    --data '{"action":"delete","query":""}')
  local total
  total=$(echo "$body" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("attributes",{}).get("summary",{}).get("total","?"))' 2>/dev/null)
  echo "  deleted: total=$total"
}

_import() {
  local label="$1"; local file="$2"; local overwrite="${3:-false}"
  local qs="overwrite=${overwrite}&overwrite_exceptions=${overwrite}&overwrite_action_connectors=${overwrite}"
  local out; out=$(mktemp)
  local t0; t0=$(python3 -c 'import time;print(time.time())')
  local http; http=$(curl -sS -o "$out" -w '%{http_code}' -u "$AUTH" \
    -H 'kbn-xsrf: true' -H 'elastic-api-version: 2023-10-31' -H "kbn-version: $KBN_VERSION" \
    -X POST "$KB/api/detection_engine/rules/_import?$qs" \
    -F "file=@${file};type=application/x-ndjson")
  local t1; t1=$(python3 -c 'import time;print(time.time())')
  local elapsed; elapsed=$(python3 -c "print(f'{${t1}-${t0}:.2f}')")
  python3 - "$out" << 'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"  parse_err: {e}"); sys.exit(0)
if 'success_count' in d:
    errs = d.get('errors', [])
    line = f"  success_count={d.get('success_count')} errors={len(errs)} rules_count={d.get('rules_count','?')}"
    if 'exceptions_success_count' in d:
        line += f" exceptions_success={d['exceptions_success_count']} exceptions_errors={len(d.get('exceptions_errors',[]))}"
    if 'action_connectors_success_count' in d:
        line += f" ac_success={d['action_connectors_success_count']} ac_errors={len(d.get('action_connectors_errors',[]))}"
    print(line)
    for e in errs[:3]:
        rid = e.get('rule_id') or e.get('id') or '?'
        msg = (e.get('error',{}).get('message') or e.get('message') or '')[:200]
        code = e.get('error',{}).get('status_code') or e.get('status_code')
        print(f"    err rule_id={rid} status={code} msg={msg}")
    if len(errs) > 3:
        print(f"    ... and {len(errs)-3} more errors")
else:
    print(f"  raw: {json.dumps(d)[:400]}")
PY
  echo "[$label] HTTP $http in ${elapsed}s overwrite=$overwrite file=$(basename "$file")"
  rm -f "$out"
}

case "${1:-run}" in
  delete) _delete_all ;;
  import) shift; _import "$@" ;;
  reset-and-import) shift; _delete_all; sleep 2; _import "$@" ;;
  *) echo "usage: $0 {delete|import LABEL FILE [OVERWRITE]|reset-and-import LABEL FILE [OVERWRITE]}" ;;
esac
EOF
chmod +x /tmp/kbn_test_import.sh
```

## 3. Test files (`.knowledge/data/rules-import/`)

Each ndjson file is one line per object. The last line is a `{ "exported_count": N, ... }`
summary. File name encodes the fixture. Sizes range from 1 rule to 1000 rules.

Files exercised by this plan (relative to repo root):

- `.knowledge/data/rules-import/1rule.custom.ndjson`
- `.knowledge/data/rules-import/100disabled-rules.ndjson`
- `.knowledge/data/rules-import/100enabled-rules.ndjson`
- `.knowledge/data/rules-import/100rules.ndjson`
- `.knowledge/data/rules-import/500rules.ndjson`
- `.knowledge/data/rules-import/500enabled-rules.ndjson`
- `.knowledge/data/rules-import/1000rules.ndjson`
- `.knowledge/data/rules-import/10rules.1x.error.missingVersion.ndjson`
- `.knowledge/data/rules-import/2rules.1x.error.minimumScheduleInterval.ndjson`
- `.knowledge/data/rules-import/2rules.1x.error.schemaValidation.ndjson`
- `.knowledge/data/rules-import/2rules.error.duplicateRuleId.ndjson`
- `.knowledge/data/rules-import/1rule.error.missingConnector.ndjson`
- `.knowledge/data/rules-import/1rule.error.mlAuth.ndjson`
- `.knowledge/data/rules-import/1rule+1exceptionlist(ownexceptions).ndjson`
- `.knowledge/data/rules-import/1rule+2exceptionlist(own.and.shared).ndjson`
- `.knowledge/data/rules-import/1rule+3actionconnectors.ndjson`

The full inventory (including 4000, 6000, 12000 rule internal-format files) is
under `.knowledge/data/rules-import/` — see also
`.knowledge/scripts/bulk-create/parallel_import_rules.sh` for the cURL shape
this plan mirrors.

## 4. The 18 tests

Each row: run the command, check the row's "Expect" column matches. HTTP 200
is expected even when rules fail — per-rule failures live inside
`errors[]` / `exceptions_errors[]` / `action_connectors_errors[]`.

### 4.1 Functional matrix (T1–T17)

| # | Command | Expect |
|---|---|---|
| T1 | `/tmp/kbn_test_import.sh reset-and-import T1 "$DATA/1rule.custom.ndjson"` | `success_count=1 errors=0` |
| T2 | `/tmp/kbn_test_import.sh reset-and-import T2 "$DATA/100disabled-rules.ndjson"` | `success_count=100 errors=0` |
| T3 | `/tmp/kbn_test_import.sh reset-and-import T3 "$DATA/100enabled-rules.ndjson"` | `success_count=100 errors=0` |
| T4 | `/tmp/kbn_test_import.sh reset-and-import T4 "$DATA/100rules.ndjson"` | `success_count=100 errors=0` |
| T5 | `/tmp/kbn_test_import.sh reset-and-import T5a "$DATA/100rules.ndjson"`<br>`/tmp/kbn_test_import.sh import T5b "$DATA/100rules.ndjson" true` | 2nd: `success_count=100 errors=0` (overwrite via `pMap`) |
| T6 | `/tmp/kbn_test_import.sh reset-and-import T6a "$DATA/100rules.ndjson"`<br>`/tmp/kbn_test_import.sh import T6b "$DATA/100rules.ndjson" false` | 2nd: `success_count=0 errors=100`, each `status=409 msg=Rule with this rule_id already exists` |
| T7 | `/tmp/kbn_test_import.sh reset-and-import T7 "$DATA/500rules.ndjson"` | `success_count=500 errors=0` (5-chunk) |
| T8 | `/tmp/kbn_test_import.sh reset-and-import T8 "$DATA/1000rules.ndjson"` | `success_count=1000 errors=0` (10-chunk) |
| T9 | `/tmp/kbn_test_import.sh reset-and-import T9 "$DATA/10rules.1x.error.missingVersion.ndjson"` | `success_count=9 errors=1`, msg contains `must specify a "version"` |
| T10 | `/tmp/kbn_test_import.sh reset-and-import T10 "$DATA/2rules.1x.error.minimumScheduleInterval.ndjson"` | `success_count=1 errors=1`, msg contains `interval is less than the allowed minimum interval` |
| T11 | `/tmp/kbn_test_import.sh reset-and-import T11 "$DATA/2rules.1x.error.schemaValidation.ndjson"` | `success_count=1 errors=1`, msg contains `risk_score` |
| T12 | `/tmp/kbn_test_import.sh reset-and-import T12 "$DATA/2rules.error.duplicateRuleId.ndjson"` | `success_count=1 errors=1`, msg contains `More than one rule with rule-id` |
| T13 | `/tmp/kbn_test_import.sh reset-and-import T13 "$DATA/1rule.error.missingConnector.ndjson"` | `success_count=0 errors=1`, `status=404 msg=Rule actions reference the following missing action IDs` |
| T14 | `/tmp/kbn_test_import.sh reset-and-import T14 "$DATA/1rule.error.mlAuth.ndjson"` | Best-effort: `success_count=1` on a stack without ML licence enforcement; on a real ML stack expect a per-rule ML-authz error. |
| T15 | `/tmp/kbn_test_import.sh reset-and-import T15 "$DATA/1rule+1exceptionlist(ownexceptions).ndjson"` | `success_count=1 exceptions_success=1 exceptions_errors=0` |
| T16 | `/tmp/kbn_test_import.sh reset-and-import T16 "$DATA/1rule+2exceptionlist(own.and.shared).ndjson" true` | `success_count=1 exceptions_success=2 exceptions_errors=0` (use `overwrite=true` — otherwise leftover exception SOs from earlier tests will show as `exceptions_errors`) |
| T17 | `/tmp/kbn_test_import.sh reset-and-import T17 "$DATA/1rule+3actionconnectors.ndjson" true` | `success_count=1 ac_success>=1 ac_errors=0` |

### 4.2 Post-import invariants — check-tasks.sh (T18)

Verifies the whole point of the bulk-create refactor: for enabled rules,
`bulkCreateRules` mints the encrypted API key **and** schedules the task
manager entry inline. All five numbers must line up.

Script location: `.knowledge/scripts/check-tasks.sh` (reads `KIBANA_DEV_PORT`
and `ES_DEV_PORT` from env; defaults to 5601 / 9200).

Inlined for the impatient (identical to the script on disk):

```bash
KIBANA_URL="http://localhost:${KIBANA_DEV_PORT:-5601}/kbn"
ES_URL="http://localhost:${ES_DEV_PORT:-9200}"
AUTH="elastic:changeme"

# security-solution alerting rules visible to Kibana
rules_json=$(curl -s -u "$AUTH" \
  --get "$KIBANA_URL/api/alerting/rules/_find" \
  --data-urlencode "per_page=2000" \
  --data-urlencode 'filter=alert.attributes.alertTypeId:siem.*')

# task manager tasks scoped to security-solution
tasks_json=$(curl -s -u "$AUTH" -H 'content-type: application/json' \
  "$ES_URL/.kibana_task_manager/_search?size=0&track_total_hits=true" \
  -d '{
    "query": { "prefix": { "task.taskType": "alerting:siem." } },
    "aggs":  { "enabled": { "filter": { "term": { "task.enabled": true } } } }
  }')

# encrypted apiKey actually written on the alert SO
api_key_count=$(curl -s -u "$AUTH" -H 'content-type: application/json' \
  "$ES_URL/.kibana_alerting_cases/_search?size=2000&filter_path=hits.hits._source.alert.apiKey" \
  -d '{
    "query": { "bool": { "filter": [
      { "term":   { "type": "alert" } },
      { "prefix": { "alert.alertTypeId": "siem." } }
    ]}},
    "_source": ["alert.apiKey"]
  }' | jq '[.hits.hits[]?._source.alert.apiKey | select(. != null and . != "")] | length')

echo "rules:           $(jq '.data | length'                                     <<<"$rules_json")"
echo "rules_enabled:   $(jq '[.data[] | select(.enabled)]              | length' <<<"$rules_json")"
echo "tasks:           $(jq '.hits.total.value'                                  <<<"$tasks_json")"
echo "tasks_enabled:   $(jq '.aggregations.enabled.doc_count'                    <<<"$tasks_json")"
echo "api_key_owner:   $(jq '[.data[] | select(.api_key_owner != null)] | length' <<<"$rules_json")"
echo "apiKey present:  $api_key_count"
```

Run this after each of the three scenarios below and compare against the
"Expect" column.

| # | Scenario | Command sequence | Expect |
|---|---|---|---|
| T18a | 100 disabled | `/tmp/kbn_test_import.sh reset-and-import T18a "$DATA/100disabled-rules.ndjson" > /dev/null && sleep 3 && bash .knowledge/scripts/check-tasks.sh` | `rules=100 enabled=0 tasks=0 tasks_enabled=0 api_key_owner=0 apiKey=0` |
| T18b | 100 enabled | `/tmp/kbn_test_import.sh reset-and-import T18b "$DATA/100enabled-rules.ndjson" > /dev/null && sleep 5 && bash .knowledge/scripts/check-tasks.sh` | all six numbers = 100 |
| T18c | 500 enabled | `/tmp/kbn_test_import.sh reset-and-import T18c "$DATA/500enabled-rules.ndjson" > /dev/null && sleep 8 && bash .knowledge/scripts/check-tasks.sh` | all six numbers = 500 (5-chunk import, no drops) |

### 4.3 Post-import invariants — check-exceptions-connectors.sh (companion to T15–T17)

Verifies that exception-list refs and connector refs declared by imported
rules actually point at real SOs after the import.

Script location: `.knowledge/scripts/check-exceptions-connectors.sh`. Full
inline version:

```bash
KIBANA_URL="http://localhost:${KIBANA_DEV_PORT:-5601}/kbn"
ES_URL="http://localhost:${ES_DEV_PORT:-9200}"
AUTH="elastic:changeme"

rules_json=$(curl -s -u "$AUTH" \
  --get "$KIBANA_URL/api/alerting/rules/_find" \
  --data-urlencode "per_page=2000" \
  --data-urlencode 'filter=alert.attributes.alertTypeId:siem.*')

# what the rules SAY they need
referenced_lists=$(jq -r '[.data[].params.exceptionsList // [] | .[].list_id] | unique | .[]' <<<"$rules_json")
referenced_connectors=$(jq -r '[.data[].actions // [] | .[].id] | unique | .[]' <<<"$rules_json")

# what actually exists in the stack
lists_json=$(curl -s -u "$AUTH" -H 'content-type: application/json' \
  "$ES_URL/.kibana*/_search?size=1000&filter_path=hits.hits._source" \
  -d '{
    "query": { "bool": { "should": [
      { "term": { "type": "exception-list" } },
      { "term": { "type": "exception-list-agnostic" } }
    ]}},
    "_source": ["exception-list.list_id","exception-list-agnostic.list_id"]
  }')
existing_lists=$(jq -r '[.hits.hits[]?._source | (."exception-list".list_id // ."exception-list-agnostic".list_id)] | map(select(. != null)) | unique | .[]' <<<"$lists_json")
existing_connectors=$(curl -s -u "$AUTH" "$KIBANA_URL/api/actions/connectors" | jq -r '.[].id')

missing_lists=$(comm -23 <(sort -u <<<"$referenced_lists")      <(sort -u <<<"$existing_lists")      || true)
missing_conns=$(comm -23 <(sort -u <<<"$referenced_connectors") <(sort -u <<<"$existing_connectors") || true)

echo "rules:                 $(jq '.data | length' <<<"$rules_json")"
echo "rules w/ exceptions:   $(jq '[.data[] | select((.params.exceptionsList // []) | length > 0)] | length' <<<"$rules_json")"
echo "rules w/ actions:      $(jq '[.data[] | select((.actions // []) | length > 0)] | length' <<<"$rules_json")"
echo "connectors:            $(jq 'length' <<<"$(curl -s -u "$AUTH" "$KIBANA_URL/api/actions/connectors")")"
echo "dangling exc refs:     ${missing_lists:-(none)}"
echo "dangling conn refs:    ${missing_conns:-(none)}"
```

Then run once per scenario:

| # | Scenario | Command sequence | Expect |
|---|---|---|---|
| T19a | E1: rule + 3 action connectors | `/tmp/kbn_test_import.sh reset-and-import E1 "$DATA/1rule+3actionconnectors.ndjson" true > /dev/null && sleep 2 && bash .knowledge/scripts/check-exceptions-connectors.sh` | 1 rule w/ actions, endpoint_list present, no dangling **exception** refs. `system-connector-.workflows` **may** show as a dangling connector — this is a script false-positive (system connectors aren't returned by `/api/actions/connectors`) and is unrelated to the import. |
| T19b | E2: rule + 1 own exception | `/tmp/kbn_test_import.sh reset-and-import E2 "$DATA/1rule+1exceptionlist(ownexceptions).ndjson" true > /dev/null && sleep 2 && bash .knowledge/scripts/check-exceptions-connectors.sh` | 1 rule w/ exceptions, no dangling refs |
| T19c | E3: rule + own+shared exceptions | `/tmp/kbn_test_import.sh reset-and-import E3 "$DATA/1rule+2exceptionlist(own.and.shared).ndjson" true > /dev/null && sleep 2 && bash .knowledge/scripts/check-exceptions-connectors.sh` | 1 rule w/ exceptions (2 list refs), no dangling refs |

## 5. What each test proves about the refactor

- **T1** — cold path smoke; validates the route can init `ensureLatestRulesPackageInstalled` on the first request without hanging.
- **T2 / T3 / T4** — single-chunk bulk create for disabled / enabled / mixed rules; validates `bulkCreateRules` handles enabled and disabled inline.
- **T5** — the overwrite branch (`pMap` at `RULE_IMPORT_BULK_UPDATE_CONCURRENCY`) still works.
- **T6** — conflict detection via `installedRulesById` (from `fetchPrebuiltImportContext`); confirms `findExistingRuleIds` removal didn't drop the 409 semantics.
- **T7 / T8** — outer chunking at `RULE_IMPORT_BULK_CREATE_BATCH_SIZE` (100). 5 and 10 chunks; no drops.
- **T9** — `missingVersionError` path in `prepareRules` returns the exact i18n message.
- **T10 / T11** — per-row `bulkCreateRules` errors get re-paired to the correct `rule_id` via the uuid `inputById` map (the mechanism `buildBulkInputs` sets up).
- **T12** — pre-route dedupe via `getTupleDuplicateErrorsAndUniqueRules` is intact.
- **T13** — action-connector validation still runs before the method is invoked.
- **T14** — ML-authz path exists (may not fire without an ML licence locally).
- **T15 / T16 / T17** — exception + connector helpers (`getReferencedExceptionLists`, `checkRuleExceptionReferences`, `import_rule_action_connectors`) still integrate correctly.
- **T18a–c** — the six-way invariant (`rules == rules_enabled == tasks == tasks_enabled == api_key_owner == apiKey_present`) is the reason the whole refactor exists. At 500 enabled rules across 5 chunks with zero drops, the risk that motivated the previous feature-flag is gone.
- **T19a–c** — post-import, every exception-list ref and (user-owned) connector ref that any imported rule declares points at a real SO in ES/Kibana. No dangling refs.

## 6. Cleanup

```bash
/tmp/kbn_test_import.sh delete
```

or, to also drop leftover exception lists and connectors used only for
testing, delete them via their Kibana APIs
(`/api/exception_lists?list_id=…`, `/api/actions/connector/{id}`).

## 7. Where the code under test lives

- Route: `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/import_rules/route.ts`
- Top-level orchestrator: `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/import/import_rules.ts`
- Client method: `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/import_rules.ts`
- Prebuilt-context helper: `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/import/fetch_prebuilt_import_context.ts`
- Constants: `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/constants.ts`
  (`RULE_IMPORT_BULK_CREATE_BATCH_SIZE`, `RULE_IMPORT_BULK_UPDATE_CONCURRENCY`)

## 8. Reference

- Full parallel-import shell script (multi-target cloud runs): `.knowledge/scripts/bulk-create/parallel_import_rules.sh`
- Full parallel-delete shell script: `.knowledge/scripts/bulk-create/parallel_delete_rules.sh`
- Fixture inventory: `.knowledge/data/rules-import/`
