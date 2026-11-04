#!/usr/bin/env bash
#
# Serverless version of test-rule-api-key-owner.sh: what happens to a running
# detection rule when its API key is deleted, or its owner is removed.
#
# Serverless has no native users API, so there's no "bob" we can create or
# delete. The rule owner is whoever's credentials we use. Each scenario creates
# a source index and an enabled query rule, waits for a baseline run, applies
# the change, indexes a fresh doc, forces a run and prints the outcome and
# alert count.
#
# Usage:
#   KIBANA_URL=https://<project>.kb.<region>.elastic.cloud KIBANA_AUTH=user:pass \
#     ./test-rule-api-key-owner-serverless.sh <scenario>
#
# Scenarios:
#   preflight           check both endpoints and print who we're authenticated as
#   key-type            create a rule and report whether its key is an ES API key
#                       (listed in _security/api_key) or not (likely a UIAM key)
#   invalidate-key      invalidate the rule's ES API key (fails if it isn't one)
#   apikey-auth-delete  create the rule while authenticated with a personal API
#                       key, then delete that key. Tests the docs warning "if the
#                       user's key gets deleted, the rules will stop running".
#   owner-removed-setup  as OWNER_AUTH, create the rule and baseline it. Then
#                        remove that user from the Cloud organization by hand.
#   owner-removed-check  force a run as admin and report. Tests the docs warning
#                        "if the user becomes inactive, the rules will stop running".
#   cleanup             remove everything this script creates
#
# Env:
#   KIBANA_URL   (required) Kibana endpoint of the serverless project
#   KIBANA_AUTH  (required) user:password of an admin on the project
#   ES_URL       (optional) defaults to KIBANA_URL with ".kb." swapped for ".es."
#   OWNER_AUTH   (optional) user:password of a second Cloud user, for owner-removed-*
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

KIBANA_URL="${KIBANA_URL:?set KIBANA_URL}"
KIBANA_URL="${KIBANA_URL%/}"
ES_URL="${ES_URL:-${KIBANA_URL/.kb./.es.}}"
ES_URL="${ES_URL%/}"
AUTH="${KIBANA_AUTH:?set KIBANA_AUTH (user:password)}"
OWNER_AUTH="${OWNER_AUTH:-}"

INDEX="rule-owner-test-sl"
RULE_ID="rule-owner-test-sl"
RULE_NAME="Rule owner test (serverless)"
PERSONAL_KEY_NAME="rule-owner-test-sl-personal"

# owner-removed-* runs across two invocations, so the rule id is kept here.
STATE_FILE="${TMPDIR:-/tmp}/rule-owner-test-sl.state"

RUN_TIMEOUT_S=180

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

# auth_args <user:pass|apikey:<encoded>>
auth_args() {
  if [[ "$1" == apikey:* ]]; then
    printf '%s\n' -H "Authorization: ApiKey ${1#apikey:}"
  else
    printf '%s\n' -u "$1"
  fi
}

# kbn <auth> <METHOD> <path> [curl args...]
kbn() {
  local auth="$1" method="$2" path="$3"
  shift 3
  local creds=()
  while IFS= read -r arg; do creds+=("$arg"); done < <(auth_args "$auth")
  curl -sS "${creds[@]}" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: Kibana" \
    -H "elastic-api-version: 2023-10-31" \
    -H "Content-Type: application/json" \
    -X "$method" "${KIBANA_URL}${path}" "$@"
}

# es <auth> <METHOD> <path> [curl args...]
es() {
  local auth="$1" method="$2" path="$3"
  shift 3
  local creds=()
  while IFS= read -r arg; do creds+=("$arg"); done < <(auth_args "$auth")
  curl -sS "${creds[@]}" -H "Content-Type: application/json" -X "$method" "${ES_URL}${path}" "$@"
}

code() { curl -sS -o /dev/null -w "%{http_code}" "$@" || echo "000"; }

step() { echo; echo "== $*"; }

username() { es "$1" GET /_security/_authenticate | jq -r '.username // empty'; }

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

