#!/usr/bin/env bash
# Security audit: scan repo for sensitive data and odd public exposures
# Usage: check-sensitive-info.sh [repo-path]

set -euo pipefail

REPO_PATH="${1:-.}"
cd "$REPO_PATH" || exit 1

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Sensitive Data & Odd Public Exposures Audit ===${NC}\n"

# Temporary files for results
HIGH_RISK=$(mktemp)
MEDIUM_RISK=$(mktemp)
LOW_RISK=$(mktemp)

trap "rm -f $HIGH_RISK $MEDIUM_RISK $LOW_RISK" EXIT

# === HIGH RISK: Actual Secrets ===
echo "Scanning for credentials and secrets..."

# API keys, bearer tokens, JWT
git ls-files 2>/dev/null | xargs grep -l \
  -iE 'api[_-]?key|bearer[[:space:]]*token|jwt|private[_-]?key|secret[_-]?key|password[[:space:]]*=' \
  2>/dev/null | while read -r file; do
  # Filter out test data, rule descriptions, and false positives
  if ! grep -qiE '(test|fixture|mock|example|description|investigation|Triage|rule|detection)' <(head -1 "$file"); then
    git ls-files "$file" 2>/dev/null >/dev/null && echo "$file"
  fi
done | sort -u > /tmp/api_keys.txt

# Private keys (PEM, RSA, certificates)
git ls-files 2>/dev/null | xargs grep -l \
  -E 'BEGIN (PRIVATE KEY|RSA PRIVATE|CERTIFICATE|EC PRIVATE|PGP PRIVATE)' \
  2>/dev/null >> /tmp/api_keys.txt 2>&1 || true

# Base64-encoded credentials (JWT-like patterns)
git ls-files 2>/dev/null | xargs grep -l \
  -E 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' \
  2>/dev/null >> /tmp/api_keys.txt 2>&1 || true

if [ -s /tmp/api_keys.txt ]; then
  echo -e "${RED}HIGH RISK: Potential credentials/secrets:${NC}" | tee -a "$HIGH_RISK"
  sort -u /tmp/api_keys.txt | while read -r file; do
    echo "  - $file" | tee -a "$HIGH_RISK"
  done
  echo "" | tee -a "$HIGH_RISK"
fi

# === MEDIUM RISK: Internal System Links ===
echo "Scanning for internal system links..."

# Slack permalinks to internal channels
SLACK_FILES=$(git ls-files 2>/dev/null | xargs grep -l 'elastic\.slack\.com' 2>/dev/null | sort -u)
if [ -n "$SLACK_FILES" ]; then
  echo -e "${YELLOW}MEDIUM RISK: Slack permalinks (internal channels):${NC}" | tee -a "$MEDIUM_RISK"
  echo "$SLACK_FILES" | while read -r file; do
    count=$(grep -c 'elastic\.slack\.com' "$file" 2>/dev/null || echo 0)
    echo "  - $file ($count links)" | tee -a "$MEDIUM_RISK"
  done
  echo "" | tee -a "$MEDIUM_RISK"
fi

# PagerDuty/Rootly incident links
INCIDENT_SYS=$(git ls-files 2>/dev/null | xargs grep -l -E 'pagerduty\.com|root\.ly' 2>/dev/null | sort -u)
if [ -n "$INCIDENT_SYS" ]; then
  echo -e "${YELLOW}MEDIUM RISK: Incident management links (PagerDuty/Rootly):${NC}" | tee -a "$MEDIUM_RISK"
  echo "$INCIDENT_SYS" | while read -r file; do
    echo "  - $file" | tee -a "$MEDIUM_RISK"
  done
  echo "" | tee -a "$MEDIUM_RISK"
fi

# Google Docs/Drive (especially internal RCAs, investigation notes)
GOOGLE_DOCS=$(git ls-files 2>/dev/null | xargs grep -l 'docs\.google\.com/document' 2>/dev/null | sort -u)
if [ -n "$GOOGLE_DOCS" ]; then
  echo -e "${YELLOW}MEDIUM RISK: Google Docs/Drive links (internal RCAs/investigations):${NC}" | tee -a "$MEDIUM_RISK"
  echo "$GOOGLE_DOCS" | while read -r file; do
    count=$(grep -c 'docs\.google\.com' "$file" 2>/dev/null || echo 0)
    echo "  - $file ($count links)" | tee -a "$MEDIUM_RISK"
  done
  echo "" | tee -a "$MEDIUM_RISK"
fi

