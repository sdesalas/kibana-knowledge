#!/usr/bin/env bash
#
# Repro: bulk-enabling an already-enabled rule whose task still has a legacy
# (pre-8.1, random) id silently kills the rule on `main`.
#
# Steps:
#   1. Create an enabled Security query rule (10s interval).
#   2. Fake legacy state: copy task:<ruleId> to task:<random>, point the rule
#      SO's scheduledTaskId at it, delete task:<ruleId>.
#   3. Confirm the rule still runs on the legacy task.
#   4. Bulk-enable the (already enabled) rule.
#   5. Wait, then check the rule still has a task and keeps running.
#
# Usage:
#   ./scripts/repro-bulk-enable-legacy-task-id.sh
#   MODE=stack ./scripts/repro-bulk-enable-legacy-task-id.sh   # Stack Management endpoint
#
# Env: MODE=security|stack, ES_DEV_PORT, KIBANA_DEV_PORT, KIBANA_BASE_PATH,
#      ES_URL, KIBANA_URL, KIBANA_AUTH (user:password), WAIT_SECS
#
set -euo pipefail

MODE="${MODE:-security}"
ES_DEV_PORT="${ES_DEV_PORT:-9200}"
KIBANA_DEV_PORT="${KIBANA_DEV_PORT:-5601}"
ES_URL="${ES_URL:-http://localhost:${ES_DEV_PORT}}"
KIBANA_URL="${KIBANA_URL:-}"
KIBANA_BASE_PATH="${KIBANA_BASE_PATH:-}"
AUTH="${KIBANA_AUTH:-elastic:changeme}"
WAIT_SECS="${WAIT_SECS:-45}"

RULE_ID="legacy-task-id-repro"
TASK_INDEX=".kibana_task_manager"
RULE_INDEX=".kibana_alerting_cases"
# superuser cannot write restricted system indices
WRITER="legacy_repro_writer"
WRITER_AUTH="${WRITER}:changeme"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

kbn() {
  local method="$1" path="$2"
  shift 2
  curl -sS -u "$AUTH" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: Kibana" \
    -H "elastic-api-version: 2023-10-31" \
    -H "Content-Type: application/json" \
    -X "$method" "${KIBANA_URL}${path}" "$@"
}

es() {
  local method="$1" path="$2"
  shift 2
  curl -sS -u "$AUTH" -H "Content-Type: application/json" -X "$method" "${ES_URL}${path}" "$@"
}

es_write() {
  local method="$1" path="$2" body result
  shift 2
  body="$(curl -sS -u "$WRITER_AUTH" -H "Content-Type: application/json" -X "$method" "${ES_URL}${path}" "$@")"
  result="$(jq -r '.result // empty' <<<"$body")"
  if [[ -z "$result" ]]; then
    echo "   ES ${method} ${path} failed: ${body}" >&2
    exit 1
  fi
  echo "   ${method} ${path}: ${result}"
}

ensure_writer() {
  es PUT "/_security/role/${WRITER}" --data "{
    \"indices\": [{
      \"names\": [\"${TASK_INDEX}*\", \"${RULE_INDEX}*\"],
      \"privileges\": [\"all\"],
      \"allow_restricted_indices\": true
    }]
  }" >/dev/null
  es PUT "/_security/user/${WRITER}" \
    --data "{\"password\":\"changeme\",\"roles\":[\"${WRITER}\"]}" >/dev/null
}

http_code() {
  curl -sS -o /dev/null -w "%{http_code}" "$@" || echo "000"
}

detect_kibana() {
  [[ -n "$KIBANA_URL" ]] && return 0
  local base="http://localhost:${KIBANA_DEV_PORT}" prefix
  local prefixes=("")
  [[ -n "$KIBANA_BASE_PATH" ]] && prefixes=("$KIBANA_BASE_PATH") || prefixes=("" "/kbn")
  for prefix in "${prefixes[@]}"; do
    if [[ "$(http_code -u "$AUTH" "${base}${prefix}/api/status")" == "200" ]]; then
      KIBANA_URL="${base}${prefix}"
      return 0
    fi
  done
  echo "Could not reach Kibana on ${base}. Set KIBANA_URL or KIBANA_DEV_PORT / KIBANA_BASE_PATH." >&2
  exit 2
}

task_exists() {
  [[ "$(http_code -u "$AUTH" "${ES_URL}/${TASK_INDEX}/_doc/task:$1")" == "200" ]]
}

rule_state() {
  kbn GET "/api/alerting/rule/$1" | jq -c '{
    enabled,
    scheduled_task_id,
    status: .execution_status.status,
    last_execution_date: .execution_status.last_execution_date
  }'
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%S.000Z
}

