#!/usr/bin/env bash
#
# Smoke-test the bulk-create / bulk-enable path for imported security rules.
# Expects N / N / N / N / N for N rules created with the experimental flag on.
#
set -e

KIBANA_URL="http://localhost:5605/kbn"
ES_URL="http://localhost:9204"
AUTH="elastic:changeme"

# 1. Fetch all alerting rules visible to Kibana.
rules_json=$(curl -s -u "$AUTH" \
  "$KIBANA_URL/api/alerting/rules/_find?per_page=500")

# 2. Count security-solution tasks in the task manager index.
task_count=$(curl -s -u "$AUTH" \
  -H 'content-type: application/json' \
  "$ES_URL/.kibana_task_manager/_count" \
  -d '{"query":{"prefix":{"task.taskType":"alerting:siem."}}}' \
  | jq '.count')

# 3. Count security-solution alert SOs whose encrypted apiKey is actually set.
api_key_count=$(curl -s -u "$AUTH" \
  -H 'content-type: application/json' \
  "$ES_URL/.kibana_alerting_cases/_search?size=500&filter_path=hits.hits._source.alert.apiKey" \
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

# 4. Derive the rule-side counts from the rules response.
total=$(jq    '.data | length'                                      <<<"$rules_json")
enabled=$(jq  '[.data[] | select(.enabled)]              | length'  <<<"$rules_json")
owners=$(jq   '[.data[] | select(.api_key_owner != null)] | length' <<<"$rules_json")

# 5. Print a small report. All five numbers should be equal.
printf 'rules:           %s\n' "$total"
printf 'enabled:         %s\n' "$enabled"
printf 'tasks:           %s\n' "$task_count"
printf 'api_key_owner:   %s\n' "$owners"
printf 'apiKey present:  %s\n' "$api_key_count"
