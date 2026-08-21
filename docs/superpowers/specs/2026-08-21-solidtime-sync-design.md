# Solidtime sync — opt-in remote target for session history

**Status:** Design approved
**Date:** 2026-08-21
**Scope:** Sync adapter in the plugin (shell) targeting any Solidtime instance; no server of our own

## Goal

Give users with multiple machines (desktop, notebook, cloud agents, sandboxes)
a unified view of their tracked time by syncing finished sessions to a
[Solidtime](https://github.com/solidtime-io/solidtime) instance — the user's
self-hosted one or solidtime.io cloud. Solidtime provides the account model,
multi-tenancy, dashboard, and reporting; the plugin provides an idempotent,
local-first sync client of roughly 100 lines of shell.

Active (working) time is the number that syncs. Each prompt→stop engagement
bracket (plus reading grace) becomes one Solidtime time entry with real start
and end timestamps, so the sum of entries equals the session's
`active_seconds` and the day's timeline in Solidtime reflects when work
actually happened.

## Non-goals

- No fork of Solidtime, no server or hosted instance of ours (a managed
  instance is a future business decision; it would not change this client).
- No bidirectional sync — Solidtime is never read back into the local store.
- No syncing of machines that do not run the plugin.
- No backfill of pre-existing history in v1 (`--backfill <range>` is a
  possible v2 flag on the manual command).
- Native Windows remains unsupported (existing plugin boundary).

## Design decisions already settled

- **Local-first is untouched.** Hooks write to the local store exactly as
  today and never wait on the network. Sync is asynchronous, optional, and
  failure-tolerant: the local store and `events.log` are the durable source,
  so a Solidtime instance that is down for days loses nothing.
- **Solidtime over Wakapi/Kimai.** Wakapi's heartbeat model recomputes
  durations server-side and would distort our active-time semantics; Kimai is
  not multi-tenant. Solidtime accepts explicit start/end entries, has native
  tags (used for issue keys), organizations, an actively maintained codebase
  (AGPL-3.0), and happens to match the maintainer's stack.
- **Integration beats forking.** AGPL requires publishing modifications even
  for a hosted service, and a fork inherits maintenance of a fast-moving
  product. An API adapter is ~100 lines.

## Configuration

`~/.claude/session-env/solidtime.conf`, created `chmod 600`:

```
SOLIDTIME_URL=https://time.example.com
SOLIDTIME_TOKEN=<api token from Solidtime UI>
SOLIDTIME_ORG_ID=<organization id>
```

- `/session-tracker:sync-setup` (new command) walks the user through creating
  the file: where to generate the token in the Solidtime UI, how to find the
  organization id, then verifies the credentials with one API call.
- Missing or unreadable config → sync is silently inactive. Nothing else in
  the plugin changes behavior.
- The token is never written to any log.

## Sync flow

New `hooks/lib/solidtime-sync.sh`, deployed to `~/.claude/session-env/` by
`session-start.sh` alongside the existing read-side libs.

**Triggers** (all run the same script):

1. `SessionEnd` — after the local upsert succeeds, the hook launches the sync
   **detached in the background** (`nohup … &`, fds redirected) and exits
   immediately. The 5s hook budget is never spent on network.
2. `SessionStart` — relaunches the sync in the background to pick up sessions
   whose sync previously failed.
3. `/session-tracker:sync` — manual run in the foreground; prints results.

**What syncs:** sessions that have ended (have a recorded end), once each.
The SessionEnd trigger passes its own `session_id` explicitly. The retry
passes (SessionStart, manual) discover candidates by listing ended sessions
from the history store — SQLite when available, `history.jsonl` otherwise,
the same source-selection logic `session-query.sh` already uses — and
keeping those whose ledger lacks a `done` line. Brackets are recomputed
deterministically from the session's persisted `events.log`, so sync needs
no schema change and works on the JSONL fallback path too (`sqlite3`
remains a soft dependency).

**Idempotency without server support.** Solidtime's API has no idempotency
key, so replay protection is a local ledger:
`~/.claude/session-env/<session_id>/solidtime-synced` — one line per bracket
index appended *after* that entry is accepted (2xx), plus a final `done`
line. A retry resumes at the first unposted bracket. Concurrent runs are
serialized with a `mkdir`-based lock (portable; no `flock` on macOS); a stale
lock older than 10 minutes is broken.

## Data mapping

**Brackets.** `hooks/lib/active-time.awk` gains an output mode
(`-v mode=brackets`) that emits one `start_ts end_ts` pair per engagement
bracket — same accounting logic as today (prompt→stop counts in full, plus up
to `SESSION_IDLE_THRESHOLD_SECONDS` of reading grace after each stop), only
the output changes. The awk file remains the single owner of time semantics.

**Per entry:**

| Solidtime field | Source |
|---|---|
| `start` / `end` | bracket timestamps (ISO 8601 UTC) |
| project | local project name (basename of canonical root); resolved to a Solidtime project id by name, created via API when absent, id cached locally |
| tags | the session's `issue_key` (e.g. `LIN-456`) when present; resolved/created and cached like projects |
| description | `<hostname> · <session_id_prefix>:<bracket_index>` — identifies the source machine and makes accidental duplicates visible to a human |

Project and tag id caches live in `~/.claude/session-env/solidtime-cache.json`
(name → id). A cache miss falls back to list + create API calls.

**To verify at implementation start** (assumptions from research, not yet
probed against a live instance): exact endpoint paths and payload field names
for time entries, projects, and tags; whether entry creation accepts
arbitrary retroactive timestamps for the authenticated member; org id
discovery. First implementation task is a probe against a real instance
(docker compose), and the spec's field mapping is corrected there if needed.

## Error handling and logging

Failures are never silent — swallowing errors is a rule for hooks, not for
sync.

- Dedicated log: `~/.claude/session-env/solidtime-sync.log`, append-only,
  timestamped lines. Each run logs start/end, per-session outcome, HTTP
  failures with status code and a truncated response body, and config errors
  (missing URL/token/org). The token itself is never logged.
- Self-rotation: when the log exceeds 500 lines it is truncated to the last
  250 (tail to temp file + `mv`).
- Hooks stay mute on stdout/stderr (non-blocking rule); the background sync
  only writes the log.
- `/session-tracker:sync` prints: sessions pending, last successful sync,
  and the most recent error lines from the log.
- `session-query.sh status` gains a `sync` object in its JSON output
  (pending count + last error) read from the same state, so
  `session-status` surfaces sync health for free.
- Network calls: `curl --retry` with capped exponential backoff and short
  timeouts; any failure leaves the ledger where it was and the next trigger
  resumes.

## Repository changes

New files:

- `hooks/lib/solidtime-sync.sh` — the sync client (deployed on SessionStart)
- `commands/sync.md`, `commands/sync-setup.md` — manual command + guided setup
- `skills/sync/SKILL.md` — natural-language trigger ("sincroniza com o solidtime")

Edited:

- `hooks/lib/active-time.awk` — `mode=brackets` output
- `hooks/session-start.sh` — deploy `solidtime-sync.sh`; background relaunch
- `hooks/session-end.sh` — background sync launch after local upsert; **and
  removal of the `st_import_events` call**
- `hooks/lib/db.sh` — **delete `st_import_events`** (root cause of the
  SessionEnd timeout: ~1.35 ms/line of `events.log` from per-line subshell +
  `sed`, exceeding the 5s hook budget at ~4k lines). Its only consumer,
  `sq_timeline`, already falls back to reading the persisted `events.log`,
  which this design promotes to the canonical bracket source. The `events`
  table stays in the schema for old rows; nothing new is written to it.
- `README.md` — new "Sync to Solidtime" section (behavioral description,
  per project convention; no pasted scripts)

## Testing

Extends the existing harness (`tests/lib.sh`, fake `HOME` in `mktemp -d`):

- `active-time.test.sh`: brackets mode over the existing scenarios — asserts
  emitted pairs, and that summing them equals the current scalar output.
- New `solidtime-sync.test.sh`: stubs `curl` with a PATH shim in the fake
  HOME. Cases: full sync happy path; failure mid-batch → ledger stops at the
  failed bracket and log contains the HTTP status line; resume completes
  only the remainder; missing config → inactive, no log spam; lock held →
  second run exits cleanly; log rotation at the 500-line threshold.
- `session-end.test.sh`: still passes with `st_import_events` removed;
  timeline keeps working from `events.log`.
- Regression guard for the timeout bug: synthetic 160k-line `events.log` in
  `db.test.sh` — SessionEnd path completes without the import (previously
  >2 minutes).
