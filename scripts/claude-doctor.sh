#!/usr/bin/env bash
# claude-doctor.sh — quick health check for Claude Code + VS Code extension

set -u

echo "=== Claude Code Doctor ==="
echo

echo "[1] CLI version"
if command -v claude >/dev/null 2>&1; then
  claude --version || echo "  claude command failed"
else
  echo "  claude CLI not found in PATH"
fi
echo

echo "[2] Node version (Claude Code needs Node 18+)"
if command -v node >/dev/null 2>&1; then
  node --version
else
  echo "  node not found"
fi
echo

echo "[3] VS Code extension installed?"
if command -v code >/dev/null 2>&1; then
  code --list-extensions --show-versions | grep -i claude || echo "  no Claude extension found"
else
  echo "  'code' CLI not on PATH (Cmd/Ctrl+Shift+P → 'Shell Command: Install code command')"
fi
echo

echo "[4] Auth env vars present?"
for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS HTTPS_PROXY HTTP_PROXY; do
  if [ -n "${!v:-}" ]; then
    # mask anything that looks like a secret
    val="${!v}"
    case "$v" in
      *KEY*|*TOKEN*) val="${val:0:6}…(${#val} chars)";;
    esac
    echo "  $v=$val"
  fi
done
echo

echo "[5] Reachability of api.anthropic.com"
curl -sS -o /dev/null -w "  HTTP %{http_code}  (connect %{time_connect}s, total %{time_total}s)\n" \
  https://api.anthropic.com/v1/messages -X POST -H "content-type: application/json" --max-time 10 \
  || echo "  curl failed — likely network/proxy/DNS"
echo

echo "[6] Bundled VSIX size (corruption check)"
vsix="$HOME/.claude/local/node_modules/@anthropic-ai/claude-code/vendor/claude-code.vsix"
if [ -f "$vsix" ]; then
  size=$(wc -c <"$vsix")
  echo "  $vsix → $size bytes"
  [ "$size" -lt 1000 ] && echo "  ⚠ looks corrupted/empty — install from Marketplace instead"
else
  echo "  not present (fine if you installed from Marketplace)"
fi