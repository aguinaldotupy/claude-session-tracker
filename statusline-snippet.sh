#!/usr/bin/env bash
# Session elapsed time snippet for status line scripts.
# Copy this block into your ~/.claude/statusline-command.sh
#
# Outputs: session_time variable (e.g. "5m", "2h15m", or empty)

session_time=""
session_file="/tmp/claude-session-$PPID"
if [ -f "$session_file" ]; then
    start=$(cat "$session_file")
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
