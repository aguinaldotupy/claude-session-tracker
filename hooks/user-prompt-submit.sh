#!/usr/bin/env bash
# UserPromptSubmit hook: records a prompt event in the session events log.
# Used by the active/idle accounting in session-status. Must never block — exit 0 on error.

set -uo pipefail

{
  INPUT=$(cat)
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
  [ -z "$SESSION_ID" ] && exit 0

  ST_HOME="${SESSION_TRACKER_HOME:-$HOME/.session-tracker}"
  SESSION_DIR="$ST_HOME/$SESSION_ID"
  EVENTS_FILE="$SESSION_DIR/events.log"

  mkdir -p "$SESSION_DIR"
  printf 'P %s\n' "$(date +%s)" >> "$EVENTS_FILE"
} || exit 0

exit 0
