#!/usr/bin/env bash
# Cursor has no PermissionRequest event. Play Tink on the closest ask-path hooks.
# Notification Center owns the sound so Cursor killing the hook cannot mute it.

input=$(cat)

event=$(printf '%s' "$input" | /usr/bin/jq -r '.hook_event_name // empty')
tool=$(printf '%s' "$input" | /usr/bin/jq -r '.tool_name // empty')
sandbox=$(printf '%s' "$input" | /usr/bin/jq -r 'if .sandbox == null then empty else .sandbox end')
cwd=$(printf '%s' "$input" | /usr/bin/jq -r '.cwd // .workspace_roots[0] // empty')
[ -z "$cwd" ] && cwd=${CURSOR_PROJECT_DIR:-}
[ -z "$tool" ] && [ "$event" = "beforeShellExecution" ] && tool=Shell

detail=$(printf '%s' "$input" | /usr/bin/jq -r '
  def compact:
    if type == "object" then
      (.command // .url // .query // .search_term // .pattern // .path // tostring)
    elif type == "string" then
      (try (fromjson | compact) catch .)
    else tostring end;
  if .tool_input != null and .tool_input != "" then
    .tool_input | compact
  elif .command != null and .hook_event_name != "beforeMCPExecution" then
    .command
  else empty end
')
detail=$(printf '%s' "$detail" | /usr/bin/tr '\n\t' '  ' | /usr/bin/sed -E 's/  +/ /g')
if [ ${#detail} -gt 40 ]; then
  detail="${detail:0:37}..."
fi

project=
[ -n "$cwd" ] && project=$(/usr/bin/basename "$cwd")

{
  /bin/date -u +"%Y-%m-%dT%H:%M:%SZ"
  printf 'event=%s tool=%s sandbox=%s cwd=%s project=%s\n' "$event" "$tool" "$sandbox" "$cwd" "$project"
  [ -n "$detail" ] && printf 'detail=%s\n' "$detail"
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

  title="Cursor tool use"
  [ -n "$project" ] && title="Cursor tool use (${project})"
  body=${detail:-Approval requested}
  [ -n "$detail" ] && body="$ ${detail}"

  /usr/bin/osascript - "$title" "$body" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  display notification (item 2 of argv) with title (item 1 of argv) sound name "Tink"
end run
APPLESCRIPT
fi

exit 0
