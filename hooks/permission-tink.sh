#!/usr/bin/env bash
# Cursor has no PermissionRequest event. Play Tink on the closest ask-path hooks.
# Notification Center owns the sound so Cursor killing the hook cannot mute it.

input=$(cat)

event=$(printf '%s' "$input" | /usr/bin/jq -r '.hook_event_name // empty')
tool=$(printf '%s' "$input" | /usr/bin/jq -r '.tool_name // empty')
sandbox=$(printf '%s' "$input" | /usr/bin/jq -r '.sandbox // empty')

{
  /bin/date -u +"%Y-%m-%dT%H:%M:%SZ"
  printf 'event=%s tool=%s sandbox=%s\n' "$event" "$tool" "$sandbox"
} >> /tmp/cursor-permission-tink.log 2>/dev/null

play=0
case "$event" in
  beforeMCPExecution) play=1 ;;
  beforeShellExecution)
    [ "$sandbox" = "false" ] && play=1
    ;;
  preToolUse) play=1 ;;
esac

if [ "$play" -eq 1 ]; then
  lock=/tmp/cursor-permission-tink.lock
  now=$(date +%s)
  if [ -f "$lock" ]; then
    last=$(cat "$lock" 2>/dev/null || echo 0)
    if [ "$last" -eq "$last" ] 2>/dev/null && [ $((now - last)) -lt 2 ]; then
      printf 'debounced\n' >> /tmp/cursor-permission-tink.log 2>/dev/null
      exit 0
    fi
  fi
  echo "$now" > "$lock"
  printf 'play=1\n' >> /tmp/cursor-permission-tink.log 2>/dev/null
  /usr/bin/osascript -e 'display notification "Cursor is waiting for approval" with title "Cursor" sound name "Tink"' >/dev/null 2>&1 || true
fi

exit 0
