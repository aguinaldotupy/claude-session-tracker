---
name: reset-session
description: Use when user asks to reset, restart, or zero out the session timer. Trigger phrases include "reset timer", "restart session time", "reiniciar tempo", "zerar timer".
---

# Reset Session Timer

Resets the session elapsed time counter by overwriting the timestamp file with the current time.

## Usage

Run this command:

```bash
SD="$(bash "${SESSION_TRACKER_HOME:-$HOME/.session-tracker}/session-query.sh" session 2>/dev/null | jq -r '.dir // empty' 2>/dev/null)"
if [ -n "$SD" ]; then
  echo "$(date +%s)" > "$SD/session-tracker"
  # Also clear active/idle event history so the new window starts clean.
  : > "$SD/events.log"
  echo "Session timer reset at $(date '+%H:%M')"
else
  echo "Session not found - session-tracker hook may not be active, or several conversations are live (run it from the project directory)"
fi
```

Inform the user that the session timer has been reset and the elapsed time now starts from zero.
