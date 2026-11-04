#!/bin/bash
# Updates elastic.apm.serverUrl and elastic.apm.secretToken in
# config/kibana.dev.yml across kibana-main and kibana-<N> / kibana-X.X clones.
# Safe to run from any kibana-* dir (incl. via the .knowledge symlink).
# Usage: ./update-apm-config.sh
#        .knowledge/scripts/update-apm-config.sh
set -euo pipefail

# pwd -P so a .knowledge -> kibana-knowledge symlink resolves to the real tree,
# not the kibana-* clone you ran it from.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; GRAY='\033[0;90m'; RED='\033[0;31m'; RESET='\033[0m'

echo ""
echo "Update elastic.apm settings in kibana.dev.yml across local clones."
echo -e "Looking under ${CYAN}${BASE_DIR}${RESET}"
echo ""

read -r -p "elastic.apm.serverUrl: " SERVER_URL
if [[ -z "${SERVER_URL}" ]]; then
  echo -e "${RED}serverUrl cannot be empty.${RESET}"
  exit 1
fi

read -r -p "elastic.apm.secretToken: " SECRET_TOKEN
if [[ -z "${SECRET_TOKEN}" ]]; then
  echo -e "${RED}secretToken cannot be empty.${RESET}"
  exit 1
fi

echo ""
echo "Will set:"
echo -e "  ${CYAN}elastic.apm.serverUrl:${RESET} ${SERVER_URL}"
echo -e "  ${CYAN}elastic.apm.secretToken:${RESET} ${SECRET_TOKEN}"
echo ""
read -r -p "Apply to all matching kibana clones? [y/N] " CONFIRM
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi
echo ""

updated=0
skipped=0
missing=0

for dir in "$BASE_DIR"/kibana-main "$BASE_DIR"/kibana-[0-9]*; do
  [ -d "$dir" ] || continue
  name=$(basename "$dir")
  file="$dir/config/kibana.dev.yml"

  if [ ! -f "$file" ]; then
    echo -e "${GRAY}${name}${RESET}  no config/kibana.dev.yml"
    missing=$((missing + 1))
    continue
  fi

  if ! grep -qE '^elastic\.apm\.serverUrl:' "$file" && \
     ! grep -qE '^elastic\.apm\.secretToken:' "$file"; then
    echo -e "${YELLOW}${name}${RESET}  no active apm keys — skipped"
    skipped=$((skipped + 1))
    continue
  fi

  # Only touch uncommented keys; leave historical commented lines alone.
  # Use | as sed delimiter so URLs don't need escaping.
  sed -i '' -E \
    -e "s|^(elastic\.apm\.serverUrl:)[[:space:]].*$|\1 ${SERVER_URL}|" \
    -e "s|^(elastic\.apm\.secretToken:)[[:space:]].*$|\1 ${SECRET_TOKEN}|" \
    "$file"

  echo -e "${GREEN}${name}${RESET}  updated"
  updated=$((updated + 1))
done

echo ""
echo -e "Done. ${GREEN}${updated}${RESET} updated, ${YELLOW}${skipped}${RESET} skipped, ${GRAY}${missing}${RESET} missing file."
echo ""
