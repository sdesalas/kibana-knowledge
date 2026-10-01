#!/usr/bin/env bash
#
# What happens to a running detection rule when its API key owner ("bob")
# changes, or when the key itself stops being valid.
#
# Each scenario starts clean: creates bob, his roles, a source index and an
# enabled query rule created *as bob*. It waits for a baseline run, applies the
# change, indexes a fresh doc, forces a run and prints the outcome, the alert
# count and bob's Alerting API key.
#
# Usage:
#   ./test-rule-api-key-owner.sh <scenario>
#
# Scenarios:
#   remove-role     bob loses read on the source index (role removed from user)
#   disable-user    bob is disabled
#   delete-user     bob is deleted
#   invalidate-key  bob's Alerting API key is invalidated
#   expire-key      bob's Alerting API key gets a 1m expiration, then we wait it out
#   cleanup         remove everything this script creates
#
# Optional env: ES_URL, KIBANA_URL, KIBANA_AUTH (user:password, default elastic:changeme)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# Admin connection. Everything except "create the rule" and "set key expiration"
# runs as this user, so the admin's own privileges never leak into bob's key.
ES_URL="${ES_URL:-http://localhost:9200}"
KIBANA_URL="${KIBANA_URL:-http://localhost:5601}"
AUTH="${KIBANA_AUTH:-elastic:changeme}"

# bob is a native-realm user we fully control: create, strip roles, disable, delete.
BOB="bob"
BOB_PASS="changeme-bob"
BOB_AUTH="${BOB}:${BOB_PASS}"

# Two roles so we can take away index access without taking away Kibana access:
#   KIBANA_ROLE  -> Kibana "all" in every space (lets bob create rules)
#   READER_ROLE  -> read on rule-owner-test* (what the rule actually searches)
KIBANA_ROLE="rule_owner_test_kibana"
READER_ROLE="rule_owner_test_reader"

# Source index the rule queries, and the rule's stable rule_id.
INDEX="rule-owner-test"
RULE_ID="rule-owner-test"

# Where Security writes alerts in the default space. We count alerts here to
# prove the rule really read data, not just that it "succeeded".
ALERTS_INDEX=".alerts-security.alerts-default"

# How long to wait for a rule run before giving up.
RUN_TIMEOUT_S=150

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

# kbn <user:pass> <METHOD> <path> [curl args...]
# Calls Kibana with the headers its APIs require (xsrf, internal origin for
# internal routes like _run_soon, and the public API version).
kbn() {
  local auth="$1" method="$2" path="$3"
  shift 3
  curl -sS -u "$auth" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: Kibana" \
    -H "elastic-api-version: 2023-10-31" \
    -H "Content-Type: application/json" \
    -X "$method" "${KIBANA_URL}${path}" "$@"
}

# es <user:pass> <METHOD> <path> [curl args...]
# Calls Elasticsearch directly and prints the response body.
es() {
  local auth="$1" method="$2" path="$3"
  shift 3
  curl -sS -u "$auth" -H "Content-Type: application/json" -X "$method" "${ES_URL}${path}" "$@"
}

# es_code <user:pass> <METHOD> <path>
# Same as es, but prints only the HTTP status. Used to show what bob himself
# can still do (401 = can't log in, 403 = logged in but not allowed).
es_code() {
  local auth="$1" method="$2" path="$3"
  curl -sS -o /dev/null -w "%{http_code}" -u "$auth" -X "$method" "${ES_URL}${path}" || echo "000"
}

step() { echo; echo "== $*"; }

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

# Fail fast if the stack isn't up.
preflight() {
  [[ "$(es_code "$AUTH" GET /)" == "200" ]] || { echo "Can't reach ES at ${ES_URL}" >&2; exit 2; }
  [[ "$(curl -s -o /dev/null -w "%{http_code}" "${KIBANA_URL}/api/status")" == "200" ]] ||
    { echo "Can't reach Kibana at ${KIBANA_URL}" >&2; exit 2; }
  echo "ES: ${ES_URL}  Kibana: ${KIBANA_URL}"
}

# Remove everything from a previous run. Every call ignores errors because any
# of these may already be gone (e.g. bob was deleted by the last scenario).
cleanup() {
  step "Cleanup"
  # Deleting the rule also makes Kibana queue its API key for invalidation.
  kbn "$AUTH" DELETE "/api/detection_engine/rules?rule_id=${RULE_ID}" >/dev/null || true
  # Belt and braces: invalidate any key still owned by bob.
  es "$AUTH" DELETE /_security/api_key --data "{\"username\":\"${BOB}\"}" >/dev/null || true
  es "$AUTH" DELETE "/_security/user/${BOB}" >/dev/null || true
  es "$AUTH" DELETE "/_security/role/${READER_ROLE}" >/dev/null || true
  kbn "$AUTH" DELETE "/api/security/role/${KIBANA_ROLE}" >/dev/null || true
  es "$AUTH" DELETE "/${INDEX}" >/dev/null || true
  echo "done"
}

