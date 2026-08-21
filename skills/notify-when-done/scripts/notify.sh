#!/usr/bin/env bash
set -euo pipefail

voice="Rishi"
volume="0.10"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--voice)
      voice="${2:?}"
      shift 2
      ;;
    --volume)
      volume="${2:?}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "usage: notify.sh [-v voice] [--volume 0.10] \"message\"" >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

message="${1:-}"
if [[ -z "$message" || $# -ne 1 ]]; then
  echo "usage: notify.sh [-v voice] [--volume 0.10] \"message\"" >&2
  exit 1
fi

tmp="$(mktemp /tmp/notify-when-done.XXXXXX.aiff)"
trap 'rm -f "$tmp"' EXIT

/usr/bin/say -v "$voice" -o "$tmp" "$message"
/usr/bin/afplay -v "$volume" "$tmp"
