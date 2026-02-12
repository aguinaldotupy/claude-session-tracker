---
name: session-status
description: Use when user asks about session duration, elapsed time, how long they've been working, or "quanto tempo". Also use when any skill or workflow needs to know session elapsed time.
---

# Session Status

Reports current Claude Code session elapsed time.

## Mechanism

A `SessionStart` hook writes `$(date +%s)` to a file inside the plugin directory and exports `CLAUDE_SESSION_FILE` via `CLAUDE_ENV_FILE`. The session ID is stable across compaction, so the timestamp survives context resets. Session files persist after session ends so users can track hours later.

## Usage

Run this to get session elapsed time:

```bash
start=$(cat "$CLAUDE_SESSION_FILE" 2>/dev/null)
if [ -n "$start" ]; then
  now=$(date +%s)
  elapsed=$((now - start))
  hours=$((elapsed / 3600))
  minutes=$(((elapsed % 3600) / 60))
  started=$(date -r "$start" "+%H:%M" 2>/dev/null || date -d "@$start" "+%H:%M" 2>/dev/null)
  if [ $hours -gt 0 ]; then
    echo "Session: ${hours}h ${minutes}m (started at ${started})"
  else
    echo "Session: ${minutes}m (started at ${started})"
  fi
else
  echo "Session file not found - hook may not be configured"
fi
```

## Output Format

Display to user:

```
Session: 2h 15m (started at 14:30)
```

If file missing, inform: session tracking hook not configured.

To reset the timer, tell the user they can use `/session-tracker:reset-session` or ask naturally.
