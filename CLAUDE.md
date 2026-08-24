# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Claude Code plugin (`session-tracker`) that tracks session working time via lifecycle hooks. Pure POSIX shell + awk + jq + SQLite — no build step, no package manager. Version lives in `.claude-plugin/plugin.json`.

## Commands

```bash
bash tests/run.sh                    # run all tests
bash tests/session-query.test.sh     # run a single test file
```

Tests use the minimal harness in `tests/lib.sh` (`assert_eq`, `finish`). Each test file creates a `mktemp -d` and re-exports `HOME` into it, so tests never touch the real `~/.claude/session-env/`. `tests/lib.sh` unsets `SESSION_IDLE_THRESHOLD_SECONDS` for determinism.

Releases are cut with the `/release` skill (bumps semver in `.claude-plugin/plugin.json`, updates `CHANGELOG.md`, tags, pushes, creates the GitHub release).

## Architecture

Two sides, connected by files under `~/.claude/session-env/`:

**Write side — hooks** (`hooks/`, registered in `hooks/hooks.json`):
- `session-start.sh`: writes the start timestamp to `~/.claude/session-env/<session_id>/session-tracker`, initializes the SQLite store, migrates any legacy `history.jsonl` (via `lib/import-history.sh`), and **deploys the read-side libs** (`active-time.awk`, `db.sh`, `session-query.sh`, `solidtime-sync.sh`) to `~/.claude/session-env/` — a stable path, because the statusline and skills run outside the plugin directory.
- `user-prompt-submit.sh` / `stop.sh` / `stop-failure.sh` / `pre-tool-use.sh` / `post-tool-use.sh` / `post-tool-use-failure.sh`: append one-letter event lines (`P`, `S`, `SF`, `T <tool>`, `D <tool>`, `DF <tool>`) to `<session_id>/events.log`. Tool events record the tool name only, never arguments.
- `session-end.sh`: computes active time from `events.log`, resolves the issue key (explicit `issue-tag` file wins, then branch-name regex `[A-Z][A-Z0-9_]+-[0-9]+`), and upserts into SQLite; falls back to appending to `history.jsonl` when `sqlite3` is missing.

**Read side — one entry point**: `hooks/lib/session-query.sh` (subcommands `status`, `history`, `timeline`, `worklog`) owns all query logic and the SQLite-vs-JSONL fallback in one tested place. It always emits JSON, always exits 0, never leaks stderr. The skills (`skills/*/SKILL.md`), commands (`commands/*.md`), and `statusline-snippet.sh` are prompt/snippet files that invoke the **deployed copy** at `~/.claude/session-env/session-query.sh` — they contain no query logic of their own.

**Storage** (`hooks/lib/db.sh` + `schema.sql`): SQLite at `~/.claude/session-env/history.db` (WAL mode), tables `projects` / `sessions` / `events` / `meta`. The `events` table is **legacy**: nothing writes to it since the per-line import was removed (it blew the 5s hook budget); `sq_timeline` reads the persisted `events.log` and falls back to the table only for rows imported by older versions. `sqlite3` is a soft dependency — every function guards with `st_has_sqlite` and the JSONL path keeps everything working without it. While `history.jsonl` still exists, it is authoritative (`_sq_source` in session-query.sh); import on next SessionStart renames it to `.imported`.

**Active-time model** (`hooks/lib/active-time.awk`): active time is additive — each prompt→stop bracket counts in full, plus up to `SESSION_IDLE_THRESHOLD_SECONDS` (default 120) of reading grace after each stop. Any change to time accounting goes in this one awk file; the SessionEnd hook, `session-query.sh`, and the statusline all share it.

**Sync side — opt-in** (`hooks/lib/solidtime-sync.sh`, deployed like the read-side libs): posts each active bracket of a finished session to a Solidtime instance as one time entry. Configured by `~/.claude/session-env/solidtime.conf` (chmod 600) or, when that file is absent, `SOLIDTIME_URL`/`SOLIDTIME_TOKEN`/`SOLIDTIME_ORG_ID` env vars — the file always wins. With neither, every sync path exits 0 silently and the plugin behaves exactly as before. `active-time.awk -v mode=brackets` emits the `start end` pairs; idempotency is a per-session ledger (`<sid>/solidtime-synced`) keyed by `<start> <end>` epochs, so a bracket a resume has grown posts only its continuation. Discovery only ever considers sessions the history store says have ended, filtered by the `solidtime-since` watermark written when sync is first configured (enabling sync never backfills old history). Errors always land in `~/.claude/session-env/solidtime-sync.log` and surface through `session-query.sh status`'s `sync` object.

**Project identity**: `st_project_root` in `db.sh` collapses git worktrees to the canonical repo root (`dirname` of `git rev-parse --git-common-dir`), so sessions in worktrees group under the main repo. `st_backfill_worktrees` is the one-time migration for older DBs, gated by a `meta` flag.

## Hard rules

- **Hooks must never block Claude Code.** Every hook wraps its body in `{ ... } || exit 0` and exits 0 on any failure; hook timeouts in `hooks.json` are 5s. Keep it that way.
- **Always quote `"${CLAUDE_PLUGIN_ROOT}"` in `hooks.json`** — the desktop app's plugin path contains a space and unquoted expansion word-splits under `sh -c`.
- **`session_id` is the identifier, never `$PPID`** — it is stable across context compaction. Read it from the hook's stdin JSON; in skills, from `CLAUDE_SESSION_ID` with `CLAUDE_CODE_SESSION_ID` as fallback.
- **The sync must never make a hook wait.** Hooks launch it detached (`( bash ... & )`) behind a config guard and exit; only `SessionEnd`/`SessionStart`/the manual command trigger it.
- **Deploy libs with temp-file + rename, never `cp -f`** — a detached `solidtime-sync.sh` from a previous session can be mid-execution, and bash reads scripts lazily by offset, so rewriting the inode makes it resume in the new bytes.
- **`SOLIDTIME_TOKEN` never reaches a log**, and verbose output goes to stderr — resolvers are read via command substitution, so anything on stdout becomes a payload field.
- **The start timestamp and `events.log` are one window**: whatever resets one truncates the other (`/clear`, reset-session). Leaving stale events behind over-bills every reader, sync included.
- SQL values built in shell must go through `st_sql_escape`; empty branch/issue become SQL `NULL`, not `''`.
- `jq` and `bash` are required dependencies; `sqlite3` is optional — never make a code path hard-depend on it. Native Windows is unsupported (POSIX shell/awk only).
- README is human-focused: describe behavior and reference files; don't paste raw scripts into it.

## Working docs

Design specs and implementation plans live in `docs/superpowers/{specs,plans}/`; `.superpowers/sdd/` holds task briefs and review diffs from past subagent-driven work — historical context, not source.
