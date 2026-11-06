#!/usr/bin/env bash
#
# Seeds active AAD alert docs so delete/disable untrackRuleAlerts has real work.
# Fetches rule id/name from Kibana, bulks into .alerts-security.alerts-<space>.
# Docs are shaped for setAlertsToUntracked (status=active, rule.uuid=alert SO id).
#
# Requires: curl, jq, uuidgen
#
# Targets from .env.sh (or PARALLEL_ENV_FILE):
#   "AUTH|KBN_URL"           — ES derived: .kb.→.es. (ECH), else ES_URL / localhost:9205
#   "AUTH|KBN_URL|ES_URL"    — explicit ES
#
# Env:
#   ALERTS_PER_RULE  default 3
#   SPACE_ID         default default
#   ES_URL           fallback when entry has no ES and KBN is not *.kb.*
#
# Usage:
#   ./parallel_seed_alerts.sh
#   ALERTS_PER_RULE=1 PARALLEL_ENV_FILE=/tmp/local.env.sh ./parallel_seed_alerts.sh
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${PARALLEL_ENV_FILE:-${SCRIPT_DIR}/.env.sh}"
ALERTS_PER_RULE="${ALERTS_PER_RULE:-3}"
SPACE_ID="${SPACE_ID:-default}"
INDEX=".alerts-security.alerts-${SPACE_ID}"
ES_URL_FALLBACK="${ES_URL:-http://localhost:9205}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "env file not found: ${ENV_FILE}" >&2
  exit 2
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

if ! declare -p TARGETS >/dev/null 2>&1; then
  echo "TARGETS array not defined in ${ENV_FILE}" >&2
  exit 2
fi
if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  echo "TARGETS array is empty in ${ENV_FILE}" >&2
  exit 2
fi

for cmd in curl jq uuidgen; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "${cmd} required" >&2
    exit 2
  fi
done

slug_from_url() {
  local u="${1#*://}"
  u="${u%%/*}"
  echo "${u}" | tr -c 'A-Za-z0-9._-' '_'
}

resolve_es_url() {
  local kbn="$1"
  local explicit="${2:-}"
  if [[ -n "$explicit" ]]; then
    echo "${explicit%/}"
    return
  fi
  local base="${kbn%/}"
  base="${base%/kbn}"
  if [[ "$base" == *'.kb.'* ]]; then
    echo "${base//.kb./.es.}"
    return
  fi
  echo "${ES_URL_FALLBACK%/}"
}

count_active_alerts() {
  local es_url="$1" es_auth="$2"
  curl -sS -u "$es_auth" -H 'content-type: application/json' \
    "${es_url}/${INDEX}/_count" \
    --data '{"query":{"term":{"kibana.alert.status":"active"}}}' \
    | jq -r '.count // 0'
}

