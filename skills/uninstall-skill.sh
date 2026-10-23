#!/usr/bin/env bash
# Removes a skill from ~/.claude/skills and ~/.agents/skills (counterpart to install-skill.sh).
# Does not delete the skill folder in this repo — only the global link/copy.
# Usage: ./uninstall-skill.sh <skill-folder-name>
# Example: ./uninstall-skill.sh weekly-update
set -euo pipefail

TARGET_DIRS=("$HOME/.claude/skills" "$HOME/.agents/skills")

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <skill-folder-name>"
  exit 1
fi

name="$1"
removed=false

for target_dir in "${TARGET_DIRS[@]}"; do
  dest="$target_dir/$name"
  if [[ ! -e "$dest" && ! -L "$dest" ]]; then
    continue
  fi

  rm -rf "$dest"
  echo "Unlinked $name from $target_dir"
  removed=true
done

if [[ "$removed" == false ]]; then
  echo "Error: '$name' not found in global skill directories"
  exit 1
fi