preflight() {
  echo "ES: ${ES_URL}"
  echo "Kibana: ${KIBANA_URL}"
  local es_code kbn_code
  es_code="$(code -u "$AUTH" "${ES_URL}/_security/_authenticate")"
  kbn_code="$(code -u "$AUTH" -H "x-elastic-internal-origin: Kibana" "${KIBANA_URL}/internal/security/me")"
  echo "ES auth: HTTP ${es_code}  Kibana auth: HTTP ${kbn_code}"
  [[ "$es_code" == "200" && "$kbn_code" == "200" ]] ||
    { echo "Can't authenticate. Check URLs and KIBANA_AUTH (Kibana may not accept basic auth here)." >&2; exit 2; }
  es "$AUTH" GET /_security/_authenticate |
    jq -c '{username, realm: .authentication_realm, type: .authentication_type, roles}'
}

cleanup() {
  step "Cleanup"
  kbn "$AUTH" DELETE "/api/detection_engine/rules?rule_id=${RULE_ID}" >/dev/null || true
  es "$AUTH" DELETE /_security/api_key --data "{\"name\":\"${PERSONAL_KEY_NAME}\"}" >/dev/null || true
  es "$AUTH" DELETE "/${INDEX}" >/dev/null || true
  rm -f "$STATE_FILE"
  echo "done"
}

index_doc() {
  es "$AUTH" POST "/${INDEX}/_doc?refresh=true" \
    --data "{\"@timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"message\":\"$1\"}" >/dev/null
}

# setup <auth used to create the rule>
setup() {
  local owner="$1" body
  step "Setup: index ${INDEX}"
  index_doc "baseline"

  step "Create enabled rule"
  body="$(kbn "$owner" POST /api/detection_engine/rules --data "{
    \"rule_id\":\"${RULE_ID}\",\"name\":\"${RULE_NAME}\",\"description\":\"API key owner lifecycle test\",
    \"type\":\"query\",\"language\":\"kuery\",\"query\":\"*\",\"index\":[\"${INDEX}*\"],
    \"risk_score\":21,\"severity\":\"low\",\"interval\":\"1m\",\"from\":\"now-10m\",\"enabled\":true
  }")"
  RULE_SO_ID="$(echo "$body" | jq -r '.id // empty')"
  [[ -n "$RULE_SO_ID" ]] || { echo "Rule create failed: $body" >&2; exit 1; }
  echo "rule id: ${RULE_SO_ID}"
}

# ---------------------------------------------------------------------------
# Running the rule and reading the result
# ---------------------------------------------------------------------------

last_run_date() {
  kbn "$AUTH" GET "/api/alerting/rule/${RULE_SO_ID}" |
    jq -r 'select(.execution_status.status != "pending") | .execution_status.last_execution_date // empty'
}

wait_for_run() {
  local prev="$1" now waited=0
  while (( waited < RUN_TIMEOUT_S )); do
    now="$(last_run_date)"
    [[ -n "$now" && "$now" != "$prev" ]] && return 0
    sleep 3
    waited=$((waited + 3))
  done
  echo "Timed out after ${RUN_TIMEOUT_S}s waiting for a rule run" >&2
  return 1
}

run_now() {
  local prev
  prev="$(last_run_date)"
  kbn "$AUTH" POST "/internal/alerting/rule/${RULE_SO_ID}/_run_soon" >/dev/null || true
  wait_for_run "$prev"
}

# Alerts are counted through the detection API: .alerts-* isn't directly readable on serverless.
alert_count() {
  kbn "$AUTH" POST /api/detection_engine/signals/search \
    --data "{\"size\":0,\"query\":{\"term\":{\"kibana.alert.rule.uuid\":\"${RULE_SO_ID}\"}}}" |
    jq -r '.hits.total.value // .hits.total // 0'
}

report() {
  kbn "$AUTH" GET "/api/alerting/rule/${RULE_SO_ID}" | jq '{
    api_key_owner,
    api_key_created_by_user,
    status: .execution_status.status,
    error: .execution_status.error,
    last_run: { outcome: .last_run.outcome, warning: .last_run.warning, msg: .last_run.outcome_msg }
  }'
  echo "alerts for rule: $(alert_count)"
}

