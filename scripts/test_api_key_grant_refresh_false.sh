#!/usr/bin/env bash
#
# Requires .security refresh_interval to already be stretched (stock ES
# defaults to 1s and rejects this setting). Then import a disabled query
# rule, bulk-enable it (mints the API key with refresh=false on this
# Kibana branch), and index 3 docs so the rule can alert.
#
# Usage:
#   ./scripts/test_api_key_grant_refresh_false.sh
#
# Ports (override if your stack is not 9200/5601):
#   ES_DEV_PORT=9201 KIBANA_DEV_PORT=5602 ./scripts/test_api_key_grant_refresh_false.sh
#
# Optional: ES_URL, KIBANA_URL, KIBANA_BASE_PATH, ELASTICSEARCH_USERNAME,
# ELASTICSEARCH_PASSWORD, KIBANA_AUTH (user:password)
#
set -euo pipefail

ES_DEV_PORT="${ES_DEV_PORT:-9200}"
KIBANA_DEV_PORT="${KIBANA_DEV_PORT:-5601}"
ES_URL="${ES_URL:-http://localhost:${ES_DEV_PORT}}"
KIBANA_URL="${KIBANA_URL:-}"
KIBANA_BASE_PATH="${KIBANA_BASE_PATH:-}"
AUTH="${KIBANA_AUTH:-${ELASTICSEARCH_USERNAME:-elastic}:${ELASTICSEARCH_PASSWORD:-changeme}}"

SO_ID="efda634f-64df-488d-b506-8d37be32e02f"
RULE_ID="9dcfc914-dcec-4ecf-9e6b-b8f89ed627a0"
INDEX="logs-api-key-grant-refresh-false"

API_VERSION="2023-10-31"
IMPORT_QS="overwrite=true&overwrite_exceptions=true&overwrite_action_connectors=true"

kbn() {
  local method="$1"
  local path="$2"
  shift 2
  curl -sS -u "$AUTH" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: Kibana" \
    -H "elastic-api-version: ${API_VERSION}" \
    -X "$method" \
    "${KIBANA_URL}${path}" \
    "$@"
}

es() {
  local method="$1"
  local path="$2"
  shift 2
  curl -sS -u "$AUTH" \
    -H "Content-Type: application/json" \
    -X "$method" \
    "${ES_URL}${path}" \
    "$@"
}

http_code() {
  curl -sS -o /dev/null -w "%{http_code}" "$@" || echo "000"
}

detect_kibana() {
  if [[ -n "$KIBANA_URL" ]]; then
    return 0
  fi

  local base="http://localhost:${KIBANA_DEV_PORT}"
  local prefixes=()
  if [[ -n "$KIBANA_BASE_PATH" ]]; then
    prefixes=("$KIBANA_BASE_PATH")
  else
    prefixes=("" "/kbn")
  fi

  local prefix
  for prefix in "${prefixes[@]}"; do
    if [[ "$(http_code "${base}${prefix}/api/status")" == "200" ]]; then
      KIBANA_URL="${base}${prefix}"
      return 0
    fi
  done

  echo "Could not reach Kibana on ${base} (tried base paths: ${prefixes[*]:-/})" >&2
  echo "Set KIBANA_URL or KIBANA_DEV_PORT / KIBANA_BASE_PATH." >&2
  exit 2
}

