#!/usr/bin/env bash
# Stop hook: records when Claude finished responding. Pairs with UserPromptSubmit
# events to compute active vs idle time. Must never block — exit 0 on error.

set -uo pipefail

{
  INPUT=$(cat)
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
  [ -z "$SESSION_ID" ] && exit 0

  SESSION_DIR="$HOME/.claude/session-env/$SESSION_ID"
  EVENTS_FILE="$SESSION_DIR/events.log"

  mkdir -p "$SESSION_DIR"
  printf 'S %s\n' "$(date +%s)" >> "$EVENTS_FILE"
} || exit 0

exit 0
