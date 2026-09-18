#!/usr/bin/env bash
#
# Inventory detection rules, exception-list containers/items, and the
# rule → list associations (which lists hang off which rule).
#
# Ports default to the dev defaults; override for a custom stack, e.g.
#   KIBANA_DEV_PORT=5603 ./check-exceptions.sh
#   SPACE=default ./check-exceptions.sh     # one space
#   SPACE=all ./check-exceptions.sh         # every space (default)
#
set -euo pipefail

echo "starting.."

KIBANA_URL="http://localhost:${KIBANA_DEV_PORT:-5601}/kbn"
AUTH="elastic:changeme"
SPACE="${SPACE:-all}"

echo "KIBANA_URL=$KIBANA_URL"
echo "SPACE=$SPACE"

kbn() {
  curl -s -u "$AUTH" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: Kibana" \
    -H "elastic-api-version: 2023-10-31" \
    "$@"
}

space_prefix() {
  local id="$1"
  if [[ "$id" == "default" ]]; then
    echo ""
  else
    echo "/s/${id}"
  fi
}

printf "1. "

# 1. Spaces.
spaces_json=$(kbn "$KIBANA_URL/api/spaces/space")
if [[ "$SPACE" == "all" ]]; then
  # shellcheck disable=SC2207
  spaces=($(jq -r '.[].id' <<<"$spaces_json"))
else
  spaces=("$SPACE")
fi
echo "spaces: ${spaces[*]}"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

printf "2. "

# 2. Detection rules per space (exceptions_list lives here).
for id in "${spaces[@]}"; do
  prefix=$(space_prefix "$id")
  kbn --get "$KIBANA_URL${prefix}/api/detection_engine/rules/_find" \
    --data-urlencode "per_page=1000" \
    >"$tmpdir/rules-${id}.json"
done

printf "3. "

# 3. Exception list containers (single + agnostic) per space.
for id in "${spaces[@]}"; do
  prefix=$(space_prefix "$id")
  kbn --get "$KIBANA_URL${prefix}/api/exception_lists/_find" \
    --data-urlencode "per_page=1000" \
    --data-urlencode "namespace_type=single,agnostic" \
    >"$tmpdir/lists-${id}.json"
done

printf "4. "

# 4. Item counts per container. Agnostic lists are the same SO in every space,
# so only fetch once (keyed by namespace_type + list_id).
: >"$tmpdir/seen"
for id in "${spaces[@]}"; do
  prefix=$(space_prefix "$id")
  while IFS=$'\t' read -r list_id ns; do
    [[ -z "$list_id" ]] && continue
    key="${ns}|${list_id}"
    if grep -Fxq "$key" "$tmpdir/seen"; then
      continue
    fi
    echo "$key" >>"$tmpdir/seen"
    kbn --get "$KIBANA_URL${prefix}/api/exception_lists/items/_find" \
      --data-urlencode "list_id=${list_id}" \
      --data-urlencode "namespace_type=${ns}" \
      --data-urlencode "per_page=1" \
      >"$tmpdir/items-${ns}-${list_id}.json"
  done < <(python3 - "$tmpdir/lists-${id}.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f).get("data") or []
for lst in data:
    print(f"{lst.get('list_id','')}\t{lst.get('namespace_type','single')}")
PY
)
done

echo "5."

# 5. Report: counts, then rule → list associations, then orphan lists.
python3 - "$tmpdir" "${spaces[@]}" <<'PY'
import json, os, sys

tmpdir = sys.argv[1]
spaces = sys.argv[2:]

def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default

def items_total(ns, list_id):
    path = os.path.join(tmpdir, f"items-{ns}-{list_id}.json")
    body = load(path, {})
    return body.get("total", 0)

print("summary")
for space in spaces:
    rules = load(os.path.join(tmpdir, f"rules-{space}.json"), {}).get("data") or []
    lists = load(os.path.join(tmpdir, f"lists-{space}.json"), {}).get("data") or []
    with_exc = [r for r in rules if r.get("exceptions_list")]
    item_sum = sum(items_total(lst.get("namespace_type") or "single", lst["list_id"]) for lst in lists)
    print(f"  [{space}]  rules={len(rules)}  rules_w_exceptions={len(with_exc)}  lists={len(lists)}  items={item_sum}")

print()
print("rule → list associations")
print("    {:6}  {:13}  {:8}  {:>5}  {}".format("id", "type", "ns", "items", "list"))
for space in spaces:
    rules = load(os.path.join(tmpdir, f"rules-{space}.json"), {}).get("data") or []
    lists = load(os.path.join(tmpdir, f"lists-{space}.json"), {}).get("data") or []
    by_id = {lst["id"]: lst for lst in lists}
    by_list_id = {(lst.get("namespace_type") or "single", lst["list_id"]): lst for lst in lists}
    if not rules:
        print(f"  [{space}] (no rules)")
        continue
    for rule in rules:
        rname = rule.get("name") or rule.get("id") or ""
        print()
        print(f"  [{space}] {rname}")
        refs = rule.get("exceptions_list") or []
        if not refs:
            print("    {:6}  {:13}  {:8}  {:>5}  {}".format("-", "-", "-", "-", "(none)"))
            continue
        for ref in refs:
            ns = ref.get("namespace_type") or "single"
            list_id = ref.get("list_id") or ""
            so_id = ref.get("id") or ""
            short_id = so_id[:6] if so_id else "-"
            lst = by_id.get(so_id) or by_list_id.get((ns, list_id))
            if lst:
                lname = lst.get("name") or list_id
                ltype = lst.get("type") or ref.get("type") or "-"
                total = items_total(ns, list_id)
                dangling = ""
            else:
                lname = list_id or so_id or "?"
                ltype = ref.get("type") or "-"
                total = "-"
                dangling = "  DANGLING"
            print(f"    {short_id:6}  {ltype:13}  {ns:8}  {str(total):>5}  {lname}{dangling}")

print()
print("lists not referenced by any rule in that space")
print("  {:8}  {:6}  {:13}  {:8}  {:>5}  {}".format("space", "id", "type", "ns", "items", "list"))
for space in spaces:
    rules = load(os.path.join(tmpdir, f"rules-{space}.json"), {}).get("data") or []
    lists = load(os.path.join(tmpdir, f"lists-{space}.json"), {}).get("data") or []
    referenced = {(ref.get("namespace_type") or "single", ref.get("list_id"))
                  for rule in rules for ref in (rule.get("exceptions_list") or [])}
    orphans = []
    for lst in lists:
        key = (lst.get("namespace_type") or "single", lst["list_id"])
        if key not in referenced:
            orphans.append(lst)
    if not orphans:
        print(f"  {space:8}  {'-':6}  {'-':13}  {'-':8}  {'-':>5}  (none)")
        continue
    for lst in orphans:
        ns = lst.get("namespace_type") or "single"
        total = items_total(ns, lst["list_id"])
        name = lst.get("name") or lst["list_id"]
        short_id = (lst.get("id") or "-")[:6]
        print(f"  {space:8}  {short_id:6}  {lst.get('type','-'):13}  {ns:8}  {str(total):>5}  {name}")
PY
