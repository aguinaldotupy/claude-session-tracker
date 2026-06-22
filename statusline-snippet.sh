#!/usr/bin/env bash
# Session elapsed time snippet for status line scripts.
# Copy this block into your ~/.claude/statusline-command.sh
#
# Derives **active** (working) time from the session's events.log using the awk deployed at $HOME/.claude/session-env/active-time.awk; falls back to wall-clock when either is missing.
# Falls back to $PPID for legacy setups.
#
# Expects: $input variable with the statusline JSON (from stdin)
# Outputs: $session_time variable (e.g. "5m", "2h15m", or empty)

session_time=""
sf=""
session_id=$(echo "$input" | jq -r '.session_id // empty')
if [ -n "$session_id" ]; then
  sf="$HOME/.claude/session-env/${session_id}/session-tracker"
fi
if [ -z "$sf" ]; then
  sf="/tmp/claude-session-$PPID"
fi
if [ -n "$sf" ] && [ -f "$sf" ]; then
  start=$(cat "$sf")
  now=$(date +%s)
  grace="${SESSION_IDLE_THRESHOLD_SECONDS:-120}"
  events="$(dirname "$sf")/events.log"
  awklib="$HOME/.claude/session-env/active-time.awk"
  if [ -f "$events" ] && [ -f "$awklib" ]; then
    # Active (working) time via the shared awk deployed by session-start.sh.
    secs=$(awk -v grace="$grace" -v t_end="$now" -f "$awklib" "$events")
  else
    secs=$((now - start))   # legacy fallback: wall-clock
  fi
  case "$secs" in ''|*[!0-9]*) secs=$((now - start)) ;; esac
  hours=$((secs / 3600))
  minutes=$(((secs % 3600) / 60))
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
