#!/bin/bash
# Lists all kibana-main and kibana-<N> worktrees with their current branch.
# Green = on main (available), red = on a feature branch (busy).
# Usage: show-kibana-branches.sh [--pull [branch]]  (branch defaults to main)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$SCRIPT_DIR/../.."
CYAN='\033[0;36m'; RED='\033[0;31m'; GREEN='\033[0;32m'; GRAY='\033[0;90m'; RESET='\033[0m'
PULL_BRANCH=""
if [[ "$1" == "--pull" ]]; then
  PULL_BRANCH="${2:-main}"
fi
echo ""
for dir in "$BASE_DIR"/kibana-main "$BASE_DIR"/kibana-[0-9]*; do
  [ -d "$dir" ] || continue
  foldername=$(basename "$dir")
  folderbranch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "not a git repo")
  if [ -n "$PULL_BRANCH" ] && [ "$folderbranch" = "$PULL_BRANCH" ]; then
    printf "${CYAN}./%s${RESET}  git:(${GREEN}%s${RESET}) pulling...\n" "$foldername" "$folderbranch"
    git -C "$dir" pull --ff-only 2>&1 | tail -1
  elif [ "$folderbranch" = "main" ]; then
    printf "${CYAN}./%s${RESET}  git:(${GREEN}%s${RESET})\n" "$foldername" "$folderbranch"
  else
    printf "${CYAN}./%s${RESET}  git:(${RED}%s${RESET})\n" "$foldername" "$folderbranch"
  fi
done
echo ""