seed_one() {
  local auth="$1" kbn_url="$2" es_url="$3" label="$4"

  echo "[$label] KBN=${kbn_url} ES=${es_url} index=${INDEX} alerts_per_rule=${ALERTS_PER_RULE}"

  local rules_tsv bulk_file
  rules_tsv="$(mktemp -t seed_alerts_rules_XXXX)"
  bulk_file="$(mktemp -t seed_alerts_bulk_XXXX)"

  local page=1 per_page=100 total=0
  : >"$rules_tsv"
  while true; do
    local chunk http_code
    chunk="$(mktemp -t seed_alerts_chunk_XXXX)"
    http_code="$(curl -sS -o "$chunk" -w '%{http_code}' \
      -u "$auth" \
      -H 'kbn-xsrf: true' \
      -H 'elastic-api-version: 2023-10-31' \
      "${kbn_url}/api/detection_engine/rules/_find?page=${page}&per_page=${per_page}")" \
      || { echo "[$label] rules/_find curl failed"; rm -f "$chunk" "$rules_tsv" "$bulk_file"; return 1; }
    if [[ "$http_code" != "200" ]]; then
      echo "[$label] rules/_find HTTP ${http_code}: $(head -c 300 "$chunk")"
      rm -f "$chunk" "$rules_tsv" "$bulk_file"
      return 1
    fi
    total="$(jq -r '.total // 0' "$chunk")"
    jq -r '.data[]? | [.id, (.name // "Unknown Rule")] | @tsv' "$chunk" >>"$rules_tsv"
    rm -f "$chunk"
    if [[ $((page * per_page)) -ge "$total" ]]; then
      break
    fi
    page=$((page + 1))
  done

  local rule_count
  rule_count="$(wc -l <"$rules_tsv" | tr -d ' ')"
  if [[ "$rule_count" -eq 0 ]]; then
    echo "[$label] no rules found"
    rm -f "$rules_tsv" "$bulk_file"
    return 2
  fi
  echo "[$label] rules=${rule_count}"

  local alert_before alert_after
  alert_before="$(count_active_alerts "$es_url" "$auth")"

  : >"$bulk_file"
  local doc_count=0 rid rname i now aid
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  while IFS=$'\t' read -r rid rname; do
    [[ -z "$rid" ]] && continue
    i=0
    while [[ "$i" -lt "$ALERTS_PER_RULE" ]]; do
      aid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
      jq -nc --arg index "$INDEX" --arg id "$aid" '{create:{_index:$index,_id:$id}}' >>"$bulk_file"
      jq -nc \
        --arg rid "$rid" \
        --arg name "$rname" \
        --arg aid "$aid" \
        --arg now "$now" \
        --arg space "$SPACE_ID" \
        '{
          "@timestamp": $now,
          event: {kind: "signal"},
          kibana: {
            space_ids: [$space],
            alert: {
              uuid: $aid,
              status: "active",
              tracked: true,
              start: $now,
              time_range: {gte: $now},
              workflow_status: "open",
              severity: "low",
              risk_score: 1,
              reason: "bench seed active alert",
              rule: {
                uuid: $rid,
                name: $name,
                category: "siem.queryRule",
                consumer: "siem",
                producer: "siem",
                rule_type_id: "siem.queryRule"
              }
            }
          }
        }' >>"$bulk_file"
      doc_count=$((doc_count + 1))
      i=$((i + 1))
    done
  done <"$rules_tsv"
  rm -f "$rules_tsv"

  echo "[$label] indexing ${doc_count} active alert docs…"

  local total_lines start end chunk_n chunk resp http_code
  total_lines="$(wc -l <"$bulk_file" | tr -d ' ')"
  start=1
  chunk_n=0
  while [[ "$start" -le "$total_lines" ]]; do
    end=$((start + 999))
    if [[ "$end" -gt "$total_lines" ]]; then
      end="$total_lines"
    fi
    chunk_n=$((chunk_n + 1))
    chunk="$(mktemp -t seed_alerts_chunk_XXXX)"
    resp="$(mktemp -t seed_alerts_resp_XXXX)"
    sed -n "${start},${end}p" "$bulk_file" >"$chunk"
    http_code="$(curl -sS -o "$resp" -w '%{http_code}' \
      -u "$auth" \
      -H 'content-type: application/x-ndjson' \
      --data-binary @"$chunk" \
      "${es_url}/_bulk?refresh=true")" \
      || { echo "[$label] bulk curl failed"; rm -f "$chunk" "$resp" "$bulk_file"; return 1; }
    if [[ "$http_code" != "200" ]]; then
      echo "[$label] bulk HTTP ${http_code}: $(head -c 400 "$resp")"
      rm -f "$chunk" "$resp" "$bulk_file"
      return 1
    fi
    if [[ "$(jq -r '.errors // false' "$resp")" == "true" ]]; then
      echo "[$label] bulk errors: $(jq -c '[.items[] | select(.create.error) | .create.error][0:3]' "$resp")"
      rm -f "$chunk" "$resp" "$bulk_file"
      return 1
    fi
    rm -f "$chunk" "$resp"
    start=$((end + 1))
  done
  rm -f "$bulk_file"

  alert_after="$(count_active_alerts "$es_url" "$auth")"
  echo "[$label] bulk_ok chunks=${chunk_n} active_alert_count before=${alert_before} after=${alert_after} delta=$((alert_after - alert_before))"
}

echo "seeding ${#TARGETS[@]} target(s) alerts_per_rule=${ALERTS_PER_RULE}"

pids=()
for entry in "${TARGETS[@]}"; do
  auth="${entry%%|*}"
  rest="${entry#*|}"
  kbn_url="${rest%%|*}"
  es_part=""
  if [[ "$rest" == *'|'* ]]; then
    es_part="${rest#*|}"
  fi
  kbn_url="${kbn_url%/}"
  es_url="$(resolve_es_url "$kbn_url" "$es_part")"
  label="$(slug_from_url "$kbn_url")"
  seed_one "$auth" "$kbn_url" "$es_url" "$label" &
  pids+=("$!")
done

fail=0
for pid in "${pids[@]}"; do
  wait "$pid" || fail=1
done

if [[ "$fail" -ne 0 ]]; then
  echo "one or more targets failed" >&2
  exit 1
fi

echo "done"
exit 0
