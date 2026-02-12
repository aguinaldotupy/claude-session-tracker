#!/usr/bin/env bash
# Session elapsed time snippet for status line scripts.
# Copy this block into your ~/.claude/statusline-command.sh
#
# Uses three fallback strategies to find the session file:
#   1. CLAUDE_SESSION_FILE env var (set by session-tracker plugin)
#   2. session_id from statusline JSON input → derives path
#   3. $PPID fallback (legacy)
#
# Expects: $input variable with the statusline JSON (from stdin)
# Outputs: $session_time variable (e.g. "5m", "2h15m", or empty)

session_time=""
sf="${CLAUDE_SESSION_FILE:-}"
if [ -z "$sf" ]; then
  session_id=$(echo "$input" | jq -r '.session_id // empty')
  if [ -n "$session_id" ]; then
    sf="$HOME/.claude/session-env/${session_id}/session-tracker"
  fi
fi
if [ -z "$sf" ]; then
  sf="/tmp/claude-session-$PPID"
fi
if [ -n "$sf" ] && [ -f "$sf" ]; then
  start=$(cat "$sf")
  now=$(date +%s)
  elapsed=$((now - start))
  hours=$((elapsed / 3600))
  minutes=$(((elapsed % 3600) / 60))
  if [ $hours -gt 0 ]; then
    session_time="${hours}h${minutes}m"
  else
    session_time="${minutes}m"
  fi
fi

# Example: append to your status line
# if [ -n "$session_time" ]; then
#   printf " \033[33m%s\033[0m" "$session_time"
# fi
