#!/usr/bin/env bash
set -euo pipefail

INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')

# Derive session directory from CLAUDE_ENV_FILE (cross-platform)
# Path: ~/.claude/session-env/<session_id>/session-tracker
if [ -z "${CLAUDE_ENV_FILE:-}" ]; then
  exit 0
fi

SESSION_DIR="$(dirname "$CLAUDE_ENV_FILE")"
SESSION_FILE="$SESSION_DIR/session-tracker"

# Export session file path for Bash tool commands and statusline
echo "export CLAUDE_SESSION_FILE=\"$SESSION_FILE\"" >> "$CLAUDE_ENV_FILE"

# Only create timestamp on new or cleared sessions
if [ "$SOURCE" = "startup" ] || [ "$SOURCE" = "clear" ]; then
  echo "$(date +%s)" > "$SESSION_FILE"
fi

echo "CLAUDE_SESSION_FILE=$SESSION_FILE"
