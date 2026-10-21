#!/usr/bin/env bash
#
# Delete exception lists for every TARGET, in parallel.
#
# Preferred path (9.6+ / #285608):
#   POST /internal/api/exception_lists/_bulk_action  (≤100 ids/batch)
# Fallback when bulk returns 404 (e.g. 9.5.4):
#   loop DELETE /api/exception_lists?id=…&namespace_type=single
# so C4 can still be timed and compared (bulk vs single-delete loop).
#
# Finds list saved-object ids via /api/exception_lists/_find, optionally filters
# by list type client-side (API ignores type=).
# Lists referenced by rules return per-id 409 — delete rules first.
#
# Requires: curl, jq
#
# Targets from .env.sh (or PARALLEL_ENV_FILE): "AUTH|KBN_URL"
#
# Env:
#   BATCH_SIZE   default 100 (max allowed by API)
#   PER_PAGE     find page size, default 100
#   TYPE         optional list type filter: detection | rule_default | …
#                empty = delete all found lists (pre-wipe)
#
# Usage:
#   ./parallel_delete_exception_lists.sh
#   TYPE=detection ./parallel_delete_exception_lists.sh
#   TYPE=rule_default PARALLEL_ENV_FILE=/tmp/local.env.sh ./parallel_delete_exception_lists.sh
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${PARALLEL_ENV_FILE:-${SCRIPT_DIR}/.env.sh}"
BATCH_SIZE="${BATCH_SIZE:-100}"
PER_PAGE="${PER_PAGE:-100}"
TYPE="${TYPE:-}"
FIND_API_VERSION='2023-10-31'
BULK_API_VERSION='1'
BULK_PATH='/internal/api/exception_lists/_bulk_action'

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

if [[ "$BATCH_SIZE" -lt 1 || "$BATCH_SIZE" -gt 100 ]]; then
  echo "BATCH_SIZE must be 1..100 (got: ${BATCH_SIZE})" >&2
  exit 2
fi

for cmd in curl jq; do
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