# Add one event to the source index with a current timestamp, so the next rule
# run has something new to alert on. refresh=true makes it searchable right away.
index_doc() {
  es "$AUTH" POST "/${INDEX}/_doc?refresh=true" \
    --data "{\"@timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"message\":\"$1\"}" >/dev/null
}

# Build the starting state: roles, bob, one doc, and a rule owned by bob.
setup() {
  step "Setup: roles, user ${BOB}, index ${INDEX}"

  # Kibana role via the Kibana API (it knows how to express "base: all" for
  # every space). No ES index privileges here on purpose.
  kbn "$AUTH" PUT "/api/security/role/${KIBANA_ROLE}" \
    --data '{"elasticsearch":{"cluster":[],"indices":[]},"kibana":[{"base":["all"],"spaces":["*"]}]}' >/dev/null

  # Plain ES role: read on the source index only.
  es "$AUTH" PUT "/_security/role/${READER_ROLE}" \
    --data "{\"indices\":[{\"names\":[\"${INDEX}*\"],\"privileges\":[\"read\",\"view_index_metadata\"]}]}" >/dev/null

  # bob starts with both roles.
  es "$AUTH" PUT "/_security/user/${BOB}" \
    --data "{\"password\":\"${BOB_PASS}\",\"roles\":[\"${KIBANA_ROLE}\",\"${READER_ROLE}\"]}" >/dev/null

  index_doc "baseline"

  # Create the rule *as bob*. Because it's created enabled, Alerting mints an
  # API key for bob right now, and the rule will run with that key from here on.
  # That key's permissions are a snapshot of bob's roles at this moment.
  step "Create enabled rule as ${BOB}"
  local body
  body="$(kbn "$BOB_AUTH" POST /api/detection_engine/rules --data "{
    \"rule_id\":\"${RULE_ID}\",\"name\":\"Rule owner test\",\"description\":\"API key owner lifecycle test\",
    \"type\":\"query\",\"language\":\"kuery\",\"query\":\"*\",\"index\":[\"${INDEX}*\"],
    \"risk_score\":21,\"severity\":\"low\",\"interval\":\"1m\",\"from\":\"now-10m\",\"enabled\":true
  }")"

  # Saved-object id of the rule. Alerting APIs need this, not the rule_id.
  RULE_SO_ID="$(echo "$body" | jq -r '.id // empty')"
  [[ -n "$RULE_SO_ID" ]] || { echo "Rule create failed: $body" >&2; exit 1; }
  echo "rule id: ${RULE_SO_ID}"
}

# ---------------------------------------------------------------------------
# Running the rule and reading the result
# ---------------------------------------------------------------------------

# Timestamp of the rule's most recent run (empty until it has run once).
last_run_date() {
  kbn "$AUTH" GET "/api/alerting/rule/${RULE_SO_ID}" | jq -r '.execution_status.last_execution_date // empty'
}

# Poll until last_execution_date moves past <prev>, i.e. a new run has finished.
# Pass "" to wait for the very first run.
wait_for_run() {
  local prev="$1" now waited=0
  while (( waited < RUN_TIMEOUT_S )); do
    now="$(last_run_date)"
    if [[ -n "$now" && "$now" != "$prev" ]]; then
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  echo "Timed out after ${RUN_TIMEOUT_S}s waiting for a rule run" >&2
  return 1
}

# Ask Task Manager to run the rule now instead of waiting for the next 1m tick,
# then wait for that run to finish. Called as admin; _run_soon doesn't change
# which key the rule runs with.
run_now() {
  local prev
  prev="$(last_run_date)"
  kbn "$AUTH" POST "/internal/alerting/rule/${RULE_SO_ID}/_run_soon" >/dev/null || true
  wait_for_run "$prev"
}

