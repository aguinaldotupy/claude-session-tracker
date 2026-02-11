#!/usr/bin/env bash
set -euo pipefail

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')

rm -f "$CLAUDE_PLUGIN_ROOT/session-tracker-$SESSION_ID"
