---
name: sync
description: Use when user asks to sync time to Solidtime, "sincroniza com o solidtime", "manda as horas", "sync sessions", or asks whether sync is working/failing.
---

# Sync to Solidtime

Runs the Solidtime sync client and reports sync health — same behavior as `/session-tracker:sync`.

## Mechanism

`~/.claude/session-env/solidtime-sync.sh` (deployed by the `SessionStart` hook) posts each finished session's active-time brackets to a Solidtime instance as time entries — see `docs/superpowers/specs/2026-08-21-solidtime-sync-design.md`. It's local-first: nothing is lost if the instance is unreachable, and the next `SessionStart` or manual run retries. Configuration lives in `~/.claude/session-env/solidtime.conf` (`chmod 600`); when it's missing, sync is silently inactive.

## Usage

1. If `~/.claude/session-env/solidtime.conf` doesn't exist, tell the user sync isn't configured and point them at `/session-tracker:sync-setup`. Stop.
2. Run:
   ```bash
   bash "$HOME/.claude/session-env/solidtime-sync.sh" --verbose
   ```
3. Read sync health:
   ```bash
   bash "$HOME/.claude/session-env/session-query.sh" status
   ```
   Use `.sync`: `{configured, pending, last_error}`.
4. If useful, show the tail of the log:
   ```bash
   tail -n 10 "$HOME/.claude/session-env/solidtime-sync.log"
   ```

## Output Format

Report: sessions synced just now, the `pending` count remaining, and `last_error` if non-empty.

## Interpreting errors

`last_error` and log lines carry an HTTP status. Translate it for the user:

- **401** — the API token is invalid or expired. Re-run `/session-tracker:sync-setup` to save a fresh token.
- **404** — the instance URL or organization id is wrong. Re-run `/session-tracker:sync-setup` with the correct values.
- **Timeout / connection failure** (no HTTP status, or a network error) — the Solidtime instance is unreachable. Nothing is lost: brackets stay in the local ledger and sync automatically on the next session start or the next `/session-tracker:sync`.
- Any other status — show the raw log line; it carries a truncated response body that usually explains the failure.

## Edge cases

- No sessions pending and no error → sync is healthy, nothing to do.
- `configured: false` → point at `/session-tracker:sync-setup`.
- Sync just ran but `pending` is still > 0 → a bracket is failing repeatedly; show the specific error from the log rather than just "pending".
