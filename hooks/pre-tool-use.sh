#!/usr/bin/env bash
# PreToolUse hook: records a tool-start heartbeat (T <ts> <tool>) in the session
# events log. Powers active-time accounting and the forensic timeline. Detail
# level B — tool type only, never arguments or paths. Must never block — exit 0.

set -uo pipefail

{
  INPUT=$(cat)
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
  [ -z "$SESSION_ID" ] && exit 0
  TOOL=$(echo "$INPUT" | jq -r '.tool_name // "?"' | tr -d '[:space:]')
  [ -z "$TOOL" ] && TOOL="?"

  SESSION_DIR="$HOME/.claude/session-env/$SESSION_ID"
  EVENTS_FILE="$SESSION_DIR/events.log"

  mkdir -p "$SESSION_DIR"
  printf 'T %s %s\n' "$(date +%s)" "$TOOL" >> "$EVENTS_FILE"
} || exit 0

exit 0
