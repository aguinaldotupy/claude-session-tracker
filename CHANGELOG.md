# Changelog

All notable changes to this plugin are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [4.0.0] - 2026-08-24

Everything the plugin writes moves out of `~/.claude/`, sessions that die
without a clean shutdown are no longer lost, and the whole thing now runs under
[opencode](https://opencode.ai) as well as Claude Code — sharing one history,
one worklog and one Solidtime sync between them.

**Upgrading is automatic.** The first session start after the update moves the
store, converts the config, and keeps the originals. Read *Changed* below if you
have scripts pointing at the old paths.

### Added
- **Sessions that never got a clean shutdown are now recorded.** `SessionEnd` is
  an optimization, not a guarantee — Claude Code can be killed and machines lose
  power — and until now such a session was silently dropped from your history and
  your sync, even though everything the accounting needs was already on disk in
  `events.log`. A background sweep at session start closes any session that has
  been silent for more than 4 hours, using its **last recorded event** as the end
  time (never the current time — that is the last moment we know you were
  working). Sessions with no events at all are left alone rather than given an
  invented end time. Tune with `SESSION_TRACKER_STALE_SECONDS` (default `14400`)
  and `SESSION_TRACKER_REAP_WINDOW_DAYS` (default `7`).
- **opencode support.** `opencode/plugin.js` maps opencode's hooks onto the same
  shell hooks Claude Code drives, writing to the same store — so your worklog
  covers your whole day regardless of which editor it happened in. Skills and
  commands are shared verbatim; installation is symlinks. See the README. The
  status line is the one thing that does not port: opencode's TUI has no custom
  status line API.
- `SESSION_TRACKER_HOME` to put the store somewhere other than the default.
- `SESSION_TRACKER_SESSION_ID`, a harness-neutral way for skills to locate the
  live session. `CLAUDE_SESSION_ID` still works.

### Changed
- **BREAKING — the store moved to `~/.session-tracker/`.** It used to live in
  `~/.claude/session-env/`, a path tied to one editor. The first session start
  after the update moves the directory and **leaves a symlink at the old path**,
  so a status line snippet you already pasted into `settings.json` keeps working
  untouched. Anything of your own that hardcodes the old path also keeps working
  through that symlink, but is worth updating.
- **BREAKING — `solidtime.conf` became `config.yml`**, one config file for the
  whole plugin. It is converted on first start and the original is kept beside it
  as `solidtime.conf.migrated`. The new file is **parsed, never executed**: the
  old one was sourced as shell, so a token containing `|`, `#`, `$` or quotes
  needed exact quoting to survive — Solidtime's own Sanctum tokens are shaped
  `<id>|<random>`, which made this a real trap. The supported syntax is
  deliberately small (a section plus one level of `key: value`), and anything
  unparseable is ignored rather than guessed at.

  ```yaml
  solidtime:
    url: https://app.solidtime.io
    token: 1|abcdef...
    org_id: 0192f...
  ```
- A session whose project cannot be determined is now stored with no project at
  all, and shown as `—`, instead of being filed under a blank name.

## [3.2.0] - 2026-08-24

### Added
- **Sync finished sessions to Solidtime (optional).** Point the plugin at a
  [Solidtime](https://github.com/solidtime-io/solidtime) instance — self-hosted
  or `solidtime.io` — and every session that ends is posted there as time
  entries, one per prompt→stop engagement, so a session's entries sum to the
  same active time the plugin reports locally. Projects are created by name and
  the session's issue key (e.g. `LIN-456`) becomes a Solidtime tag, which gives
  users working across several machines one unified dashboard. Set it up with
  `/session-tracker:sync-setup`; run or inspect it with `/session-tracker:sync`.
  Nothing changes for anyone who doesn't configure it: with no config the sync
  paths exit immediately, make no network calls, and write no new files.
- Sync is local-first and never blocks a hook. Hooks launch it detached, a
  Solidtime instance that is down for days loses nothing (every finished
  session waits in the local store and retries on the next session start), and
  a per-session ledger keeps replays idempotent — including sessions resumed
  after a sync, which post only the work added since.
- Sync health is visible: failures always land in
  `~/.claude/session-env/solidtime-sync.log`, and `session-status` reports a
  `sync` object with the pending count and the last error.
- Ephemeral environments (CI, cloud sessions, sandbox VMs) can configure sync
  with `SOLIDTIME_URL` / `SOLIDTIME_TOKEN` / `SOLIDTIME_ORG_ID` environment
  variables instead of a config file. The file wins when both are present.

### Fixed
- **Ending a long session could hang Claude Code for minutes.** The SessionEnd
  hook copied `events.log` into SQLite one row per shelled-out subprocess
  (~1.35 ms per line), so a session with a few thousand events blew the hook's
  5 s budget — worst observed: over two minutes, with the session's timeline
  rolled back when the hook was killed. That import is gone; the timeline is
  read from `events.log`, which is where it already fell back to. The `events`
  table is kept for rows written by older versions.
- **`/clear` left stale events behind.** Clearing a session resets its start
  timestamp but reused the same session id, and `events.log` was not truncated
  with it — so the statusline kept reporting the pre-clear total, and (once
  sync existed) the whole pre-clear window was billed to Solidtime. The
  timestamp and the event log are now reset together, matching what
  `/session-tracker:reset-session` always did.

### Changed
- The read-side libraries are deployed with an atomic rename instead of an
  in-place copy, so a sync still running from a previous session cannot be
  overwritten mid-execution.

## [3.1.1] - 2026-07-16

### Fixed
- **Every hook was silently broken in Claude Desktop sessions.** Claude Code
  hands hook commands to `sh -c` with `${CLAUDE_PLUGIN_ROOT}` expanded
  unquoted, and the desktop app installs plugins under
  `~/Library/Application Support/…` — the space word-splits the command, so
  all 8 hooks died before running (`/bin/sh: /Users/…/Library/Application: is
  a directory`): no session timestamp, no events, no SQLite rows for any
  desktop-launched session. Terminal sessions were unaffected (space-free
  plugin path). Every `hooks.json` command now wraps `${CLAUDE_PLUGIN_ROOT}`
  in quotes, and the test suite asserts both the quoting and that the
  SessionStart command line survives a plugin root containing a space.
- The `session-status` skill and `session-query` resolved the live session id
  only from `$CLAUDE_SESSION_ID`, which desktop child sessions leave unset.
  Both now fall back to `$CLAUDE_CODE_SESSION_ID`.

## [3.1.0] - 2026-07-15

### Changed
- Read path consolidated into a single tested `session-query` CLI
  (`hooks/lib/session-query.sh`, deployed to `~/.claude/session-env/`). The
  `session-status`, `session-history`, and `worklog` skills/commands now call it
  and render its JSON instead of embedding SQL/awk/jq. Behavior is unchanged;
  the SQLite-vs-JSONL guard and the forensic-timeline awk now live (and are
  tested) in one place.

## [3.0.2] - 2026-07-14

### Changed
- Migration now groups a repo's Claude Code worktrees under one project. Rows
  whose `project_dir` is a default-layout worktree (`<repo>/.claude/worktrees/
  <name>`) get `project_root = <repo>`, so all worktrees of a repo aggregate as
  a single project instead of dozens of hash-named ones. The exact,
  Claude-Code-owned `/.claude/worktrees/` marker gates this — custom worktree
  paths are left as-is (fall back to `project_dir`). The full worktree path is
  still kept in `project_dir` as session detail. (New sessions already grouped
  correctly via `git rev-parse --git-common-dir`; this aligns migrated history.)

### Added
- One-time, idempotent backfill (`st_backfill_worktrees`, run at SessionStart)
  that regroups already-migrated worktree sessions under their repo root and
  removes the orphaned per-worktree project rows — so databases created by
  v3.0.0/v3.0.1 get the same grouping without re-migrating.

## [3.0.1] - 2026-07-13

### Fixed
- **Migration of a large `history.jsonl` never completed, so session totals were
  wrong.** The v3.0.0 importer ran one `sqlite3` process per session (~85s for
  ~3000 rows) inside the `SessionStart` hook's 5s timeout — it was killed after
  ~150 rows, never renamed the file, and re-thrashed every start, leaving a
  partial database. The read path then preferred that partial DB over the
  complete JSON-lines log, so `session-status`/`session-history` reported only a
  fraction of sessions. The importer now runs as a single `sqlite3` transaction
  fed by one `jq` stream (skipping malformed lines), migrating thousands of rows
  in well under a second.
- While `history.jsonl` still exists (migration pending or running without
  `sqlite3`), the skills now read the complete deduped JSON-lines log instead of
  an incomplete database; SQLite becomes authoritative only once the file is
  migrated and renamed to `history.jsonl.imported`.

## [3.0.0] - 2026-07-07

### Added
- Relational SQLite session store at `~/.claude/session-env/history.db`
  (`projects`/`sessions`/`events`), replacing the append-only `history.jsonl`
  as the aggregate log. Heartbeats stay in the per-session text `events.log`
  (hot-path); SQLite is written once per session at `SessionEnd`.
- Canonical `project_root` (via `git rev-parse --git-common-dir`) so all
  worktrees of a repo group under one project, independent of the worktree path.
- `Branch/Issue` column in `session-history`; per-session forensic timeline now
  served from the durable `events` table.
- Automatic, idempotent migration of `history.jsonl` into SQLite on the first
  session after upgrade (file renamed `history.jsonl.imported`).

### Fixed
- **Session time totals were inflated ~78%.** `SessionEnd` appended a fresh
  cumulative row on every session close (and fires repeatedly across
  resume/`--continue` for a stable `session_id`), so summing rows double-counted.
  With `session_id` as a primary key and upsert, each session is exactly one row.

### Changed
- `sqlite3` is a new soft dependency (falls back to JSON-lines when absent).

## [2.6.0] - 2026-07-07

### Added
- `PreToolUse`/`PostToolUse` hooks append tool heartbeats (`T <ts> <tool>` /
  `D <ts> <tool>`, tool type only) to `events.log`.
- Forensic per-session timeline in the `session-history` skill, showing time
  spent per tool type inside each working interval.
- Shared `hooks/lib/active-time.awk` library (deployed to
  `~/.claude/session-env/active-time.awk` on session start so the statusline and
  skills share one implementation) and a plain-bash test suite under `tests/`.
- `PostToolUseFailure`/`StopFailure` hooks append failure heartbeats (`DF <ts>
  <tool>` / `SF <ts>`) to `events.log`, closing brackets that a failed tool or an
  API-errored turn would otherwise leave dangling. For active-time they count
  exactly like `D`/`S`; the distinct marks let the `session-history` forensic
  timeline flag failed tools (`✗`) and API-error stops.

### Changed
- **Active time is now computed additively** (prompt→stop brackets plus a
  bounded reading grace) instead of subtracting idle gaps from wall-clock. A
  session parked while you work in another session on the same project no longer
  inflates — it stops accruing after the grace. Active is now the headline
  number in the statusline, `session-status`, and `session-history`; wall-clock
  is shown as secondary context.
- `SESSION_IDLE_THRESHOLD_SECONDS` is reinterpreted as the reading-grace cap and
  its default changes from 300s to **120s**.
- Historical `history.jsonl` entries written before this release keep their old
  subtractively-computed `active_seconds`/`idle_seconds` values — they are not
  retroactively recomputed, so `session-history` totals spanning the upgrade mix
  the two models.

## [2.5.0] - 2026-05-13

### Added
- `UserPromptSubmit` and `Stop` hooks that append `P <ts>` / `S <ts>` events to
  `~/.claude/session-env/<session_id>/events.log`.
- Active vs idle time accounting: gaps between `Stop` and the next prompt that
  exceed `SESSION_IDLE_THRESHOLD_SECONDS` (default 300s) count as idle, the
  rest as active.
- `active_seconds` and `idle_seconds` fields in the JSONL history written by
  `SessionEnd`.

### Changed
- `session-status` skill output now reports active and idle alongside total
  elapsed: `Session: 1h 23m (active: 48m, idle: 35m, started at 14:30)`.
- `reset-session` skill now also truncates `events.log` so the new window
  starts with no historical events.

## [2.4.0] - 2026-04-14

### Added
- `SessionEnd` hook that appends finished sessions to
  `~/.claude/session-env/history.jsonl`.
- `/session-tracker:session-history` command and skill for reviewing past
  sessions, filterable by date and project.
- `/session-tracker:tag-session` command and `issue-tag` file for explicit
  issue association, with branch-name fallback (`[A-Z][A-Z0-9_]+-[0-9]+`).
- `/session-tracker:worklog` command — MCP-agnostic worklog generation.
- Daily total in `session-status` (sum of today's finished sessions + live
  elapsed).

## [2.1.0] - 2026-02-12

### Changed
- Use `session_id` directly as the file identifier; dropped the
  `CLAUDE_ENV_FILE` indirection. Session ID is stable across compact/resume,
  so no `PreCompact` hook is needed.
- Statusline snippet now resolves the session file via a fallback chain.

## [2.0.0] - 2026-02-12

### Added
- Persistent session files: data survives session end so hours can be tallied
  later.
- `/session-tracker:reset-session` skill to zero the live timer.

### Changed
- **Breaking:** session storage moved from process-scoped `$PPID` files to
  per-session files under `~/.claude/session-env/`.

## [1.1.0] - 2026-02-11

### Changed
- Track sessions by `session_id` instead of `$PPID` so the timer survives
  context compaction.

## [1.0.0] - 2026-02-11

### Added
- Initial release: `SessionStart` hook + `session-status` skill + optional
  statusline snippet for live elapsed time.

[4.0.0]: https://github.com/aguinaldotupy/claude-session-tracker/compare/v3.2.0...v4.0.0
[3.2.0]: https://github.com/aguinaldotupy/claude-session-tracker/compare/v3.1.1...v3.2.0
[3.1.1]: https://github.com/aguinaldotupy/claude-session-tracker/compare/v3.1.0...v3.1.1
[3.1.0]: https://github.com/aguinaldotupy/claude-session-tracker/compare/v3.0.2...v3.1.0
[3.0.2]: https://github.com/aguinaldotupy/claude-session-tracker/compare/v3.0.1...v3.0.2
[3.0.1]: https://github.com/aguinaldotupy/claude-session-tracker/compare/v3.0.0...v3.0.1
[3.0.0]: https://github.com/aguinaldotupy/claude-session-tracker/compare/v2.6.0...v3.0.0
[2.6.0]: https://github.com/aguinaldotupy/claude-session-tracker/compare/v2.5.0...v2.6.0
[2.5.0]: https://github.com/aguinaldotupy/claude-session-tracker/compare/v2.4.0...v2.5.0
[2.4.0]: https://github.com/aguinaldotupy/claude-session-tracker/compare/v2.1.0...v2.4.0
[2.1.0]: https://github.com/aguinaldotupy/claude-session-tracker/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/aguinaldotupy/claude-session-tracker/compare/v1.1.0...v2.0.0
[1.1.0]: https://github.com/aguinaldotupy/claude-session-tracker/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/aguinaldotupy/claude-session-tracker/releases/tag/v1.0.0
