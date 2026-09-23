---
description: Reset the session timer to zero, restarting the elapsed time counter
disable-model-invocation: true
---

# Reset Session Timer

Reset the session timer by overwriting the timestamp file with the current time.

Run this command:

```bash
SD="$(bash "${SESSION_TRACKER_HOME:-$HOME/.session-tracker}/session-query.sh" session 2>/dev/null | jq -r '.dir // empty' 2>/dev/null)"
if [ -n "$SD" ]; then
  echo "$(date +%s)" > "$SD/session-tracker"
  : > "$SD/events.log"
  echo "Session timer reset at $(date '+%H:%M')"
else
  echo "Session not found - session-tracker hook may not be active, or several conversations are live (run it from the project directory)"
fi
```

Display the result to the user.
