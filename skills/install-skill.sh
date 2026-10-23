#!/usr/bin/env bash
# Symlinks a single skill folder into ~/.claude/skills and ~/.agents/skills for global discovery.
# Unlike make-global.sh (which copies), this creates a symlink so edits here are reflected immediately.
# Usage: ./install-skill.sh <skill-folder-name>
# Example: ./install-skill.sh pr-review
set -euo pipefail

SKILLS_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIRS=("$HOME/.claude/skills" "$HOME/.agents/skills")

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

for target_dir in "${TARGET_DIRS[@]}"; do
  mkdir -p "$target_dir"
  rm -rf "$target_dir/$name"
  ln -s "$src" "$target_dir/$name"
  echo "Linked $name -> $target_dir/$name"
done
