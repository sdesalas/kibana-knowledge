#!/usr/bin/env bash
# Removes a skill from ~/.claude/skills (counterpart to install-skill.sh).
# Does not delete the skill folder in this repo — only the global link/copy.
# Usage: ./uninstall-skill.sh <skill-folder-name>
# Example: ./uninstall-skill.sh weekly-update
set -euo pipefail

TARGET_DIR="$HOME/.claude/skills"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <skill-folder-name>"
  exit 1
fi

name="$1"
dest="$TARGET_DIR/$name"

if [[ ! -e "$dest" && ! -L "$dest" ]]; then
  echo "Error: '$dest' not found"
  exit 1
fi

rm -rf "$dest"
echo "Unlinked $name from $TARGET_DIR"
