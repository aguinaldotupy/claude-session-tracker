---
name: session-status
description: Use when user asks about session duration, elapsed time, how long they've been working, or "quanto tempo". Also use when any skill or workflow needs to know session elapsed time.
---

# Session Status

Reports current Claude Code session elapsed time.

## Mechanism

A `SessionStart` hook writes `$(date +%s)` to `/tmp/claude-session-$PPID` when the session begins. A `SessionEnd` hook removes it.

## Usage

Run this to get session elapsed time:

```bash
start=$(cat /tmp/claude-session-$PPID 2>/dev/null)
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
