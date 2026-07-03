#!/usr/bin/env bash
#
# Complements check-tasks.sh. Verifies the dependency bits that the bulk
# prebuilt-rule install path can drop: exception-list references and
# connector (action) references on installed security-solution rules.
#
# Special attention to the rules that ship ENABLED and carry dependencies:
#   Endpoint Security (Elastic Defend)  9a1a2dae-0b5f-4c3d-8305-a268d404c306  -> endpoint_list
#   Container Workload Protection        4b4e9c99-27ea-4621-95c8-82341bc6e512  -> (none)
#
# Ports default to the dev defaults; override for a custom stack, e.g.
#   KIBANA_DEV_PORT=5604 ES_DEV_PORT=9203 ./check-exceptions-connectors.sh
#
set -e

echo "starting.."

KIBANA_URL="http://localhost:${KIBANA_DEV_PORT:-5601}/kbn"
ES_URL="http://localhost:${ES_DEV_PORT:-9200}"
AUTH="elastic:changeme"

echo "KIBANA_URL=$KIBANA_URL"
echo "ES_URL=$ES_URL"

printf "1. "

# 1. Fetch security-solution alerting rules (params carry exceptionsList + ruleId; actions at top level).
rules_json=$(curl -s -u "$AUTH" \
  --get "$KIBANA_URL/api/alerting/rules/_find" \
  --data-urlencode "per_page=2000" \
  --data-urlencode 'filter=alert.attributes.alertTypeId:siem.*')
total=$(jq '.data | length' <<<"$rules_json")

printf "2. "

# 2. Exception-list references declared by the rules themselves.
rules_with_exceptions=$(jq '[.data[] | select((.params.exceptionsList // []) | length > 0)] | length' <<<"$rules_json")
referenced_lists=$(jq -r '[.data[].params.exceptionsList // [] | .[].list_id] | unique | .[]' <<<"$rules_json")

printf "3. "

# 3. Exception lists that actually exist in ES (default + agnostic namespaces).
lists_json=$(curl -s -u "$AUTH" -H 'content-type: application/json' \
  "$ES_URL/.kibana*/_search?size=1000&filter_path=hits.hits._source" \
  -d '{
    "query": { "bool": { "should": [
      { "term": { "type": "exception-list" } },
      { "term": { "type": "exception-list-agnostic" } }
    ]}},
    "_source": ["exception-list.list_id","exception-list-agnostic.list_id"]
  }')
existing_lists=$(jq -r '[.hits.hits[]?._source | (."exception-list".list_id // ."exception-list-agnostic".list_id)] | map(select(. != null)) | unique | .[]' <<<"$lists_json")
endpoint_list_present=$(grep -qx "endpoint_list" <<<"$existing_lists" && echo yes || echo no)
missing_lists=$(comm -23 <(sort -u <<<"$referenced_lists") <(sort -u <<<"$existing_lists") || true)

printf "4. "

# 4. Connectors present in Kibana + action references declared by the rules.
connectors_json=$(curl -s -u "$AUTH" "$KIBANA_URL/api/actions/connectors")
connector_count=$(jq 'length' <<<"$connectors_json")
existing_connectors=$(jq -r '.[].id' <<<"$connectors_json")
rules_with_actions=$(jq '[.data[] | select((.actions // []) | length > 0)] | length' <<<"$rules_json")
referenced_connectors=$(jq -r '[.data[].actions // [] | .[].id] | unique | .[]' <<<"$rules_json")
missing_connectors=$(comm -23 <(sort -u <<<"$referenced_connectors") <(sort -u <<<"$existing_connectors") || true)

echo "5."

# 5. Report.
printf 'rules (siem.*):        %s\n' "$total"
printf 'rules w/ exceptions:   %s\n' "$rules_with_exceptions"
printf 'endpoint_list present: %s\n' "$endpoint_list_present"
printf 'connectors:            %s\n' "$connector_count"
printf 'rules w/ actions:      %s\n' "$rules_with_actions"

echo
echo "dangling exception-list refs (referenced by a rule but missing in ES):"
if [[ -n "$missing_lists" ]]; then echo "$missing_lists" | sed 's/^/  - /'; else echo "  (none)"; fi

echo
echo "dangling connector refs (referenced by a rule but missing in Kibana):"
if [[ -n "$missing_connectors" ]]; then echo "$missing_connectors" | sed 's/^/  - /'; else echo "  (none)"; fi

echo
echo "first 10 rules (enabled first, then last updated DESC):"
jq -r '
  def row($r): [
    ($r.name[0:30]),
    ($r.enabled | tostring),
    ($r.updated_at // "-"),
    (($r.params.exceptionsList // []) | length | tostring),
    (($r.actions // []) | length | tostring),
    ((($r.params.exceptionsList // []) | map(.list_id) | join(",")) // "-")
  ];
  ["name","enabled","updated_at","exceptions","actions","exception_list_ids"],
  (.data | sort_by([.enabled, .updated_at]) | reverse | .[0:10][] | row(.))
  | @tsv
' <<<"$rules_json" | column -t -s $'\t'
