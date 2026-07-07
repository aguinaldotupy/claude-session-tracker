#!/usr/bin/env bash
# StopFailure hook: records when a turn ended due to an API error (SF <ts>).
# Closes the engagement bracket opened by UserPromptSubmit when the normal `Stop`
# hook never fires, so an errored turn no longer leaves a dangling `P`. For
# active-time it counts exactly like a normal `S` (engagement ends, reading tail
# begins); the distinct mark lets the forensic timeline flag the API error.
# StopFailure output/exit code is ignored by Claude Code. Must never block — exit 0.

set -uo pipefail

{
  INPUT=$(cat)
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
  [ -z "$SESSION_ID" ] && exit 0

  SESSION_DIR="$HOME/.claude/session-env/$SESSION_ID"
  EVENTS_FILE="$SESSION_DIR/events.log"

  mkdir -p "$SESSION_DIR"
  printf 'SF %s\n' "$(date +%s)" >> "$EVENTS_FILE"
} || exit 0

exit 0