require_key_and_task() {
  local id="$1"
  local body owner task_id hits
  body="$(curl -sS -u "$AUTH" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: Kibana" \
    "${KIBANA_URL}/api/alerting/rule/${id}")"

  if command -v jq >/dev/null 2>&1; then
    owner="$(echo "$body" | jq -r '.api_key_owner // empty')"
    task_id="$(echo "$body" | jq -r '.scheduled_task_id // empty')"
  else
    owner="$(echo "$body" | sed -n 's/.*"api_key_owner":"\([^"]*\)".*/\1/p' | head -1)"
    task_id="$(echo "$body" | sed -n 's/.*"scheduled_task_id":"\([^"]*\)".*/\1/p' | head -1)"
  fi

  if [[ -z "$owner" ]]; then
    echo "Rule ${id} has no API key assigned (api_key_owner is empty)." >&2
    exit 1
  fi
  echo "API key owner: ${owner}"

  if [[ -z "$task_id" ]]; then
    echo "Rule ${id} has no scheduled_task_id." >&2
    exit 1
  fi

  hits="$(es POST "/.kibana_task_manager*/_search" --data "{
    \"size\": 1,
    \"query\": {
      \"bool\": {
        \"should\": [
          { \"ids\": { \"values\": [\"task:${task_id}\"] } },
          { \"term\": { \"task.id\": \"${task_id}\" } }
        ],
        \"minimum_should_match\": 1
      }
    }
  }")"
  local total
  if command -v jq >/dev/null 2>&1; then
    total="$(echo "$hits" | jq -r '.hits.total.value // .hits.total // 0')"
  else
    total="$(echo "$hits" | sed -n 's/.*"value":\([0-9]*\).*/\1/p' | head -1)"
  fi
  if [[ "${total:-0}" -lt 1 ]]; then
    echo "No Task Manager task found for scheduled_task_id=${task_id}." >&2
    exit 1
  fi
  echo "Task Manager task: ${task_id}"
}

require_security_refresh() {
  local body interval
  body="$(es GET "/.security/_settings/index.refresh_interval")"
  if command -v jq >/dev/null 2>&1; then
    interval="$(echo "$body" | jq -r '[.. | objects | .refresh_interval? | select(. != null)] | first // empty')"
  else
    interval="$(echo "$body" | sed -n 's/.*"refresh_interval"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  fi

  if [[ -z "$interval" ]]; then
    echo ".security refresh_interval is not set (default 1s). Stretch it to ~30s on patched ES, then re-run:" >&2
    echo "  curl -u ${AUTH} -X PUT '${ES_URL}/_security/settings' -H 'Content-Type: application/json' \\" >&2
    echo "    -d '{ \"security\": { \"index.refresh_interval\": \"30s\" } }'" >&2
    exit 2
  fi

  echo ".security refresh_interval: ${interval}"
}

lookup_id() {
  local body
  body="$(kbn GET "/api/detection_engine/rules?id=${SO_ID}" || true)"
  if echo "$body" | grep -q "\"id\":\"${SO_ID}\""; then
    echo "$SO_ID"
    return 0
  fi

  body="$(kbn GET "/api/detection_engine/rules?rule_id=${RULE_ID}" || true)"
  if command -v jq >/dev/null 2>&1; then
    echo "$body" | jq -r 'select(.id != null) | .id' | head -1
  else
    echo "$body" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1
  fi
}

if [[ "$(http_code -u "$AUTH" "${ES_URL}")" == "000" ]]; then
  echo "Could not reach Elasticsearch at ${ES_URL}" >&2
  echo "Set ES_URL or ES_DEV_PORT." >&2
  exit 2
fi

echo "ES: ${ES_URL}"
require_security_refresh

detect_kibana
echo "Kibana: ${KIBANA_URL}"

existing="$(lookup_id || true)"
if [[ -n "${existing:-}" ]]; then
  echo "Deleting existing rule ${existing}"
  kbn POST "/api/detection_engine/rules/_bulk_action?dry_run=false" \
    -H "Content-Type: application/json" \
    --data "{\"action\":\"delete\",\"ids\":[\"${existing}\"]}" >/dev/null
else
  echo "No existing rule to delete"
fi

ndjson="$(mktemp -t grant_refresh_false_XXXX).ndjson"
trap 'rm -f "$ndjson"' EXIT
cat >"$ndjson" <<EOF
{"id":"${SO_ID}","rule_id":"${RULE_ID}","name":"Test rule \\"${INDEX}\\"","immutable":false,"rule_source":{"type":"internal"},"version":1,"revision":0,"enabled":false,"interval":"10s","from":"now-2m","to":"now","description":"Test rule: create an alert for every entry in index \\"${INDEX}\\"","tags":[],"author":[],"license":"","threat":[],"related_integrations":[],"required_fields":[],"setup":"","false_positives":[],"references":[],"risk_score":73,"risk_score_mapping":[],"severity":"high","severity_mapping":[],"output_index":"","max_signals":100,"exceptions_list":[],"actions":[],"type":"query","language":"kuery","index":["${INDEX}"],"query":"*","filters":[]}
{"exported_count":1,"exported_rules_count":1,"missing_rules":[],"missing_rules_count":0,"exported_exception_list_count":0,"exported_exception_list_item_count":0,"missing_exception_list_item_count":0,"missing_exception_list_items":[],"missing_exception_lists":[],"missing_exception_lists_count":0,"exported_action_connector_count":0,"missing_action_connection_count":0,"missing_action_connections":[],"excluded_action_connection_count":0,"excluded_action_connections":[]}
EOF

echo "Importing disabled rule"
import_body="$(kbn POST "/api/detection_engine/rules/_import?${IMPORT_QS}" \
  -F "file=@${ndjson};type=application/x-ndjson")"
if command -v jq >/dev/null 2>&1; then
  echo "$import_body" | jq '{success, success_count, errors}'
else
  echo "$import_body"
fi

rule_id="$(lookup_id)"
if [[ -z "$rule_id" ]]; then
  echo "Import succeeded but rule was not found (id=${SO_ID} rule_id=${RULE_ID})" >&2
  exit 1
fi

echo "Bulk-enabling ${rule_id}"
enable_body="$(kbn POST "/api/detection_engine/rules/_bulk_action?dry_run=false" \
  -H "Content-Type: application/json" \
  --data "{\"action\":\"enable\",\"ids\":[\"${rule_id}\"]}")"
if command -v jq >/dev/null 2>&1; then
  echo "$enable_body" | jq '{success, rules_count: .attributes.results.updated | length}'
else
  echo "$enable_body"
fi

require_key_and_task "$rule_id"

echo "Indexing 3 docs into ${INDEX}"
es DELETE "/${INDEX}" >/dev/null || true
bulk_resp="$(es POST "/${INDEX}/_bulk?refresh=true" \
  --data-binary @- <<EOF
{"create":{}}
{"@timestamp":"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)","message":"${INDEX} event 1","event":{"dataset":"${INDEX}"}}
{"create":{}}
{"@timestamp":"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)","message":"${INDEX} event 2","event":{"dataset":"${INDEX}"}}
{"create":{}}
{"@timestamp":"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)","message":"${INDEX} event 3","event":{"dataset":"${INDEX}"}}
EOF
)"
if command -v jq >/dev/null 2>&1; then
  echo "$bulk_resp" | jq '{errors, items: (.items | length)}'
else
  echo "$bulk_resp"
fi

echo
echo "Rule ${rule_id} is enabled (10s interval)."
echo "Expect 3 alerts in Security > Alerts within ~20s."
echo "  ${KIBANA_URL}/app/security/alerts"
echo "  ${KIBANA_URL}/api/detection_engine/rules?id=${rule_id}"
