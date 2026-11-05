#!/usr/bin/env bash
# Usage: watch_buildkite.sh <build-number> [pipeline] [timeout-secs] [interval-secs]
set -uo pipefail

build="${1:?build number required}"
pipeline="${2:-elastic/kibana-pull-request}"
timeout="${3:-3600}"
interval="${4:-60}"
notify=~/.claude/skills/notify-when-done/scripts/notify.sh

say_it() {
  echo "[$(date +%H:%M:%S)] $1"
  osascript -e "display notification \"$1\" with title \"Buildkite #$build\"" >/dev/null 2>&1
  "$notify" "$1" >/dev/null 2>&1
}

deadline=$(( $(date +%s) + timeout ))
warned=false

while (( $(date +%s) < deadline )); do
  json=$(bk build view "$build" -p "$pipeline" -o json 2>/dev/null)
  state=$(jq -r '.state // empty' <<<"$json" 2>/dev/null)

  if [[ -z "$state" ]]; then
    echo "[$(date +%H:%M:%S)] couldn't fetch build, retrying"
    sleep "$interval"
    continue
  fi

  failed=$(jq -r '[.jobs[] | select(.type=="script" and (.state=="failed" or .state=="timed_out"))] | length' <<<"$json")
  running=$(jq -r '[.jobs[] | select(.type=="script" and (.state=="running" or .state=="scheduled" or .state=="assigned" or .state=="waiting"))] | length' <<<"$json")
  echo "[$(date +%H:%M:%S)] state=$state running=$running failed=$failed"

  case "$state" in
    passed) say_it "Build $build passed."; exit 0 ;;
    failed) say_it "Build $build failed with $failed failed jobs."; exit 1 ;;
    canceled|canceling|skipped|not_run) say_it "Build $build was $state."; exit 1 ;;
    failing)
      if ! $warned; then
        say_it "Build $build has a failing job, still running."
        warned=true
      fi
      ;;
  esac

  sleep "$interval"
done

say_it "Stopped watching build $build after $(( timeout / 60 )) minutes, it's still $state."
exit 2
