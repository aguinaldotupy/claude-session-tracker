#!/usr/bin/env bash
# Session elapsed time snippet for status line scripts.
# Copy this block into your ~/.claude/statusline-command.sh
#
# Requires CLAUDE_SESSION_FILE env var (set by session-tracker plugin)
# Outputs: session_time variable (e.g. "5m", "2h15m", or empty)

session_time=""
if [ -n "${CLAUDE_SESSION_FILE:-}" ] && [ -f "$CLAUDE_SESSION_FILE" ]; then
    start=$(cat "$CLAUDE_SESSION_FILE")
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

# Example: append to your status line printf
# printf " \033[33m%s\033[0m" "$session_time"
