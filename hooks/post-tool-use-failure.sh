#!/usr/bin/env bash
# PostToolUseFailure hook: records a tool-failed heartbeat (DF <ts> <tool>) in the
# session events log. Closes the PreToolUse `T` bracket for a tool that errored,
# so a failed tool no longer leaves a dangling start. For active-time it counts
# exactly like a normal `D` (the work still happened); the distinct mark lets the
# forensic timeline flag the failure. Detail level B — tool type only, never
# arguments or paths. Must never block — exit 0 on error.

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
  printf 'DF %s %s\n' "$(date +%s)" "$TOOL" >> "$EVENTS_FILE"
} || exit 0

exit 0