# rule_keys <auth of the key owner>
# Alerting names the keys it creates "Alerting: <rule type>/<rule name>".
rule_keys() {
  es "$1" GET "/_security/api_key?owner=true" | jq --arg name "$RULE_NAME" '[.api_keys[]
    | select((.name | startswith("Alerting:")) and (.name | endswith($name)))
    | { id, name, realm, invalidated, expiration, creation }]'
}

baseline() {
  step "Baseline: wait for first run"
  wait_for_run ""
  report
}

after() {
  step "After change: index a new doc and force a run"
  index_doc "after-change"
  run_now
  report
}

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

scenario="${1:-}"

case "$scenario" in
  preflight)
    preflight
    ;;

  # On stateful the rule gets an ES API key granted for the owner. On serverless
  # it may get a UIAM key instead, which ES doesn't list.
  key-type)
    preflight; cleanup; setup "$AUTH"; baseline
    step "ES API keys created by Alerting for this rule"
    keys="$(rule_keys "$AUTH")"
    echo "$keys"
    if [[ "$(echo "$keys" | jq 'length')" == "0" ]]; then
      echo "No ES API key found: the rule's key is likely a UIAM key."
    else
      echo "The rule uses an ES API key."
    fi
    ;;

  # Expect: like stateful scenario #4, the next run fails and no new alert appears.
  invalidate-key)
    preflight; cleanup; setup "$AUTH"; baseline
    step "Invalidate the rule's ES API key"
    # Deleted rules' keys linger until invalidated in the background, so take the newest.
    id="$(rule_keys "$AUTH" | jq -r '[.[] | select(.invalidated | not)] | sort_by(.creation) | last.id // empty')"
    [[ -n "$id" ]] || { echo "No active ES API key for the rule (UIAM key?). Run key-type." >&2; exit 1; }
    es "$AUTH" DELETE /_security/api_key --data "{\"ids\":[\"${id}\"]}" | jq -c .
    after
    ;;

  # With API key auth, Alerting stores the caller's own key on the rule instead
  # of creating one. Deleting that personal key is what the docs warning describes.
  apikey-auth-delete)
    preflight; cleanup
    step "Create a personal API key (${PERSONAL_KEY_NAME})"
    encoded="$(es "$AUTH" POST /_security/api_key --data "{\"name\":\"${PERSONAL_KEY_NAME}\"}" | jq -r '.encoded // empty')"
    [[ -n "$encoded" ]] || { echo "Couldn't create a personal API key" >&2; exit 1; }
    echo "Kibana with the key: HTTP $(code -H "Authorization: ApiKey ${encoded}" \
      -H "x-elastic-internal-origin: Kibana" "${KIBANA_URL}/internal/security/me")"
    setup "apikey:${encoded}"; baseline
    step "Delete the personal API key"
    es "$AUTH" DELETE /_security/api_key --data "{\"name\":\"${PERSONAL_KEY_NAME}\"}" | jq -c .
    after
    ;;

  owner-removed-setup)
    [[ -n "$OWNER_AUTH" ]] || { echo "Set OWNER_AUTH to a second Cloud user" >&2; exit 2; }
    preflight; cleanup
    owner="$(username "$OWNER_AUTH")"
    [[ -n "$owner" ]] || { echo "OWNER_AUTH can't authenticate" >&2; exit 2; }
    setup "$OWNER_AUTH"; baseline
    step "ES API keys created by Alerting for ${owner}"
    rule_keys "$OWNER_AUTH"
    echo "RULE_SO_ID=${RULE_SO_ID}" > "$STATE_FILE"
    echo
    echo "Now remove ${owner} from the Cloud organization, then run: $0 owner-removed-check"
    ;;

  # Expect, if serverless matches stateful: the rule keeps alerting.
  # If removing the user revokes their UIAM keys: the run fails, like invalidate-key.
  owner-removed-check)
    [[ -f "$STATE_FILE" ]] || { echo "Run owner-removed-setup first" >&2; exit 2; }
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    preflight
    if [[ -n "$OWNER_AUTH" ]]; then
      echo "owner authenticating: ES HTTP $(code -u "$OWNER_AUTH" "${ES_URL}/_security/_authenticate")"
    fi
    after
    ;;

  cleanup)
    cleanup
    ;;

  *)
    sed -n '2,35p' "$0"
    exit 2
    ;;
esac
