#!/usr/bin/env bash
#
# Checks that each Kibana in .env.sh TARGETS is up (GET /api/status).
#
# Override the env file with PARALLEL_ENV_FILE=/path/to/file.
#
# Usage:
#   ./scripts/bulk-create/check_instances.sh
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${PARALLEL_ENV_FILE:-${SCRIPT_DIR}/.env.sh}"
STATUS_PATH="/api/status"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
MAX_TIME="${MAX_TIME:-15}"

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
    printf '%s\tUP\t%s\t%s\t%ss\n' "$label" "$http_code" "$level" "$time_total" >>"$summary_file"
    return 0
  fi

  echo "[$label] DOWN  HTTP ${http_code}  ${level}  ${time_total}s"
  printf '%s\tDOWN\t%s\t%s\t%ss\n' "$label" "$http_code" "$level" "$time_total" >>"$summary_file"
  return 1
}

echo "Checking ${#TARGETS[@]} instance(s) from ${ENV_FILE}"
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
printf 'target\tstate\thttp\tlevel\ttime\n'
for sf in "${summary_files[@]}"; do
  cat "$sf"
  rm -f "$sf"
done
echo "---------------"

if [[ "$rc" -ne 0 ]]; then
  echo "one or more instances are down" >&2
fi
exit "$rc"
