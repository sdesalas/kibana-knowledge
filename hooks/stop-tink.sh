#!/usr/bin/env bash
# Triple Tink when the agent finishes a turn and is waiting on the user.
cat >/dev/null

/usr/bin/nohup /bin/bash -c '
  /usr/bin/afplay /System/Library/Sounds/Tink.aiff &
  /bin/sleep 0.16
  /usr/bin/afplay /System/Library/Sounds/Tink.aiff &
  /bin/sleep 0.16
  /usr/bin/afplay /System/Library/Sounds/Tink.aiff
  wait
' >/dev/null 2>&1 &
disown || true

exit 0
