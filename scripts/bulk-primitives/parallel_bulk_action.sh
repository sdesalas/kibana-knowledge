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
#
# Usage:
#   ACTION=enable ./parallel_bulk_action.sh
#   ACTION=disable ./parallel_bulk_action.sh
#   ACTION=delete ./parallel_bulk_action.sh
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

if [[ -z "$BODY" ]]; then
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

  echo "[$label] -> POST ${url}${BULK_PATH}"
  echo "[$label]    body: ${BODY}"

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
    --data "$BODY" \
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

echo "Bulk action: ${ACTION}  dry_run=${DRY_RUN}  targets=${#TARGETS[@]}"
echo "Body: ${BODY}"
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
