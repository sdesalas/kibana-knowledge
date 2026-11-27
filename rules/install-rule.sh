#!/usr/bin/env bash
# Symlinks a single rule folder into ~/.claude/rules for global discovery.
# Edits here are reflected immediately (counterpart to skills/install-skill.sh).
# Usage: ./install-rule.sh <rule-folder-name>
# Example: ./install-rule.sh codeowners
set -euo pipefail

RULES_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIRS=("$HOME/.claude/rules")

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <rule-folder-name>"
  exit 1
fi

name="$1"
src="$RULES_DIR/$name"

if [[ ! -d "$src" ]]; then
  echo "Error: '$src' not found"
  exit 1
fi

for target_dir in "${TARGET_DIRS[@]}"; do
  mkdir -p "$target_dir"
  rm -rf "$target_dir/$name"
  ln -s "$src" "$target_dir/$name"
  echo "Linked $name -> $target_dir/$name"
done
