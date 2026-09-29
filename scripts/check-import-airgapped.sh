#!/usr/bin/env bash
#
# Repro: rules/_import fails when the prebuilt rules package can't be installed
# (offline, no bundled package) even if the file has no valid rules.
# Run against a clean ES + Kibana. Don't open the Security app during the test.
#

KIBANA_URL="http://localhost:${KIBANA_DEV_PORT:-5601}/kbn"
AUTH="elastic:changeme"
TMP_DIR="${TMPDIR:-/tmp}"
EXC_FILE="$TMP_DIR/exc_only.ndjson"
RULE_FILE="$TMP_DIR/valid_rule.ndjson"

ts() { echo -e "\n=== $(date '+%H:%M:%S') $* ==="; }
kb() { curl -s --max-time 120 -u "$AUTH" -H 'elastic-api-version: 2023-10-31' -H 'kbn-xsrf: true' "$@"; }
pause() { read -r -p ">>> $* then press Enter "; }

echo "KIBANA_URL=$KIBANA_URL"

ts "1. wait for Kibana"
until kb "$KIBANA_URL/api/status" | jq -e '.status.overall.level=="available"' >/dev/null 2>&1; do sleep 5; done
echo ready

ts "2a. rules package status (expect \"not_installed\")"
kb "$KIBANA_URL/api/fleet/epm/packages/security_detection_engine" | jq .item.status
ts "2b. exception lists (expect total 0)"
kb "$KIBANA_URL/api/exception_lists/_find?namespace_type=single" | jq '{total, ids: [.data[].list_id]}'
ts "2c. rules (expect 0)"
kb "$KIBANA_URL/api/detection_engine/rules/_find?per_page=1" | jq .total

ts "3. fixtures"
echo '{"list_id":"test-exc-list","name":"Test list","description":"test","type":"detection","namespace_type":"single","tags":[],"os_types":[]}' > "$EXC_FILE"
echo '{"rule_id":"test-rule-1","name":"Test rule","description":"test","type":"query","query":"*:*","index":["logs-*"],"risk_score":21,"severity":"low","enabled":false,"version":1}' > "$RULE_FILE"
wc -l "$EXC_FILE" "$RULE_FILE"

pause "Turn OFF Wi-Fi"
ts "4. offline check (expect offline)"
curl -s --max-time 5 https://epr.elastic.co >/dev/null && echo "STILL ONLINE" || echo "offline"

ts "5. import exception list only, offline (expect HTTP 500)"
kb -w '\nHTTP %{http_code}\n' -X POST "$KIBANA_URL/api/detection_engine/rules/_import" -F "file=@$EXC_FILE"

ts "6. exception lists after failed import (expect total 1, test-exc-list)"
kb "$KIBANA_URL/api/exception_lists/_find?namespace_type=single" | jq '{total, ids: [.data[].list_id]}'

ts "7a. import valid rule, offline (expect HTTP 500, pre-existing behaviour)"
kb -w '\nHTTP %{http_code}\n' -X POST "$KIBANA_URL/api/detection_engine/rules/_import" -F "file=@$RULE_FILE"
ts "7b. rules after failed import (expect 0)"
kb "$KIBANA_URL/api/detection_engine/rules/_find?per_page=1" | jq .total

pause "Turn ON Wi-Fi"
ts "8. rules package status, back online (expect \"not_installed\")"
kb "$KIBANA_URL/api/fleet/epm/packages/security_detection_engine" | jq .item.status

ts "done"
