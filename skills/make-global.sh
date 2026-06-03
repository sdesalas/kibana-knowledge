#!/usr/bin/env bash
# Copies all skill folders in this directory into ~/.claude/skills so Claude Code picks them up globally.
# Run this once after cloning the repo to bootstrap all skills on a new machine.
# To install a single skill instead, use install-skill.sh.
set -euo pipefail

SKILLS_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="$HOME/.claude/skills"

for skill in "$SKILLS_DIR"/*/; do
  name="$(basename "$skill")"
  mkdir -p "$TARGET_DIR/$name"
  cp -r "$skill"* "$TARGET_DIR/$name/"
  echo "Copied $name -> $TARGET_DIR/$name"
done
