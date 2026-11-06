#!/usr/bin/env bash
#
# Runs a rules _bulk_action on N Kibana instances in parallel.
#
# Targets are loaded from .env.sh (or PARALLEL_ENV_FILE), which must define a
# TARGETS bash array. Each entry is "AUTH|URL" (auth is "user:password").
#
# ACTION (required): enable | disable | delete | edit
# For ACTION=edit, EDIT_BODY must be a JSON array of edit ops, e.g.:
#   EDIT_BODY='[{"type":"add_tags","value":["bench"]}]'
# Optionally override the full request body with BODY=...
# Optional: QUERY (default ""), DRY_RUN=true|false (default false)
# Optional: SELECT=query|ids (default query).
#   SELECT=ids → per target, _find up to FIND_PER_PAGE rule ids (not timed),
#   then POST _bulk_action with {"action","ids"} (curl time_total is the action only).
#   Mutually exclusive with QUERY / a BODY that already sets query or ids.
# Optional: IDS_LIMIT=N with SELECT=ids — use only the first N ids from _find
#   (e.g. disable half the rules before a mixed enable).
#
# Usage:
#   ACTION=enable ./parallel_bulk_action.sh
#   ACTION=disable ./parallel_bulk_action.sh
#   ACTION=delete ./parallel_bulk_action.sh
#   ACTION=delete SELECT=ids ./parallel_bulk_action.sh
#   ACTION=disable SELECT=ids IDS_LIMIT=500 ./parallel_bulk_action.sh
#   ACTION=edit EDIT_BODY='[{"type":"add_tags","value":["bench"]}]' ./parallel_bulk_action.sh
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${PARALLEL_ENV_FILE:-${SCRIPT_DIR}/.env.sh}"
ACTION="${ACTION:-}"
QUERY="${QUERY:-}"
DRY_RUN="${DRY_RUN:-false}"
EDIT_BODY="${EDIT_BODY:-}"
BODY="${BODY:-}"
SELECT="${SELECT:-query}"
FIND_PER_PAGE="${FIND_PER_PAGE:-1000}"
IDS_LIMIT="${IDS_LIMIT:-}"

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

case "$ACTION" in
  enable|disable|delete|edit) ;;
  *)
    echo "ACTION must be enable|disable|delete|edit (got: '${ACTION}')" >&2
    exit 2
    ;;
esac

case "$SELECT" in
  query|ids) ;;
  *)
    echo "SELECT must be query|ids (got: '${SELECT}')" >&2
    exit 2
    ;;
esac

if [[ "$SELECT" == "ids" && -n "$QUERY" ]]; then
  echo "SELECT=ids cannot be combined with QUERY (got QUERY='${QUERY}')" >&2
  exit 2
fi
if [[ "$SELECT" == "ids" && -n "$BODY" ]]; then
  echo "SELECT=ids builds the body per target; omit BODY" >&2
  exit 2
fi

if [[ -z "$BODY" && "$SELECT" == "query" ]]; then
  if [[ "$ACTION" == "edit" && -z "$EDIT_BODY" ]]; then
    echo "ACTION=edit requires EDIT_BODY (JSON array of edit ops)" >&2
    exit 2
  fi
  BODY="$(
    ACTION="$ACTION" QUERY="$QUERY" EDIT_BODY="$EDIT_BODY" python3 - <<'PY'
import json, os
action = os.environ["ACTION"]
body = {"action": action, "query": os.environ.get("QUERY", "")}
if action == "edit":
    body["edit"] = json.loads(os.environ["EDIT_BODY"])
print(json.dumps(body, separators=(",", ":")))
PY
  )"
fi

BULK_PATH="/api/detection_engine/rules/_bulk_action?dry_run=${DRY_RUN}"
FIND_PATH="/api/detection_engine/rules/_find?per_page=${FIND_PER_PAGE}&page=1"
API_VERSION='2023-10-31'

USER_AGENT='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36'

gen_hex() {
  local n="$1"
  if [[ -r /dev/urandom ]]; then
    LC_ALL=C tr -dc '0-9a-f' </dev/urandom | head -c "$n"
  else
    printf '%s' "$(date +%s%N)$RANDOM$RANDOM" | shasum | head -c "$n"
  fi
}

gen_traceparent() {
  printf '00-%s-%s-01' "$(gen_hex 32)" "$(gen_hex 16)"
}

fetch_rule_ids() {
  local label="$1"
  local url="$2"
  local auth="$3"
  local out_file="$4"

  local tmp_find
  tmp_find="$(mktemp -t kbn_${label}_find_XXXX)"
  local find_code
  find_code="$(curl -sS \
    -o "$tmp_find" \
    -w '%{http_code}' \
    -u "$auth" \
    -H 'accept: application/json' \
    -H "elastic-api-version: ${API_VERSION}" \
    -H 'kbn-xsrf: true' \
    -H "user-agent: ${USER_AGENT}" \
    "${url}${FIND_PATH}")" \
    || {
      echo "[$label] _find curl failed" >&2
      rm -f "$tmp_find"
      return 1
    }

  if [[ "$find_code" != "200" ]]; then
    echo "[$label] _find HTTP ${find_code}: $(head -c 200 "$tmp_find" | tr '\n' ' ')" >&2
    rm -f "$tmp_find"
    return 1
  fi

  python3 - "$tmp_find" "$out_file" "${IDS_LIMIT:-}" <<'PY'
import json, sys
src, dst, limit = sys.argv[1], sys.argv[2], sys.argv[3]
payload = json.load(open(src))
ids = [r["id"] for r in payload.get("data", []) if r.get("id")]
if limit:
    ids = ids[: int(limit)]
if not ids:
    raise SystemExit("no rule ids in _find response")
json.dump(ids, open(dst, "w"), separators=(",", ":"))
print(len(ids))
PY
  local rc=$?
  rm -f "$tmp_find"
  return "$rc"
}