delete_one() {
  local auth="$1" kbn_url="$2" label="$3" summary_file="$4"
  kbn_url="${kbn_url%/}"

  echo "[$label] find exception lists…"

  local ids_file page=1 total=0
  ids_file="$(mktemp -t exc_list_ids_XXXX)"
  : >"$ids_file"

  while true; do
    local chunk http_code
    chunk="$(mktemp -t exc_list_find_XXXX)"
    http_code="$(curl -sS -o "$chunk" -w '%{http_code}' \
      -u "$auth" \
      -H 'kbn-xsrf: true' \
      -H "elastic-api-version: ${FIND_API_VERSION}" \
      "${kbn_url}/api/exception_lists/_find?page=${page}&per_page=${PER_PAGE}")" \
      || { echo "[$label] _find curl failed"; rm -f "$chunk" "$ids_file"; printf '%s\tERROR\t-\t-\n' "$label" >>"$summary_file"; return 1; }
    if [[ "$http_code" != "200" ]]; then
      echo "[$label] _find HTTP ${http_code}: $(head -c 300 "$chunk")"
      rm -f "$chunk" "$ids_file"
      printf '%s\t%s\t-\t-\n' "$label" "$http_code" >>"$summary_file"
      return 1
    fi
    total="$(jq -r '.total // 0' "$chunk")"
    # _find has no reliable type= filter — filter client-side when TYPE is set.
    if [[ -n "$TYPE" ]]; then
      jq -r --arg t "$TYPE" '.data[]? | select(.type == $t) | .id' "$chunk" >>"$ids_file"
    else
      jq -r '.data[]? | .id' "$chunk" >>"$ids_file"
    fi
    rm -f "$chunk"
    if [[ $((page * PER_PAGE)) -ge "$total" ]]; then
      break
    fi
    page=$((page + 1))
  done

  local id_count
  id_count="$(wc -l <"$ids_file" | tr -d ' ')"
  if [[ -n "$TYPE" ]]; then
    echo "[$label] lists=${id_count} type=${TYPE} (find.total=${total})"
  else
    echo "[$label] lists=${id_count} (find.total=${total})"
  fi

  if [[ "$id_count" -eq 0 ]]; then
    echo "[$label] nothing to delete"
    printf '%s\t200\t0.000\t0\n' "$label" >>"$summary_file"
    rm -f "$ids_file"
    return 0
  fi

  local batch_n=0 succeeded=0 failed=0 elapsed_s=0 stats http_code time_total
  local offset=0 batch_ids body resp batch_ok batch_fail mode=bulk

  # Probe bulk with first batch; on 404 fall back to single-DELETE loop for all ids.
  batch_ids="$(sed -n "1,${BATCH_SIZE}p" "$ids_file")"
  body="$(printf '%s\n' "$batch_ids" | jq -Rsc \
    '{action:"delete", ids: (split("\n") | map(select(length>0))), namespace_type:"single"}')"
  resp="$(mktemp -t exc_list_bulk_XXXX)"
  stats="$(curl -sS -o "$resp" -w '%{http_code} %{time_total}' \
    -X POST \
    -u "$auth" \
    -H 'kbn-xsrf: true' \
    -H 'content-type: application/json' \
    -H "elastic-api-version: ${BULK_API_VERSION}" \
    -H 'x-elastic-internal-origin: Kibana' \
    --data "$body" \
    "${kbn_url}${BULK_PATH}")" \
    || { echo "[$label] bulk curl failed"; rm -f "$resp" "$ids_file"; printf '%s\tERROR\t-\t%s\n' "$label" "$id_count" >>"$summary_file"; return 1; }

  http_code="${stats% *}"
  time_total="${stats##* }"

  if [[ "$http_code" == "404" ]]; then
    mode=single
    echo "[$label] bulk HTTP 404 — falling back to single DELETE loop (${id_count} lists)"
    rm -f "$resp"
    elapsed_s=0
    succeeded=0
    failed=0
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      resp="$(mktemp -t exc_list_del_XXXX)"
      stats="$(curl -sS -o "$resp" -w '%{http_code} %{time_total}' \
        -X DELETE \
        -u "$auth" \
        -H 'kbn-xsrf: true' \
        -H "elastic-api-version: ${FIND_API_VERSION}" \
        "${kbn_url}/api/exception_lists?id=${id}&namespace_type=single")" \
        || { echo "[$label] single DELETE curl failed id=$id"; rm -f "$resp"; failed=$((failed + 1)); continue; }
      http_code="${stats% *}"
      time_total="${stats##* }"
      elapsed_s="$(awk -v a="$elapsed_s" -v b="$time_total" 'BEGIN { printf "%.6f", a+b }')"
      if [[ "$http_code" == "200" ]]; then
        succeeded=$((succeeded + 1))
        echo "[$label] DELETE id=${id} ok ${time_total}s"
      else
        failed=$((failed + 1))
        echo "[$label] DELETE id=${id} HTTP ${http_code}: $(head -c 200 "$resp")"
      fi
      rm -f "$resp"
    done <"$ids_file"
    rm -f "$ids_file"
    echo "[$label] done mode=single succeeded=${succeeded} failed=${failed} time=${elapsed_s}s"
    printf '%s\tsingle\t%ss\t%s\n' "$label" "$elapsed_s" "$succeeded" >>"$summary_file"
    [[ "$failed" -gt 0 ]] && return 1
    return 0
  fi

  if [[ "$http_code" != "200" ]]; then
    echo "[$label] bulk HTTP ${http_code}: $(head -c 400 "$resp")"
    rm -f "$resp" "$ids_file"
    printf '%s\t%s\t%ss\t0\n' "$label" "$http_code" "$time_total" >>"$summary_file"
    return 1
  fi

  # First bulk batch succeeded — continue remaining batches.
  elapsed_s="$time_total"
  batch_ok="$(jq -r '.summary.succeeded // 0' "$resp")"
  batch_fail="$(jq -r '.summary.failed // 0' "$resp")"
  succeeded=$((succeeded + batch_ok))
  failed=$((failed + batch_fail))
  batch_n=1
  if [[ "$batch_fail" -gt 0 ]]; then
    echo "[$label] batch ${batch_n}: ok=${batch_ok} fail=${batch_fail} ${time_total}s sample=$(jq -c '[.errors[:2][]?]' "$resp")"
  else
    echo "[$label] batch ${batch_n}: ok=${batch_ok} ${time_total}s"
  fi
  rm -f "$resp"
  offset=$BATCH_SIZE

  while [[ "$offset" -lt "$id_count" ]]; do
    batch_ids="$(sed -n "$((offset + 1)),$((offset + BATCH_SIZE))p" "$ids_file")"
    body="$(printf '%s\n' "$batch_ids" | jq -Rsc \
      '{action:"delete", ids: (split("\n") | map(select(length>0))), namespace_type:"single"}')"
    resp="$(mktemp -t exc_list_bulk_XXXX)"
    stats="$(curl -sS -o "$resp" -w '%{http_code} %{time_total}' \
      -X POST \
      -u "$auth" \
      -H 'kbn-xsrf: true' \
      -H 'content-type: application/json' \
      -H "elastic-api-version: ${BULK_API_VERSION}" \
      -H 'x-elastic-internal-origin: Kibana' \
      --data "$body" \
      "${kbn_url}${BULK_PATH}")" \
      || { echo "[$label] bulk curl failed"; rm -f "$resp" "$ids_file"; printf '%s\tERROR\t-\t%s\n' "$label" "$id_count" >>"$summary_file"; return 1; }

    http_code="${stats% *}"
    time_total="${stats##* }"
    elapsed_s="$(awk -v a="$elapsed_s" -v b="$time_total" 'BEGIN { printf "%.6f", a+b }')"

    if [[ "$http_code" != "200" ]]; then
      echo "[$label] bulk HTTP ${http_code}: $(head -c 400 "$resp")"
      rm -f "$resp" "$ids_file"
      printf '%s\t%s\t%ss\t%s\n' "$label" "$http_code" "$elapsed_s" "$succeeded" >>"$summary_file"
      return 1
    fi

    batch_ok="$(jq -r '.summary.succeeded // 0' "$resp")"
    batch_fail="$(jq -r '.summary.failed // 0' "$resp")"
    succeeded=$((succeeded + batch_ok))
    failed=$((failed + batch_fail))
    batch_n=$((batch_n + 1))
    if [[ "$batch_fail" -gt 0 ]]; then
      echo "[$label] batch ${batch_n}: ok=${batch_ok} fail=${batch_fail} ${time_total}s sample=$(jq -c '[.errors[:2][]?]' "$resp")"
    else
      echo "[$label] batch ${batch_n}: ok=${batch_ok} ${time_total}s"
    fi
    rm -f "$resp"
    offset=$((offset + BATCH_SIZE))
  done

  rm -f "$ids_file"

  echo "[$label] done mode=bulk batches=${batch_n} succeeded=${succeeded} failed=${failed} time=${elapsed_s}s"
  printf '%s\t200\t%ss\t%s\n' "$label" "$elapsed_s" "$succeeded" >>"$summary_file"

  if [[ "$failed" -gt 0 ]]; then
    return 1
  fi
  return 0
}

if [[ -n "$TYPE" ]]; then
  echo "delete exception lists  type=${TYPE}  batch_size=${BATCH_SIZE}  targets=${#TARGETS[@]}"
else
  echo "delete exception lists  type=ALL  batch_size=${BATCH_SIZE}  targets=${#TARGETS[@]}"
fi
echo

pids=()
summary_files=()
for entry in "${TARGETS[@]}"; do
  auth="${entry%%|*}"
  # tolerate optional |ES_URL third field
  rest="${entry#*|}"
  kbn_url="${rest%%|*}"
  label="$(slug_from_url "$kbn_url")"
  sf="$(mktemp -t kbn_summary_exc_XXXX)"
  summary_files+=("$sf")
  delete_one "$auth" "$kbn_url" "$label" "$sf" &
  pids+=("$!")
done

rc=0
for pid in "${pids[@]}"; do
  wait "$pid" || rc=1
done

echo
echo "--- exception-list delete timings ---"
printf 'target\thttp\ttime\tdeleted\n'
for sf in "${summary_files[@]}"; do
  cat "$sf"
  rm -f "$sf"
done
echo "-------------------------------------"

exit "$rc"
