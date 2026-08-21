---
description: Sync finished sessions to Solidtime now and show sync health
---

# Sync

Runs the Solidtime sync client immediately and reports sync health: what just happened, how many sessions are still pending, and the most recent error, if any.

## Arguments

None.

## Behavior

1. If `~/.claude/session-env/solidtime.conf` does not exist, tell the user sync isn't configured yet and point them at `/session-tracker:sync-setup`. Stop.
2. Run the sync client in verbose mode and show its output:
   ```bash
   bash ~/.claude/session-env/solidtime-sync.sh --verbose
   ```
3. Fetch sync health:
   ```bash
   bash ~/.claude/session-env/session-query.sh status
   ```
   Read the `.sync` object: `{configured, pending, last_error}`. Report `pending` (sessions not yet fully synced) and `last_error` (most recent `ERROR` line from the sync log, if any).
4. Show the last 10 lines of the sync log for context:
   ```bash
   tail -n 10 ~/.claude/session-env/solidtime-sync.log 2>/dev/null
   ```
5. Summarize: how many sessions synced just now, how many remain pending, and whether the last known error (if any) still applies (it may predate this run's success).

## Implementation hint

```bash
if [ ! -f "$HOME/.claude/session-env/solidtime.conf" ]; then
  echo "Sync isn't configured yet - run /session-tracker:sync-setup"
  exit 0
fi
bash "$HOME/.claude/session-env/solidtime-sync.sh" --verbose
bash "$HOME/.claude/session-env/session-query.sh" status | jq '.sync'
tail -n 10 "$HOME/.claude/session-env/solidtime-sync.log" 2>/dev/null
```

Display the sync run output, the `.sync` summary, and the recent log tail to the user.
