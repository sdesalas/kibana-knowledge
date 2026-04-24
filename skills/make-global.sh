#!/usr/bin/env bash
set -euo pipefail

SKILLS_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="$HOME/.claude/skills"

for skill in "$SKILLS_DIR"/*/; do
  name="$(basename "$skill")"
  mkdir -p "$TARGET_DIR/$name"
  cp -r "$skill"* "$TARGET_DIR/$name/"
  echo "Copied $name -> $TARGET_DIR/$name"
done