# Print everything we care about after a run:
#   - rule outcome as Alerting sees it (status, error, warning/messages).
#     Detection "missing privileges" shows up as last_run.outcome = warning.
#   - how many alerts the rule has written in total (goes up by one per new doc
#     if the rule could actually read the index)
#   - bob's Alerting API keys: still valid? expiring? and which roles its
#     permission snapshot (limited_by) was taken from
report() {
  kbn "$AUTH" GET "/api/alerting/rule/${RULE_SO_ID}" | jq '{
    api_key_owner,
    status: .execution_status.status,
    error: .execution_status.error,
    last_run: { outcome: .last_run.outcome, warning: .last_run.warning, msg: .last_run.outcome_msg }
  }'

  local alerts
  alerts="$(es "$AUTH" POST "/${ALERTS_INDEX}/_count" \
    --data "{\"query\":{\"term\":{\"kibana.alert.rule.uuid\":\"${RULE_SO_ID}\"}}}" | jq -r '.count // 0')"
  echo "alerts for rule: ${alerts}"

  # Alerting names its keys "Alerting: <rule type>/<rule name>", so filter on that.
  echo "bob's Alerting API keys:"
  es "$AUTH" GET "/_security/api_key?username=${BOB}&with_limited_by=true" | jq '[.api_keys[]
    | select(.name | startswith("Alerting:"))
    | { id, name, invalidated, expiration, limited_by_roles: ((.limited_by // [{}])[0] | keys) }]'
}

# Id of bob's current (not yet invalidated) Alerting key.
key_id() {
  es "$AUTH" GET "/_security/api_key?username=${BOB}" | jq -r '[.api_keys[]
    | select((.name | startswith("Alerting:")) and (.invalidated | not))][0].id // empty'
}

# Before the change: the rule's first run should succeed and produce 1 alert.
baseline() {
  step "Baseline: wait for first run"
  wait_for_run ""
  report
}

# After the change: add a new doc and force a run. Compare with the baseline:
# an extra alert means the rule could still read the index with bob's key.
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
preflight

case "$scenario" in
  # bob keeps Kibana access but loses read on the source index.
  # Expect: bob gets 403 searching the index himself, but the rule keeps
  # alerting, because its key still holds the old permission snapshot.
  remove-role)
    cleanup; setup; baseline
    step "Remove ${READER_ROLE} from ${BOB}"
    # No password in the body: for an existing user, PUT only updates roles.
    es "$AUTH" PUT "/_security/user/${BOB}" --data "{\"roles\":[\"${KIBANA_ROLE}\"]}" >/dev/null
    echo "bob searching ${INDEX} directly: HTTP $(es_code "$BOB_AUTH" GET "/${INDEX}/_search")"
    after
    ;;

  # bob can no longer log in. Open question: does his existing key still work?
  disable-user)
    cleanup; setup; baseline
    step "Disable ${BOB}"
    es "$AUTH" PUT "/_security/user/${BOB}/_disable" >/dev/null
    echo "bob authenticating: HTTP $(es_code "$BOB_AUTH" GET /_security/_authenticate)"
    after
    ;;

  # bob is gone entirely (the "fired" case). Same open question as above.
  delete-user)
    cleanup; setup; baseline
    step "Delete ${BOB}"
    es "$AUTH" DELETE "/_security/user/${BOB}" | jq -c .
    echo "bob authenticating: HTTP $(es_code "$BOB_AUTH" GET /_security/_authenticate)"
    after
    ;;

  # An admin kills the key (what Stack Management -> API keys -> Delete does).
  # Expect: the next run fails with an authentication error and no new alert.
  invalidate-key)
    cleanup; setup; baseline
    step "Invalidate bob's Alerting API key"
    id="$(key_id)"
    [[ -n "$id" ]] || { echo "No active Alerting key for ${BOB}" >&2; exit 1; }
    es "$AUTH" DELETE /_security/api_key --data "{\"ids\":[\"${id}\"]}" | jq -c .
    after
    ;;

  # Kibana never sets an expiration on rule keys, so we add one ourselves.
  # Only the key's owner can update it, so this call runs as bob.
  # Expect: once the minute passes, the next run fails with an auth error.
  expire-key)
    cleanup; setup; baseline
    step "Set a 1m expiration on bob's Alerting API key (as bob, the owner)"
    id="$(key_id)"
    [[ -n "$id" ]] || { echo "No active Alerting key for ${BOB}" >&2; exit 1; }
    # Updating a key also refreshes its limited_by snapshot to bob's current roles.
    resp="$(es "$BOB_AUTH" PUT "/_security/api_key/${id}" --data '{"expiration":"1m"}')"
    echo "$resp" | jq -c .
    [[ "$(echo "$resp" | jq -r '.updated // empty')" == "true" ]] ||
      { echo "Key update failed; this ES version may not support updating expiration" >&2; exit 1; }
    echo "waiting 75s for the key to expire"
    sleep 75
    after
    ;;

  cleanup)
    cleanup
    ;;

  # No or unknown scenario: print the usage block from the top of this file.
  *)
    sed -n '2,22p' "$0"
    exit 2
    ;;
esac
