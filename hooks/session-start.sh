#!/usr/bin/env bash
set -euo pipefail

INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')

SESSION_FILE="$CLAUDE_PLUGIN_ROOT/session-tracker-$SESSION_ID"

# Export session file path for Bash tool commands and statusline
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export CLAUDE_SESSION_FILE=$SESSION_FILE" >> "$CLAUDE_ENV_FILE"
fi

# Only create timestamp on new or cleared sessions
if [ "$SOURCE" = "startup" ] || [ "$SOURCE" = "clear" ]; then
  echo "$(date +%s)" > "$SESSION_FILE"
fi

echo "CLAUDE_SESSION_FILE=$SESSION_FILE"
