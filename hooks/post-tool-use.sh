#!/usr/bin/env bash
# PostToolUse hook: records a tool-done heartbeat (D <ts> <tool>) in the session
# events log, pairing with the PreToolUse T line to measure tool duration. Detail
# level B — tool type only. Must never block — exit 0 on error.

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
  printf 'D %s %s\n' "$(date +%s)" "$TOOL" >> "$EVENTS_FILE"
} || exit 0

exit 0