# Internal dashboards (overview.elastic-cloud.com, vault-ci, etc.)
INTERNAL_DASHBOARDS=$(git ls-files 2>/dev/null | xargs grep -l -E 'overview\.elastic-cloud\.com|vault-ci-prod' 2>/dev/null | sort -u)
if [ -n "$INTERNAL_DASHBOARDS" ]; then
  echo -e "${YELLOW}MEDIUM RISK: Internal dashboards/infrastructure:${NC}" | tee -a "$MEDIUM_RISK"
  echo "$INTERNAL_DASHBOARDS" | while read -r file; do
    echo "  - $file" | tee -a "$MEDIUM_RISK"
  done
  echo "" | tee -a "$MEDIUM_RISK"
fi

# === MEDIUM-LOW RISK: Team/Operational Data ===
echo "Scanning for team/operational data..."

# Raw Slack JSON dumps
JSON_DUMPS=$(git ls-files 2>/dev/null | xargs grep -l -E '"messages":|"User":|"Channel"|raw-channel' 2>/dev/null | sort -u)
if [ -n "$JSON_DUMPS" ]; then
  echo -e "${YELLOW}MEDIUM RISK: Raw Slack/data dumps:${NC}" | tee -a "$MEDIUM_RISK"
  echo "$JSON_DUMPS" | while read -r file; do
    echo "  - $file" | tee -a "$MEDIUM_RISK"
  done
  echo "" | tee -a "$MEDIUM_RISK"
fi

# Incident channel archives and postmortems
INCIDENT_DATA=$(find . -path ./.git -prune -o -type f -name '*incident*' -o -name '*postmortem*' -o -name '*rca*' -o -name '*INC-*' 2>/dev/null | grep -v '.git' | sort -u)
if [ -n "$INCIDENT_DATA" ]; then
  echo -e "${YELLOW}MEDIUM RISK: Incident/postmortem data:${NC}" | tee -a "$MEDIUM_RISK"
  echo "$INCIDENT_DATA" | while read -r file; do
    [ -f "$file" ] && echo "  - $file" | tee -a "$MEDIUM_RISK"
  done
  echo "" | tee -a "$MEDIUM_RISK"
fi

# === LOW RISK: Naming/Metadata ===
echo "Scanning for internal metadata..."

# Internal epic/ticket numbers
EPIC_NUMS=$(git ls-files 2>/dev/null | xargs grep -l 'epic #' 2>/dev/null | sort -u)
if [ -n "$EPIC_NUMS" ]; then
  echo -e "${BLUE}LOW RISK: Internal epic/ticket numbers:${NC}" | tee -a "$LOW_RISK"
  echo "$EPIC_NUMS" | while read -r file; do
    nums=$(grep -o 'epic #[0-9]*' "$file" 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')
    echo "  - $file ($nums)" | tee -a "$LOW_RISK"
  done
  echo "" | tee -a "$LOW_RISK"
fi

# Zoom recordings with access codes
ZOOM_RECORDINGS=$(git ls-files 2>/dev/null | xargs grep -l 'elastic\.zoom\.us/rec' 2>/dev/null | sort -u)
if [ -n "$ZOOM_RECORDINGS" ]; then
  echo -e "${BLUE}LOW RISK: Zoom recordings (may contain access codes):${NC}" | tee -a "$LOW_RISK"
  echo "$ZOOM_RECORDINGS" | while read -r file; do
    echo "  - $file" | tee -a "$LOW_RISK"
  done
  echo "" | tee -a "$LOW_RISK"
fi

# === SUMMARY ===
echo -e "\n${BLUE}=== SUMMARY ===${NC}\n"

HIGH_COUNT=$(grep -c . "$HIGH_RISK" 2>/dev/null || echo 0)
MEDIUM_COUNT=$(grep -c . "$MEDIUM_RISK" 2>/dev/null || echo 0)
LOW_COUNT=$(grep -c . "$LOW_RISK" 2>/dev/null || echo 0)

if [ "$HIGH_COUNT" -gt 0 ]; then
  echo -e "${RED}HIGH RISK findings: $HIGH_COUNT${NC}"
  cat "$HIGH_RISK"
fi

if [ "$MEDIUM_COUNT" -gt 0 ]; then
  echo -e "${YELLOW}MEDIUM RISK findings: $MEDIUM_COUNT${NC}"
  cat "$MEDIUM_RISK"
fi

if [ "$LOW_COUNT" -gt 0 ]; then
  echo -e "${BLUE}LOW RISK findings: $LOW_COUNT${NC}"
  cat "$LOW_RISK"
fi

if [ "$HIGH_COUNT" -eq 0 ] && [ "$MEDIUM_COUNT" -eq 0 ] && [ "$LOW_COUNT" -eq 0 ]; then
  echo -e "${GREEN}✓ No obvious sensitive data found${NC}"
fi

echo -e "\n${BLUE}=== Notes ===${NC}"
echo "- Findings that require Elastic auth (Slack, Google Docs) are lower risk but still unusual for public repos"
echo "- Manually review HIGH RISK findings — some false positives may occur"
echo "- If HIGH RISK items exist: rotate credentials and use git filter-repo to remove from history"
