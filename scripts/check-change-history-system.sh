#!/usr/bin/env bash
#
# Check whether the `.kibana_change_history` data stream and its backing
# indices are flagged as system by Elasticsearch.
#
set -e

ES_URL="http://localhost:${ES_DEV_PORT:-9200}"
AUTH="${ES_AUTH:-elastic:changeme}"
DS_NAME=".kibana_change_history"

if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
else
  C_RESET= C_BOLD= C_DIM= C_RED= C_GREEN= C_YELLOW= C_BLUE= C_CYAN=
fi

fmt_bool() {
  case "$1" in
    true)  printf '%strue%s'  "$C_GREEN" "$C_RESET" ;;
    false) printf '%sfalse%s' "$C_RED"   "$C_RESET" ;;
    *)     printf '%s%s%s'    "$C_DIM"   "$1" "$C_RESET" ;;
  esac
}

printf '%sES_URL%s      = %s\n' "$C_BOLD" "$C_RESET" "$ES_URL"
printf '%sdata_stream%s = %s\n' "$C_BOLD" "$C_RESET" "$DS_NAME"
echo

if ! curl -sf -o /dev/null -u "$AUTH" --connect-timeout 3 "$ES_URL"; then
  printf '%sError:%s Cannot reach %s\n' "$C_RED$C_BOLD" "$C_RESET" "$ES_URL" >&2
  exit 1
fi

# 1. Data stream itself.
ds_json=$(curl -s -u "$AUTH" \
  -H 'X-Elastic-Product-Origin: kibana' \
  "$ES_URL/_data_stream/$DS_NAME")

ds_exists=$(jq '[.data_streams[]?] | length > 0' <<<"$ds_json")

if [[ "$ds_exists" != "true" ]]; then
  printf '%sdata stream %s%s%s not found%s\n' \
    "$C_RED" "$C_BOLD" "$DS_NAME" "$C_RESET$C_RED" "$C_RESET" >&2
  echo "$ds_json" | jq .
  exit 1
fi

ds_system=$(jq  '.data_streams[0].system'  <<<"$ds_json")
ds_hidden=$(jq  '.data_streams[0].hidden'  <<<"$ds_json")
ds_managed=$(jq '.data_streams[0]._meta.managed // false' <<<"$ds_json")

printf '%sdata stream%s    system=%s  hidden=%s  managed=%s\n' \
  "$C_BOLD" "$C_RESET" \
  "$(fmt_bool "$ds_system")" \
  "$(fmt_bool "$ds_hidden")" \
  "$(fmt_bool "$ds_managed")"

# 2. Backing indices via _resolve/index (returns attributes incl. "system").
resolve_json=$(curl -s -u "$AUTH" \
  -H 'X-Elastic-Product-Origin: kibana' \
  "$ES_URL/_resolve/index/.ds-${DS_NAME}-*?expand_wildcards=all")

echo
printf '%sbacking indices:%s\n' "$C_BOLD" "$C_RESET"
while IFS=$'\t' read -r name attrs is_sys; do
  [[ -z "$name" ]] && continue
  if [[ "$is_sys" == "true" ]]; then
    tag="${C_GREEN}SYSTEM${C_RESET}"
  else
    tag="${C_RED}NOT SYSTEM${C_RESET}"
  fi
  printf '  %s%s%s  %sattributes=[%s]%s  %s\n' \
    "$C_CYAN" "$name" "$C_RESET" "$C_DIM" "$attrs" "$C_RESET" "$tag"
done < <(jq -r '.indices[]? | [
    .name,
    (.attributes | join(",")),
    ((.attributes | index("system")) != null | tostring)
  ] | @tsv' <<<"$resolve_json")

# 3. Probe: try to read docs without the product-origin header. If the DS/index
# is truly system-restricted, ES rejects with 400 illegal_argument_exception.
probe() {
  local target="$1"
  local body http tag detail hits reason ok=1
  body=$(mktemp)
  http=$(curl -s -o "$body" -w '%{http_code}' -u "$AUTH" \
    -X POST "$ES_URL/${target}/_search?size=1")
  if [[ "$http" == "200" ]]; then
    hits=$(jq '.hits.total.value // (.hits.hits | length)' <"$body" 2>/dev/null || echo "?")
    tag="${C_RED}${C_BOLD}LEAK${C_RESET}"
    detail="http=$http hits=$hits"
    ok=0
  elif [[ "$http" == "400" ]]; then
    reason=$(jq -r '.error.reason // ""' <"$body" 2>/dev/null)
    if [[ "$reason" == *"reserved for system operations"* ]]; then
      tag="${C_GREEN}OK${C_RESET}  "
      detail="http=$http (system-restricted)"
    else
      tag="${C_YELLOW}FAIL${C_RESET}"
      detail="http=$http reason=$reason"
      ok=0
    fi
  else
    reason=$(jq -r '.error.reason // ""' <"$body" 2>/dev/null)
    tag="${C_YELLOW}FAIL${C_RESET}"
    detail="http=$http reason=$reason"
    ok=0
  fi
  rm -f "$body"
  printf '  %s %s%s%s  %s%s%s\n' \
    "$tag" "$C_CYAN" "$target" "$C_RESET" "$C_DIM" "$detail" "$C_RESET"
  return $ok
}

echo
printf '%sread probe%s %s(no product-origin header, should be rejected)%s:\n' \
  "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
probe_ok=true
probe "$DS_NAME" || probe_ok=false
while read -r idx; do
  [[ -z "$idx" ]] && continue
  probe "$idx" || probe_ok=false
done < <(jq -r '.indices[]?.name' <<<"$resolve_json")

# 4. Summary: fail loudly if the DS or any backing index is not marked system.
missing=$(jq '[.indices[]? | select((.attributes | index("system")) | not) | .name]' \
  <<<"$resolve_json")
missing_count=$(jq 'length' <<<"$missing")

echo
if [[ "$ds_system" == "true" && "$missing_count" == "0" && "$probe_ok" == "true" ]]; then
  printf '%s%sOK%s: data stream and all backing indices are system and reads are blocked\n' \
    "$C_GREEN" "$C_BOLD" "$C_RESET"
  exit 0
fi

printf '%s%sPROBLEM:%s\n' "$C_RED" "$C_BOLD" "$C_RESET"
[[ "$ds_system" != "true" ]] && \
  printf '  %s-%s data stream is %sNOT system%s\n' "$C_RED" "$C_RESET" "$C_RED" "$C_RESET"
if [[ "$missing_count" != "0" ]]; then
  printf '  %s-%s backing indices missing %ssystem%s attribute:\n' \
    "$C_RED" "$C_RESET" "$C_RED" "$C_RESET"
  jq -r '.[] | "      \(.)"' <<<"$missing"
fi
[[ "$probe_ok" != "true" ]] && \
  printf '  %s-%s one or more read probes were %snot rejected%s as system-restricted\n' \
    "$C_RED" "$C_RESET" "$C_RED" "$C_RESET"
exit 2