wait_for_run_after() {
  local id="$1" since="$2" secs="$3" state
  for _ in $(seq 1 "$secs"); do
    state="$(rule_state "$id")"
    if [[ "$(jq -r '.status' <<<"$state")" != "pending" ]] &&
      [[ "$(jq -r '.last_execution_date' <<<"$state")" > "$since" ]]; then
      echo "$state"
      return 0
    fi
    sleep 1
  done
  echo "$state"
  return 1
}

[[ "$(http_code -u "$AUTH" "$ES_URL")" == "200" ]] || { echo "Could not reach ES at ${ES_URL}" >&2; exit 2; }
detect_kibana
echo "ES:     ${ES_URL}"
echo "Kibana: ${KIBANA_URL}"
echo "Mode:   ${MODE}"
echo

echo "1. Creating enabled rule (rule_id=${RULE_ID})"
kbn DELETE "/api/detection_engine/rules?rule_id=${RULE_ID}" >/dev/null || true
id="$(kbn POST "/api/detection_engine/rules" --data "{
  \"rule_id\": \"${RULE_ID}\",
  \"name\": \"Legacy task id repro\",
  \"description\": \"Bulk enable on a rule with a legacy task id\",
  \"type\": \"query\",
  \"language\": \"kuery\",
  \"index\": [\"logs-legacy-task-id-repro\"],
  \"query\": \"*\",
  \"risk_score\": 21,
  \"severity\": \"low\",
  \"interval\": \"10s\",
  \"from\": \"now-1m\",
  \"enabled\": true
}" | jq -r '.id // empty')"
[[ -n "$id" ]] || { echo "Rule creation failed" >&2; exit 1; }
echo "   id=${id}"

for _ in $(seq 1 20); do task_exists "$id" && break; sleep 1; done
task_exists "$id" || { echo "task:${id} never appeared" >&2; exit 1; }

legacy="$(uuidgen | tr '[:upper:]' '[:lower:]')"
echo "2. Faking legacy state: task:${id} -> task:${legacy}"
source="$(es GET "/${TASK_INDEX}/_doc/task:${id}" | jq --arg now "$(now_iso)" '._source
  | .task.status = "idle"
  | .task.ownerId = null
  | .task.retryAt = null
  | .task.startedAt = null
  | .task.attempts = 0
  | .task.runAt = $now')"
ensure_writer
es_write PUT "/${TASK_INDEX}/_doc/task:${legacy}?refresh=true" --data "$source"
es_write POST "/${RULE_INDEX}/_update/alert:${id}?refresh=true" \
  --data "{\"doc\":{\"alert\":{\"scheduledTaskId\":\"${legacy}\"}}}"
es_write DELETE "/${TASK_INDEX}/_doc/task:${id}?refresh=true"

swapped_at="$(now_iso)"
echo "3. Waiting for the rule to run on the legacy task"
if ! state="$(wait_for_run_after "$id" "$swapped_at" 40)" ||
  [[ "$(jq -r '.scheduled_task_id' <<<"$state")" != "$legacy" ]] ||
  task_exists "$id"; then
  echo "   Rule is not running on the legacy task, setup is broken: ${state}" >&2
  exit 1
fi
echo "   ${state}"

echo "4. Bulk-enabling the already-enabled rule (${MODE})"
if [[ "$MODE" == "stack" ]]; then
  response="$(kbn POST "/internal/alerting/rules/_bulk_enable" --data "{\"ids\":[\"${id}\"]}" |
    jq -c '{total, errors, task_ids_failed_to_be_enabled}')"
  failed="$(jq '.errors | length' <<<"$response")"
else
  response="$(kbn POST "/api/detection_engine/rules/_bulk_action?dry_run=false" \
    --data "{\"action\":\"enable\",\"ids\":[\"${id}\"]}" |
    jq -c '{success, summary: .attributes.summary, errors: .attributes.errors}')"
  failed="$(jq '.summary.failed // 0' <<<"$response")"
fi
echo "   ${response}"
if [[ "$failed" != "0" ]]; then
  echo "INCONCLUSIVE: bulk enable request itself failed" >&2
  exit 2
fi
enabled_at="$(now_iso)"

echo "5. Waiting up to ${WAIT_SECS}s for the rule to run again"
ran=true
state="$(wait_for_run_after "$id" "$enabled_at" "$WAIT_SECS")" || ran=false
scheduled="$(jq -r '.scheduled_task_id' <<<"$state")"

echo
echo "Rule:                      ${state}"
echo "task:${id} exists:     $(task_exists "$id" && echo yes || echo no)"
echo "task:${legacy} exists: $(task_exists "$legacy" && echo yes || echo no)"
echo

if $ran && task_exists "$scheduled"; then
  echo "OK: rule kept running on task ${scheduled}"
else
  echo "BUG: rule is enabled but has no task (scheduled_task_id=${scheduled}) and stopped running"
  exit 1
fi
