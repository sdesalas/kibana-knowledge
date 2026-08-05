#!/usr/bin/env bash
# beforeMCPExecution: surface Slack (and other) MCP call details in the approval UI.
set -euo pipefail

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
tool_input=$(printf '%s' "$input" | jq -c '.tool_input // {}')

# tool_input may be a JSON string or object depending on Cursor version
if printf '%s' "$tool_input" | jq -e 'type == "string"' >/dev/null 2>&1; then
  parsed=$(printf '%s' "$tool_input" | jq -r '.' | jq -c '.' 2>/dev/null || echo '{}')
else
  parsed=$tool_input
fi

is_slack=0
if [[ "$tool_name" == *slack* ]] || [[ "$tool_name" == *Slack* ]]; then
  is_slack=1
fi

query=$(printf '%s' "$parsed" | jq -r '.query // empty')
channel_id=$(printf '%s' "$parsed" | jq -r '.channel_id // empty')
limit=$(printf '%s' "$parsed" | jq -r '.limit // empty')
content_types=$(printf '%s' "$parsed" | jq -r '.content_types // empty')

summary="MCP: ${tool_name}"
[[ -n "$query" ]] && summary+=$'\n'"query: ${query}"
[[ -n "$channel_id" ]] && summary+=$'\n'"channel_id: ${channel_id}"
[[ -n "$limit" ]] && summary+=$'\n'"limit: ${limit}"
[[ -n "$content_types" ]] && summary+=$'\n'"content_types: ${content_types}"

# Compact fallback when no common fields present
if [[ -z "$query" && -z "$channel_id" ]]; then
  compact=$(printf '%s' "$parsed" | jq -c '.' 2>/dev/null | head -c 500 || true)
  [[ -n "$compact" && "$compact" != "{}" ]] && summary+=$'\n'"input: ${compact}"
fi

if [[ "$is_slack" -eq 1 ]]; then
  # Prefer ask so the message is attached to the approval path when supported.
  # Native MCP approval still applies; this does not auto-approve.
  jq -n \
    --arg user_message "$summary" \
    --arg agent_message "Slack MCP call details were surfaced to the user via beforeMCPExecution." \
    '{permission: "ask", user_message: $user_message, agent_message: $agent_message}'
  exit 0
fi

jq -n --arg user_message "$summary" \
  '{permission: "allow", user_message: $user_message}'
exit 0
