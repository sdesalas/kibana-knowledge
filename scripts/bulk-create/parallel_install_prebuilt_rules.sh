#!/usr/bin/env bash
#
# Hits POST /internal/detection_engine/prebuilt_rules/installation/_perform
# on N Kibana instances in parallel with mode=ALL_RULES.
#
# Targets are loaded from scripts/parallel.env.sh, which must define a TARGETS
# bash array. Each entry is "AUTH|URL" (auth is "user:password").
#
# Override the env file with PARALLEL_ENV_FILE=/path/to/file.
#
# Usage:
#   ./scripts/parallel_install_prebuilt_rules.sh
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${PARALLEL_ENV_FILE:-${SCRIPT_DIR}/.env.sh}"

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

INSTALL_PATH="/internal/detection_engine/prebuilt_rules/installation/_perform"
INSTALL_BODY='{"mode":"ALL_RULES"}'
INSTALL_API_VERSION='1'
INSTALL_BUILD_NUMBER='102936'

DELETE_PATH="/api/detection_engine/rules/_bulk_action?dry_run=false"
DELETE_BODY='{"action":"delete","query":""}'
DELETE_API_VERSION='2023-10-31'
DELETE_BUILD_NUMBER='102774'

KBN_VERSION='9.5.0-SNAPSHOT'
POST_DELETE_WAIT_SECS=10

USER_AGENT='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36'

gen_hex() {
  # Generates `n` random hex chars; falls back if /dev/urandom isn't available.
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

hit() {
  local label="$1"
  local url="$2"
  local auth="$3"
  local path_suffix="$4"
  local body="$5"
  local api_version="$6"
  local build_number="$7"
  local summary_file="$8"

  if [[ -z "$url" || "$url" == ".." ]]; then
    echo "[$label] SKIPPED (URL not configured)"
    printf '%s\tSKIPPED\t-\n' "$label" >>"$summary_file"
    return 0
  fi

  echo "[$label] -> POST ${url}${path_suffix}"

  local tmp_body
  tmp_body="$(mktemp -t kbn_${label}_XXXX)"

  local origin="${url%/}"
  local referer="${origin}/app/security/rules/add_rules"
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
    -H "elastic-api-version: ${api_version}" \
    -H "kbn-build-number: ${build_number}" \
    -H "kbn-version: ${KBN_VERSION}" \
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
    --data "$body" \
    "${url}${path_suffix}")" \
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
  preview="$(head -c 50 "$tmp_body" | tr '\n' ' ')"
  echo "[$label] <- HTTP ${http_code} in ${time_total}s | ${preview}"
  rm -f "$tmp_body"

  printf '%s\t%s\t%ss\n' "$label" "$http_code" "$time_total" >>"$summary_file"
}

run_in_parallel() {
  local phase="$1"
  local path_suffix="$2"
  local body="$3"
  local api_version="$4"
  local build_number="$5"

  echo "=== Phase: ${phase} ==="

  local pids=()
  local summary_files=()
  for i in "${!TARGETS[@]}"; do
    local entry="${TARGETS[$i]}"
    local auth="${entry%%|*}"
    local url="${entry#*|}"
    local target_name
    target_name="${url#*://}"
    target_name="${target_name:0:28}"
    target_name="${target_name//[^a-zA-Z0-9_-]/_}"
    local label="${target_name}-${phase}"

    local sf
    sf="$(mktemp -t kbn_summary_${phase}_XXXX)"
    summary_files+=("$sf")

    hit "$label" "$url" "$auth" "$path_suffix" "$body" \
      "$api_version" "$build_number" "$sf" &
    pids+=($!)
  done

  local rc=0
  for pid in "${pids[@]}"; do
    wait "$pid" || rc=1
  done

  echo "--- ${phase} timings ---"
  printf 'target\thttp\ttime\n'
  for sf in "${summary_files[@]}"; do
    cat "$sf"
    rm -f "$sf"
  done
  echo "------------------------"

  return "$rc"
}

EXIT=0
run_in_parallel "delete" \
  "$DELETE_PATH" "$DELETE_BODY" \
  "$DELETE_API_VERSION" "$DELETE_BUILD_NUMBER" || EXIT=1

echo "Waiting ${POST_DELETE_WAIT_SECS}s before bulk install..."
sleep "$POST_DELETE_WAIT_SECS"

run_in_parallel "install" \
  "$INSTALL_PATH" "$INSTALL_BODY" \
  "$INSTALL_API_VERSION" "$INSTALL_BUILD_NUMBER" || EXIT=1

exit "$EXIT"
