---
description: Reset the session timer to zero, restarting the elapsed time counter
disable-model-invocation: true
---

# Reset Session Timer

Reset the session timer by overwriting the timestamp file with the current time.

Run this command:

```bash
if [ -n "${CLAUDE_SESSION_FILE:-}" ] && [ -f "$CLAUDE_SESSION_FILE" ]; then
  echo "$(date +%s)" > "$CLAUDE_SESSION_FILE"
  echo "Session timer reset at $(date '+%H:%M')"
else
  echo "Session file not found - session-tracker hook may not be active"
fi
```

Display the result to the user.
