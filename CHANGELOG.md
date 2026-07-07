# Changelog

All notable changes to this plugin are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[2.5.0]: https://github.com/aguinaldotupy/claude-session-tracker/compare/v2.4.0...v2.5.0
[2.4.0]: https://github.com/aguinaldotupy/claude-session-tracker/compare/v2.1.0...v2.4.0
[2.1.0]: https://github.com/aguinaldotupy/claude-session-tracker/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/aguinaldotupy/claude-session-tracker/compare/v1.1.0...v2.0.0
[1.1.0]: https://github.com/aguinaldotupy/claude-session-tracker/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/aguinaldotupy/claude-session-tracker/releases/tag/v1.0.0
