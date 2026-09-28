#!/usr/bin/env bash
#
# Checks that each Kibana in .env.sh TARGETS is up (GET /api/status).
# Optionally POST /api/security_solution/initialize after a successful check.
#
# Override the env file with PARALLEL_ENV_FILE=/path/to/file.
# Enable initialize with INITIALIZE=1 (default: 0).
#
# Usage:
#   ./scripts/bulk-create/check_instances.sh
#   INITIALIZE=1 ./scripts/bulk-create/check_instances.sh
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${PARALLEL_ENV_FILE:-${SCRIPT_DIR}/.env.sh}"
STATUS_PATH="/api/status"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
MAX_TIME="${MAX_TIME:-15}"
INITIALIZE="${INITIALIZE:-0}"
INIT_PATH="/api/security_solution/initialize"
INIT_BODY='{"flows":["create-list-indices","security-data-views","init-prebuilt-rules","init-endpoint-protection","init-ai-prompts","init-detection-rule-monitoring"]}'
INIT_MAX_TIME="${INIT_MAX_TIME:-130}"

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

target_label() {
  local url="$1"
  local name="${url#*://}"
  name="${name%%/*}"
  printf '%s' "$name"
}

status_level() {
  local body="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.status.overall.level // .status.overall.state // empty' <<<"$body" 2>/dev/null
  fi
}

check_one() {
  local url="$1"
  local auth="$2"
  local summary_file="$3"
  local label
  label="$(target_label "$url")"

  if [[ -z "$url" || "$url" == ".." ]]; then
    echo "[$label] SKIPPED (URL not configured)"
    printf '%s\tSKIP\t-\t-\n' "$label" >>"$summary_file"
    return 0
  fi

  local tmp_body
  tmp_body="$(mktemp -t kbn_status_XXXX)"

  local stats
  stats="$(curl -sS \
    -o "$tmp_body" \
    -w '%{http_code} %{time_total}' \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" \
    -u "$auth" \
    -H 'kbn-xsrf: true' \
    "${url}${STATUS_PATH}")" \
    || {
      echo "[$label] DOWN (curl failed)"
      printf '%s\tDOWN\t-\t-\n' "$label" >>"$summary_file"
      rm -f "$tmp_body"
      return 1
    }

  local http_code time_total
  http_code="${stats% *}"
  time_total="${stats##* }"

  local body level
  body="$(cat "$tmp_body")"
  rm -f "$tmp_body"
  level="$(status_level "$body")"
  [[ -z "$level" ]] && level="-"

  if [[ "$http_code" == "200" && "$level" != "unavailable" && "$level" != "red" ]]; then
    echo "[$label] UP  HTTP ${http_code}  ${level}  ${time_total}s"
    if [[ "$INITIALIZE" == "1" ]]; then
      initialize_one "$url" "$auth" "$label" "$summary_file" "$http_code" "$level" "$time_total"
      return $?
    fi
    printf '%s\tUP\t%s\t%s\t%ss\n' "$label" "$http_code" "$level" "$time_total" >>"$summary_file"
    return 0
  fi

  echo "[$label] DOWN  HTTP ${http_code}  ${level}  ${time_total}s"
  printf '%s\tDOWN\t%s\t%s\t%ss\n' "$label" "$http_code" "$level" "$time_total" >>"$summary_file"
  return 1
}

initialize_one() {
  local url="$1"
  local auth="$2"
  local label="$3"
  local summary_file="$4"
  local status_code="$5"
  local level="$6"
  local status_time="$7"

  local tmp_body
  tmp_body="$(mktemp -t kbn_init_XXXX)"

  local stats
  stats="$(curl -sS \
    -o "$tmp_body" \
    -w '%{http_code} %{time_total}' \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$INIT_MAX_TIME" \
    -X POST \
    -u "$auth" \
    -H 'content-type: application/json' \
    -H 'elastic-api-version: 2023-10-31' \
    -H 'kbn-xsrf: true' \
    --data "$INIT_BODY" \
    "${url}${INIT_PATH}")" \
    || {
      echo "[$label] INIT FAIL (curl failed)"
      printf '%s\tUP\t%s\t%s\t%ss\tFAIL\n' "$label" "$status_code" "$level" "$status_time" >>"$summary_file"
      rm -f "$tmp_body"
      return 1
    }

  local http_code time_total
  http_code="${stats% *}"
  time_total="${stats##* }"

  local preview
  preview="$(head -c 80 "$tmp_body" | tr '\n' ' ')"
  rm -f "$tmp_body"

  if [[ "$http_code" == "200" ]]; then
    echo "[$label] INIT OK  HTTP ${http_code}  ${time_total}s  ${preview}"
    printf '%s\tUP\t%s\t%s\t%ss\t%s\n' "$label" "$status_code" "$level" "$status_time" "$http_code" >>"$summary_file"
    return 0
  fi

  echo "[$label] INIT FAIL  HTTP ${http_code}  ${time_total}s  ${preview}"
  printf '%s\tUP\t%s\t%s\t%ss\t%s\n' "$label" "$status_code" "$level" "$status_time" "$http_code" >>"$summary_file"
  return 1
}

echo "Checking ${#TARGETS[@]} instance(s) from ${ENV_FILE}"
if [[ "$INITIALIZE" == "1" ]]; then
  echo "Initialize: on (POST ${INIT_PATH})"
fi
echo

pids=()
summary_files=()
for i in "${!TARGETS[@]}"; do
  entry="${TARGETS[$i]}"
  auth="${entry%%|*}"
  url="${entry#*|}"
  sf="$(mktemp -t kbn_check_XXXX)"
  summary_files+=("$sf")
  check_one "$url" "$auth" "$sf" &
  pids+=($!)
done

rc=0
for pid in "${pids[@]}"; do
  wait "$pid" || rc=1
done

echo
echo "--- summary ---"
if [[ "$INITIALIZE" == "1" ]]; then
  printf 'target\tstate\thttp\tlevel\ttime\tinit\n'
else
  printf 'target\tstate\thttp\tlevel\ttime\n'
fi
for sf in "${summary_files[@]}"; do
  cat "$sf"
  rm -f "$sf"
done
echo "---------------"

if [[ "$rc" -ne 0 ]]; then
  echo "one or more instances are down" >&2
fi
exit "$rc"
