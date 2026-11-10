#!/usr/bin/env bash
# Stop hook: records when Claude finished responding. Pairs with UserPromptSubmit
# events to compute active vs idle time. Must never block — exit 0 on error.

set -uo pipefail

{
  INPUT=$(cat)
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
  [ -z "$SESSION_ID" ] && exit 0

  ST_HOME="${SESSION_TRACKER_HOME:-$HOME/.session-tracker}"
  SESSION_DIR="$ST_HOME/$SESSION_ID"
  EVENTS_FILE="$SESSION_DIR/events.log"

  mkdir -p "$SESSION_DIR"
  printf 'S %s\n' "$(date +%s)" >> "$EVENTS_FILE"

  # Cloud sessions (claude.ai/code, Claude Projects threads) run in a VM that is
  # paused and reclaimed on its own schedule: SessionEnd may never fire and the
  # store dies with the box. Sync after every turn instead -- the per-bracket
  # ledger makes repeats idempotent and posts a grown bracket's tail only.
  if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && [ -f "$ST_HOME/solidtime-sync.sh" ] \
     && { [ -f "$ST_HOME/config.yml" ] || [ -n "${SOLIDTIME_URL:-}" ]; }; then
    ( bash "$ST_HOME/solidtime-sync.sh" --session "$SESSION_ID" >/dev/null 2>&1 & ) 2>/dev/null || true
  fi
} || exit 0

exit 0
