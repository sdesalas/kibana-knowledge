#!/usr/bin/env bash
#
# list_codeowner_files.sh
#
# Print every tracked file in the repo that is owned by a given CODEOWNERS team.
# IMPORTANT: Run script from Kibana repo root.
#
# Usage:
#   ./list_codeowner_files.sh [team-handle]
#
# Defaults to @elastic/security-detection-rule-management.
#
# How it works:
#   CODEOWNERS uses gitignore-style patterns with last-match-wins semantics.
#   We translate CODEOWNERS into a synthetic .gitignore where:
#     - lines that include the target team -> positive pattern (= owned)
#     - lines that do NOT include the target team -> "!pattern" (= un-owned)
#   Blank/comment lines are preserved as blanks so the synthetic file's line
#   numbers stay 1:1 with CODEOWNERS line numbers. We then run
#   `git check-ignore -v --no-index` from a temp git repo whose only ignore
#   source is that synthetic file. The reported line number is used to look
#   up the original CODEOWNERS line's team count, classifying each owned
#   path as fully-owned (1 team) or shared (>1 team).
#
# Memory: streams `git ls-files` through `git check-ignore --stdin`. Only a
# small int[] sized by CODEOWNERS line count (~3500) is held in memory.

set -euo pipefail

TEAM="${1:-@elastic/security-detection-rule-management}"

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "Not inside a git repository." >&2
  echo "Please run this script from the Kibana repo root (the directory that contains .github/CODEOWNERS)." >&2
  exit 1
fi
CODEOWNERS_FILE="${REPO_ROOT}/.github/CODEOWNERS"

if [[ ! -f "${CODEOWNERS_FILE}" ]]; then
  echo "CODEOWNERS not found at ${CODEOWNERS_FILE}" >&2
  echo "Please run this script from the Kibana repo root (the directory that contains .github/CODEOWNERS)." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d -p "${REPO_ROOT}" .codeowners-tmp.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Init an isolated git repo so only our synthetic .gitignore drives matching.
git -C "${TMP_DIR}" init -q

# Build .gitignore + a parallel team-count file. Line N in either file
# corresponds to line N in CODEOWNERS.
awk -v team="${TEAM}" -v counts_file="${TMP_DIR}/team_counts" '
  {
    if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) {
      print ""
      print 0 > counts_file
      next
    }

    line = $0
    sub(/[[:space:]]+#.*$/, "", line)  # strip inline comment
    n = split(line, fields, /[[:space:]]+/)

    pattern = ""
    for (i = 1; i <= n; i++) {
      if (fields[i] != "") { pattern = fields[i]; break }
    }
    if (pattern == "") {
      print ""
      print 0 > counts_file
      next
    }

    sub(/\/$/, "", pattern)

    team_count = 0
    owned = 0
    for (i = 1; i <= n; i++) {
      if (fields[i] ~ /^@/) {
        team_count++
        if (fields[i] == team) owned = 1
      }
    }

    # Per CODEOWNERS spec, a pattern with no team UNSETS ownership for that
    # path (last-match-wins), so the file is not ours, same as a foreign-team
    # rule. Encode both cases as "!pattern".
    if (owned) print pattern
    else       print "!" pattern

    print team_count > counts_file
  }
' "${CODEOWNERS_FILE}" > "${TMP_DIR}/.gitignore"

# Stream every tracked path through check-ignore. -v reports the matched
# rule as "<source>:<linenum>:<pattern>\t<path>". Source is ".gitignore"
# (relative, no colons), so the second colon-separated field is linenum.
{
  git -C "${REPO_ROOT}" ls-files \
    | git -C "${TMP_DIR}" check-ignore -v --no-index --stdin \
    || {
      status=$?
      # exit code 1 = "no paths ignored" (valid, just means team owns nothing)
      [[ ${status} -eq 1 ]] || exit ${status}
    }
} | awk -F'\t' -v team="${TEAM}" -v counts_file="${TMP_DIR}/team_counts" '
  BEGIN {
    i = 0
    while ((getline cnt < counts_file) > 0) {
      i++
      team_counts[i] = cnt + 0
    }
  }
  {
    # $1 = "<source>:<linenum>:<pattern>". Source = ".gitignore" (no colons).
    # Use match() to extract linenum + pattern robustly even if pattern
    # itself contains a colon.
    rest = $1
    sub(/^[^:]*:/, "", rest)             # drop "<source>:"
    linenum = rest + 0                   # leading digits = linenum
    sub(/^[0-9]+:/, "", rest)            # drop "<linenum>:"
    pattern = rest                       # remaining = pattern

    # check-ignore -v reports every match, INCLUDING negations. A file
    # matched only by "!pattern" is NOT owned, skip it.
    if (substr(pattern, 1, 1) == "!") next

    tc = team_counts[linenum]
    if (tc == 1)      full++
    else if (tc > 1)  shared++
    print $2
  }
  END {
    printf "\n--- CODEOWNERS summary for %s ---\n", team        > "/dev/stderr"
    printf "Fully owned (only this team): %d\n",   full + 0     > "/dev/stderr"
    printf "Shared with other teams:      %d\n",   shared + 0   > "/dev/stderr"
    printf "Total owned:                  %d\n",   full + shared > "/dev/stderr"
  }
'
