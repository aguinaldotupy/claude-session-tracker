---
name: sync
description: Use when user asks to sync time to Solidtime, "sincroniza com o solidtime", "manda as horas", "sync sessions", or asks whether sync is working/failing.
---

# Sync to Solidtime

Runs the Solidtime sync client and reports sync health — same behavior as `/session-tracker:sync`.

## Mechanism

`~/.session-tracker/solidtime-sync.sh` (deployed by the `SessionStart` hook) posts each finished session's active-time brackets to a Solidtime instance as time entries — see `docs/superpowers/specs/2026-08-21-solidtime-sync-design.md`. It runs on three triggers: automatically in the background right when a session ends, again on the next `SessionStart` to retry anything still pending, and on demand via `/session-tracker:sync` or this skill. It's local-first: nothing is lost if the instance is unreachable — the session stays in the local store until one of those triggers succeeds. Configuration lives in `~/.session-tracker/config.yml` (`chmod 600`); when it's missing, sync is silently inactive.

## Usage

1. If `~/.session-tracker/config.yml` doesn't exist **and** `SOLIDTIME_URL` is unset (the env-var config mode), tell the user sync isn't configured and point them at `/session-tracker:sync-setup`. Stop.
2. Run:
   ```bash
   bash "${SESSION_TRACKER_HOME:-$HOME/.session-tracker}/solidtime-sync.sh" --verbose
   ```
3. Read sync health:
   ```bash
   bash "${SESSION_TRACKER_HOME:-$HOME/.session-tracker}/session-query.sh" status
   ```
   Use `.sync`: `{configured, pending, last_error}`.
4. If useful, show the tail of the log:
   ```bash
   tail -n 10 "${SESSION_TRACKER_HOME:-$HOME/.session-tracker}/solidtime-sync.log"
   ```

## Output Format

Report: sessions synced just now, the `pending` count remaining, and `last_error` if non-empty.

**The current session is never among them.** Sync works from finished sessions, and this one has no end time until it ends — its time posts automatically at `SessionEnd`, seconds later. So "0 synced" here is the normal, healthy answer when the only outstanding work is the conversation you are in; say so rather than reporting it as nothing happening.

## Interpreting errors

`last_error` and log lines carry an HTTP status. Translate it for the user:

- **401** — the API token is invalid or expired. Re-run `/session-tracker:sync-setup` to save a fresh token.
- **404** — the instance URL or organization id is wrong. Re-run `/session-tracker:sync-setup` with the correct values.
- **`lock held, skipping run`** — another sync (the one SessionStart launches in the background) is already running. Not an error and nothing is lost; wait a few seconds and run again.
- **`ERROR curl not found`** — this machine has no `curl`, which the sync client requires. Install it; nothing syncs until then.
- **`no events.log (session dir gone?)`** — that session's directory was deleted before its time was posted, so it is written off permanently. Only a concern if it repeats.
- **Timeout / connection failure** (no HTTP status, or a network error) — the Solidtime instance is unreachable. Nothing is lost: brackets stay in the local ledger and sync automatically the next time a session ends, on the next session start, or on the next `/session-tracker:sync`.
- Any other status — show the raw log line; it carries a truncated response body that usually explains the failure.

## Edge cases

- No sessions pending and no error → sync is healthy, nothing to do.
- `configured: false` → point at `/session-tracker:sync-setup`.
- Sync just ran but `pending` is still > 0 → a bracket is failing repeatedly; show the specific error from the log rather than just "pending".
