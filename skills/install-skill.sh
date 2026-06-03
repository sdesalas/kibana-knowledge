#!/usr/bin/env bash
# Symlinks a single skill folder into ~/.claude/skills so Claude Code picks it up globally.
# Unlike make-global.sh (which copies), this creates a symlink so edits here are reflected immediately.
# Usage: ./install-skill.sh <skill-folder-name>
# Example: ./install-skill.sh pr-review
set -euo pipefail

SKILLS_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="$HOME/.claude/skills"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <skill-folder-name>"
  exit 1
fi

name="$1"
src="$SKILLS_DIR/$name"

if [[ ! -d "$src" ]]; then
  echo "Error: '$src' not found"
  exit 1
fi

mkdir -p "$TARGET_DIR"
rm -rf "$TARGET_DIR/$name"
ln -s "$src" "$TARGET_DIR/$name"
echo "Linked $name -> $TARGET_DIR/$name"
