#!/usr/bin/env bash
#
# Smoke-test the bulk-create / bulk-enable path for imported security rules.
# Expects N / N / N / N / N for N rules created with the experimental flag on.
#
set -e

echo "starting.."

KIBANA_URL="http://localhost:${KIBANA_DEV_PORT:-5601}/kbn"
ES_URL="http://localhost:${ES_DEV_PORT:-9204}"
AUTH="elastic:changeme"

echo "KIBANA_URL=$KIBANA_URL"
echo "ES_URL=$ES_URL"

printf "1. "

# 1. Fetch security-solution alerting rules visible to Kibana.
rules_json=$(curl -s -u "$AUTH" \
  --get "$KIBANA_URL/api/alerting/rules/_find" \
  --data-urlencode "per_page=1000" \
  --data-urlencode 'filter=alert.attributes.alertTypeId:siem.*')

printf "2. "

# 2. Count security-solution tasks (total + enabled) in the task manager index.
tasks_json=$(curl -s -u "$AUTH" \
  -H 'content-type: application/json' \
  "$ES_URL/.kibana_task_manager/_search?size=0&track_total_hits=true" \
  -d '{
    "query": { "prefix": { "task.taskType": "alerting:siem." } },
    "aggs":  { "enabled": { "filter": { "term": { "task.enabled": true } } } }
  }')
task_count=$(jq         '.hits.total.value'           <<<"$tasks_json")
task_enabled_count=$(jq '.aggregations.enabled.doc_count' <<<"$tasks_json")

printf "3. "

# 3. Count security-solution alert SOs whose encrypted apiKey is actually set.
api_key_count=$(curl -s -u "$AUTH" \
  -H 'content-type: application/json' \
  "$ES_URL/.kibana_alerting_cases/_search?size=2000&filter_path=hits.hits._source.alert.apiKey" \
  -d '{
    "query": {
      "bool": {
        "filter": [
          { "term":   { "type": "alert" } },
          { "prefix": { "alert.alertTypeId": "siem." } }
        ]
      }
    },
    "_source": ["alert.apiKey"]
  }' \
  | jq '[.hits.hits[]?._source.alert.apiKey | select(. != null and . != "")] | length')

printf "4. "

# 4. Derive the rule-side counts from the rules response.
total=$(jq    '.data | length'                                      <<<"$rules_json")
enabled=$(jq  '[.data[] | select(.enabled)]              | length'  <<<"$rules_json")
owners=$(jq   '[.data[] | select(.api_key_owner != null)] | length' <<<"$rules_json")

echo "5."

# 5. Print a small report. All five numbers should be equal.
printf 'rules:           %s\n' "$total"
printf 'rules_enabled:   %s\n' "$enabled"
printf 'tasks:           %s\n' "$task_count"
printf 'tasks_enabled:   %s\n' "$task_enabled_count"
printf 'api_key_owner:   %s\n' "$owners"
printf 'apiKey present:  %s\n' "$api_key_count"
