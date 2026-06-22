#!/usr/bin/env bash
set -euo pipefail

INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [ -z "$SESSION_ID" ]; then
  exit 0
fi

SESSION_DIR="$HOME/.claude/session-env/$SESSION_ID"
SESSION_FILE="$SESSION_DIR/session-tracker"

mkdir -p "$SESSION_DIR"

# Deploy the canonical active-time awk to a stable, plugin-independent path so
# the statusline and skills (which run outside the plugin dir) share one impl.
AWK_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/active-time.awk"
if [ -f "$AWK_SRC" ]; then
  cp -f "$AWK_SRC" "$HOME/.claude/session-env/active-time.awk" 2>/dev/null || true
fi

# Create timestamp on new/cleared sessions, or if file is missing (e.g. plugin installed after session started)
if [ "$SOURCE" = "startup" ] || [ "$SOURCE" = "clear" ] || [ ! -f "$SESSION_FILE" ]; then
  echo "$(date +%s)" > "$SESSION_FILE"
fi

echo "CLAUDE_SESSION_FILE=$SESSION_FILE"
