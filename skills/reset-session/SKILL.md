---
name: reset-session
description: Use when user asks to reset, restart, or zero out the session timer. Trigger phrases include "reset timer", "restart session time", "reiniciar tempo", "zerar timer".
---

# Reset Session Timer

Resets the session elapsed time counter by overwriting the timestamp file with the current time.

## Usage

Run this command:

```bash
if [ -n "${CLAUDE_SESSION_FILE:-}" ] && [ -f "$CLAUDE_SESSION_FILE" ]; then
  echo "$(date +%s)" > "$CLAUDE_SESSION_FILE"
  echo "Session timer reset at $(date '+%H:%M')"
else
  echo "Session file not found - session-tracker hook may not be active"
fi
```

Inform the user that the session timer has been reset and the elapsed time now starts from zero.
