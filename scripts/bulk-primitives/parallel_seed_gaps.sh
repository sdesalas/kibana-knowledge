#!/usr/bin/env bash
#
# Seeds gap docs in .kibana-event-log-ds for every TARGET, in parallel.
# Fetches rule id/name from Kibana, bulks unfilled gap events into ES.
# Shape matches generate_gaps_for_rule.ts (alert SO id, not rule_id).
#
# Requires: curl, jq, uuidgen
#
# Targets from .env.sh (or PARALLEL_ENV_FILE):
#   "AUTH|KBN_URL"           — ES derived: .kb.→.es. (ECH), else ES_URL / localhost:9206
#   "AUTH|KBN_URL|ES_URL"    — explicit ES
#
# Env:
#   GAPS_PER_RULE   default 3
#   SPACE_ID        default default
#   ES_URL          fallback when entry has no ES and KBN is not *.kb.*
#
# Usage:
#   ./parallel_seed_gaps.sh
#   GAPS_PER_RULE=1 PARALLEL_ENV_FILE=/tmp/local.env.sh ./parallel_seed_gaps.sh
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${PARALLEL_ENV_FILE:-${SCRIPT_DIR}/.env.sh}"
GAPS_PER_RULE="${GAPS_PER_RULE:-3}"
SPACE_ID="${SPACE_ID:-default}"
INDEX='.kibana-event-log-ds'
ES_URL_FALLBACK="${ES_URL:-http://localhost:9206}"

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

# UTC timestamp minus N minutes (macOS date -v, else GNU date -d)
iso_minus_minutes() {
  local mins="$1"
  if date -u -v-"${mins}"M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; then
    return 0
  fi
  date -u -d "-${mins} minutes" '+%Y-%m-%dT%H:%M:%SZ'
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

count_gaps() {
  local es_url="$1" es_auth="$2"
  curl -sS -u "$es_auth" -H 'content-type: application/json' \
    "${es_url}/${INDEX}/_count" \
    --data '{"query":{"bool":{"must":[{"term":{"event.action":"gap"}},{"term":{"event.provider":"alerting"}}]}}}' \
    | jq -r '.count // 0'
}

seed_one() {
  local auth="$1" kbn_url="$2" es_url="$3" label="$4"

  echo "[$label] KBN=${kbn_url} ES=${es_url} gaps_per_rule=${GAPS_PER_RULE}"

  local rules_tsv bulk_file
  rules_tsv="$(mktemp -t seed_gaps_rules_XXXX)"
  bulk_file="$(mktemp -t seed_gaps_bulk_XXXX)"

  local page=1 per_page=100 total=0
  : >"$rules_tsv"
  while true; do
    local chunk http_code
    chunk="$(mktemp -t seed_gaps_chunk_XXXX)"
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

  local gap_before gap_after
  gap_before="$(count_gaps "$es_url" "$auth")"

  : >"$bulk_file"
  local doc_count=0 rid rname i end_mins start_mins gte lte exec_uuid duration_ms so_json
  while IFS=$'\t' read -r rid rname; do
    [[ -z "$rid" ]] && continue
    i=0
    while [[ "$i" -lt "$GAPS_PER_RULE" ]]; do
      end_mins=$((24 * 60 + i * 10))
      start_mins=$((end_mins + 15))
      gte="$(iso_minus_minutes "$start_mins")"
      lte="$(iso_minus_minutes "$end_mins")"
      exec_uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
      duration_ms=$((15 * 60 * 1000))

      if [[ "$SPACE_ID" == "default" ]]; then
        so_json="$(jq -nc --arg id "$rid" '{rel:"primary",type:"alert",id:$id,type_id:"siem.queryRule"}')"
      else
        so_json="$(jq -nc --arg id "$rid" --arg space "$SPACE_ID" \
          '{rel:"primary",type:"alert",id:$id,type_id:"siem.queryRule",namespace:$space}')"
      fi

      jq -nc --arg index "$INDEX" '{create:{_index:$index}}' >>"$bulk_file"
      jq -nc \
        --arg id "$rid" \
        --arg name "$rname" \
        --arg gte "$gte" \
        --arg lte "$lte" \
        --argjson duration "$duration_ms" \
        --arg exec_uuid "$exec_uuid" \
        --arg space "$SPACE_ID" \
        --argjson so "$so_json" \
        '{
          "@timestamp": $lte,
          event: {provider: "alerting", action: "gap", kind: "alert", category: ["siem"]},
          kibana: {
            alert: {
              rule: {
                revision: 1,
                rule_type_id: "siem.queryRule",
                consumer: "siem",
                execution: {uuid: $exec_uuid},
                gap: {
                  range: {gte: $gte, lte: $lte},
                  filled_intervals: [],
                  in_progress_intervals: [],
                  unfilled_intervals: [{gte: $gte, lte: $lte}],
                  status: "unfilled",
                  total_gap_duration_ms: $duration,
                  filled_duration_ms: 0,
                  unfilled_duration_ms: $duration,
                  in_progress_duration_ms: 0
                }
              }
            },
            saved_objects: [$so],
            space_ids: [$space],
            server_uuid: "5d29f261-1b85-4d90-9088-53e0e0e87c7c",
            version: "9.6.0"
          },
          rule: {
            id: $id,
            license: "basic",
            category: "siem.queryRule",
            ruleset: "siem",
            name: $name
          },
          ecs: {version: "1.8.0"}
        }' >>"$bulk_file"
      doc_count=$((doc_count + 1))
      i=$((i + 1))
    done
  done <"$rules_tsv"
  rm -f "$rules_tsv"

  echo "[$label] indexing ${doc_count} gap docs…"

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
    chunk="$(mktemp -t seed_gaps_chunk_XXXX)"
    resp="$(mktemp -t seed_gaps_resp_XXXX)"
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

  gap_after="$(count_gaps "$es_url" "$auth")"
  echo "[$label] bulk_ok chunks=${chunk_n} gap_count before=${gap_before} after=${gap_after} delta=$((gap_after - gap_before))"
}

echo "seeding ${#TARGETS[@]} target(s) gaps_per_rule=${GAPS_PER_RULE}"

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
echo "all targets ok"