hit_bulk() {
  local label="$1"
  local url="$2"
  local auth="$3"
  local summary_file="$4"

  if [[ -z "$url" || "$url" == ".." ]]; then
    echo "[$label] SKIPPED (URL not configured)"
    printf '%s\tSKIPPED\t-\n' "$label" >>"$summary_file"
    return 0
  fi

  local request_body="$BODY"
  if [[ "$SELECT" == "ids" ]]; then
    local ids_file
    ids_file="$(mktemp -t kbn_${label}_ids_XXXX)"
    echo "[$label] SELECT=ids → GET ${url}${FIND_PATH} (not timed)"
    local id_count
    if ! id_count="$(fetch_rule_ids "$label" "$url" "$auth" "$ids_file")"; then
      printf '%s\tERROR\t-\n' "$label" >>"$summary_file"
      rm -f "$ids_file"
      return 1
    fi
    request_body="$(
      ACTION="$ACTION" IDS_FILE="$ids_file" EDIT_BODY="$EDIT_BODY" python3 - <<'PY'
import json, os
body = {"action": os.environ["ACTION"], "ids": json.load(open(os.environ["IDS_FILE"]))}
if os.environ["ACTION"] == "edit":
    body["edit"] = json.loads(os.environ["EDIT_BODY"])
print(json.dumps(body, separators=(",", ":")))
PY
    )"
    rm -f "$ids_file"
    echo "[$label] collected ${id_count} ids for ${ACTION}"
  fi

  echo "[$label] -> POST ${url}${BULK_PATH}"
  echo "[$label]    body: ${request_body:0:200}$([[ ${#request_body} -gt 200 ]] && echo '…')"

  local tmp_body
  tmp_body="$(mktemp -t kbn_${label}_XXXX)"

  local origin="${url%/}"
  local referer="${origin}/app/security/rules/management"
  local traceparent
  traceparent="$(gen_traceparent)"

  local stats
  stats="$(curl -sS \
    -o "$tmp_body" \
    -w '%{http_code} %{time_total}' \
    -X POST \
    -u "$auth" \
    -H 'accept: */*' \
    -H 'accept-language: en-US,en;q=0.9,es;q=0.8' \
    -H 'content-type: application/json' \
    -H "elastic-api-version: ${API_VERSION}" \
    -H 'kbn-xsrf: true' \
    -H "origin: ${origin}" \
    -H 'priority: u=1, i' \
    -H "referer: ${referer}" \
    -H 'sec-ch-ua: "Chromium";v="148", "Google Chrome";v="148", "Not/A)Brand";v="99"' \
    -H 'sec-ch-ua-mobile: ?0' \
    -H 'sec-ch-ua-platform: "macOS"' \
    -H 'sec-fetch-dest: empty' \
    -H 'sec-fetch-mode: cors' \
    -H 'sec-fetch-site: same-origin' \
    -H "traceparent: ${traceparent}" \
    -H 'tracestate: es=s:1' \
    -H "user-agent: ${USER_AGENT}" \
    -H 'x-elastic-internal-origin: Kibana' \
    --data "$request_body" \
    "${url}${BULK_PATH}")" \
    || {
      echo "[$label] curl failed"
      printf '%s\tERROR\t-\n' "$label" >>"$summary_file"
      rm -f "$tmp_body"
      return 1
    }

  local http_code time_total
  http_code="${stats% *}"
  time_total="${stats##* }"

  local preview
  preview="$(head -c 120 "$tmp_body" | tr '\n' ' ')"
  echo "[$label] <- HTTP ${http_code} in ${time_total}s | ${preview}"
  rm -f "$tmp_body"

  printf '%s\t%s\t%ss\n' "$label" "$http_code" "$time_total" >>"$summary_file"
}

echo "Bulk action: ${ACTION}  select=${SELECT}  dry_run=${DRY_RUN}  targets=${#TARGETS[@]}"
if [[ "$SELECT" == "ids" ]]; then
  echo "Body: (built per target from _find ids)"
else
  echo "Body: ${BODY}"
fi
echo

pids=()
summary_files=()
for i in "${!TARGETS[@]}"; do
  entry="${TARGETS[$i]}"
  auth="${entry%%|*}"
  url="${entry#*|}"
  target_name="${url#*://}"
  target_name="${target_name:0:28}"
  target_name="${target_name//[^a-zA-Z0-9_-]/_}"
  label="${target_name}-${ACTION}"

  sf="$(mktemp -t kbn_summary_bulk_XXXX)"
  summary_files+=("$sf")

  hit_bulk "$label" "$url" "$auth" "$sf" &
  pids+=($!)
done

rc=0
for pid in "${pids[@]}"; do
  wait "$pid" || rc=1
done

echo
echo "--- ${ACTION} timings ---"
printf 'target\thttp\ttime\n'
for sf in "${summary_files[@]}"; do
  cat "$sf"
  rm -f "$sf"
done
echo "------------------------"

exit "$rc"
