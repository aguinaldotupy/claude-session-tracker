# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, OpenCode, Antigravity, and other agentic environments) when working with code in this repository.

## What this is

A multi-harness plugin (`session-tracker`) that tracks session working time via lifecycle hooks across Claude Code, OpenCode, and Google Antigravity (AGY). Bash shell scripts + awk + jq + SQLite — no build step, no package manager. Version lives in `.claude-plugin/plugin.json`.

## Commands

```bash
bash tests/run.sh                    # run all tests
bash tests/session-query.test.sh     # run a single test file
bash tests/agy-plugin.test.sh        # run AGY plugin tests
```

Tests use the minimal harness in `tests/lib.sh` (`assert_eq`, `finish`). Each test file creates a `mktemp -d` and re-exports `HOME` into it, so tests never touch the real `~/.session-tracker/`. `tests/lib.sh` unsets `SESSION_IDLE_THRESHOLD_SECONDS` and session harness env vars for determinism.

Releases are cut with the `/release` skill (bumps semver in `.claude-plugin/plugin.json`, updates `CHANGELOG.md`, tags, pushes, creates the GitHub release).

## Architecture

Two sides, connected by files under the **store home** — `$SESSION_TRACKER_HOME`, default `~/.session-tracker/`. `st_home` in `db.sh` resolves it on every call (never cached, so tests and callers can scope it with `HOME`/env). Everything lived under `~/.claude/session-env/` before v4; `st_migrate_home` moves that directory on the first `SessionStart` and leaves a symlink behind so statusline snippets users already pasted into `settings.json`, and any detached `solidtime-sync.sh` from a previous session, keep resolving. The home is harness-neutral on purpose: nothing about it is tied to a single editor, so multiple harnesses (Claude Code, OpenCode, Antigravity) share one store, one worklog, one Solidtime sync.

**Write side — hooks** (`hooks/`, registered in `hooks/hooks.json` and `agy/hooks.json`):
- `session-start.sh`: migrates the legacy home (must happen before the first `mkdir`), writes the start timestamp to `<home>/<session_id>/session-tracker` and the session's `cwd` alongside it (the only record of which project a crashed session belonged to), initializes the SQLite store, migrates any legacy `history.jsonl` (via `lib/import-history.sh`), and **deploys the read-side libs** (`active-time.awk`, `db.sh`, `session-query.sh`, `solidtime-sync.sh`, `reap-sessions.sh`) to the store home — a stable path, because the statusline, skills, and sidecars run outside the plugin directory.
- `user-prompt-submit.sh` / `stop.sh` / `stop-failure.sh` / `pre-tool-use.sh` / `post-tool-use.sh` / `post-tool-use-failure.sh`: append one-letter event lines (`P`, `S`, `SF`, `T <tool>`, `D <tool>`, `DF <tool>`) to `<session_id>/events.log`. Tool events record the tool name only, never arguments.
- `reap-sessions.sh` (in `lib/`, deployed and launched detached by `SessionStart` or run on a schedule by Antigravity's sidecar): finalizes sessions that died **without** a `SessionEnd` — a crash, a `kill`, or an environment that was abruptly closed. Everything the accounting needs is already durable in `events.log`, so it closes such a session from its own **last event** (never from `now`: that is the last moment we know it was working, and we know nothing after it). A session with no events has no such evidence and is skipped rather than given an invented end. Staleness threshold `SESSION_TRACKER_STALE_SECONDS` (default 14400 = 4h), prefiltered to the last `SESSION_TRACKER_REAP_WINDOW_DAYS` (default 7) so the sweep stays O(recent). Being wrong is self-correcting: `st_upsert_session` only overwrites a row whose stored `end_ts` is older, so a session that turns out to still be alive wins when it ends properly.
- `session-end.sh`: computes active time from `events.log`, resolves the issue key (explicit `issue-tag` file wins, then branch-name regex `[A-Z][A-Z0-9_]+-[0-9]+`), and upserts into SQLite; falls back to appending to `history.jsonl` when `sqlite3` is missing.

**Read side — one entry point**: `hooks/lib/session-query.sh` (subcommands `status`, `history`, `timeline`, `worklog`) owns all query logic and the SQLite-vs-JSONL fallback in one tested place. It always emits JSON, always exits 0, never leaks stderr. The skills (`skills/*/SKILL.md`), commands (`commands/*.md`), and `statusline-snippet.sh` are prompt/snippet files that invoke the **deployed copy** at `<home>/session-query.sh` (default `~/.session-tracker/session-query.sh`) — they contain no query logic of their own. Resolves live session via `CLAUDE_SESSION_ID`, `CLAUDE_CODE_SESSION_ID`, `ANTIGRAVITY_CONVERSATION_ID`, or fallback to `<home>/current-session`.

**Storage** (`hooks/lib/db.sh` + `schema.sql`): SQLite at `~/.session-tracker/history.db` (WAL mode), tables `projects` / `sessions` / `events` / `meta`. The `events` table is **legacy**: nothing writes to it since the per-line import was removed (it blew the 5s hook budget); `sq_timeline` reads the persisted `events.log` and falls back to the table only for rows imported by older versions. `sqlite3` is a soft dependency — every function guards with `st_has_sqlite` and the JSONL path keeps everything working without it. While `history.jsonl` still exists, it is authoritative (`_sq_source` in session-query.sh); import on next SessionStart renames it to `.imported`.

**Active-time model** (`hooks/lib/active-time.awk`): active time is additive — each prompt→stop bracket counts in full, plus up to `SESSION_IDLE_THRESHOLD_SECONDS` (default 120) of reading grace after each stop. Any change to time accounting goes in this one awk file; the SessionEnd hook, `session-query.sh`, and the statusline all share it.

**Sync side — opt-in** (`hooks/lib/solidtime-sync.sh`, deployed like the read-side libs): posts each active bracket of a finished session to a Solidtime instance as one time entry. Configured by the `solidtime:` section of `~/.session-tracker/config.yml` (chmod 600) or, when that file is absent, `SOLIDTIME_URL`/`SOLIDTIME_TOKEN`/`SOLIDTIME_ORG_ID` env vars — the file always wins. With neither, every sync path exits 0 silently and the plugin behaves exactly as before. `active-time.awk -v mode=brackets` emits the `start end` pairs; idempotency is a per-session ledger (`<sid>/solidtime-synced`) keyed by `<start> <end>` epochs, so a bracket a resume has grown posts only its continuation. Discovery only ever considers sessions the history store says have ended, filtered by the `solidtime-since` watermark written when sync is first configured (enabling sync never backfills old history). Errors always land in `<home>/solidtime-sync.log` (default `~/.session-tracker/solidtime-sync.log`) and surface through `session-query.sh status`'s `sync` object.

**Config** (`db.sh`): one file for the whole plugin, `<home>/config.yml`. `st_config_parse` reads a deliberate YAML *subset* (`section:` + one level of `key: value`, `#` comments, one layer of outer quotes; `SECTION_KEY` uppercased) so no `yq`/python dependency creeps in; `st_config_load` exports the results one at a time. Nothing is ever evaluated — the old `solidtime.conf` was `source`d, which executed whatever it held and made a Sanctum token's `|` a quoting hazard. `st_config_set <section> <key> <value>` rewrites exactly one key in place; `st_migrate_config` converts a legacy `solidtime.conf` on the first `SessionStart` (sourcing it once, as the old client did) and archives it as `.migrated`.

**Project identity**: `st_project_root` in `db.sh` collapses git worktrees to the canonical repo root (`dirname` of `git rev-parse --git-common-dir`), so sessions in worktrees group under the main repo. `st_backfill_worktrees` is the one-time migration for older DBs, gated by a `meta` flag.

**opencode side** (`opencode/plugin.js`): opencode has no shell-hook system and no session-end event, so this is an adapter, not a second implementation — it spawns the *same* `hooks/*.sh` with the same stdin JSON, into the same store. `chat.message`→`user-prompt-submit`, `tool.execute.before/after`→`pre/post-tool-use`, `session.idle`→`stop`, `session.error`→`stop-failure`, `dispose`→`session-end`; a session is initialised on first sighting with `source: "resume"` (so re-attaching never truncates a live `events.log`), and `shell.env` publishes `SESSION_TRACKER_SESSION_ID`/`CLAUDE_SESSION_ID` so the skills locate the live session unchanged. Hooks are serialised through one promise chain — `events.log` must stay time-ordered for `active-time.awk` — and awaited only on idle/error/dispose, never on the per-tool path. Skills and commands are shared verbatim (opencode reads body-as-prompt markdown and discovers `.claude/skills/`); no fork of either exists, and none should.

**agy (Antigravity) side** (`agy/`): Antigravity uses lifecycle hooks (`PreInvocation`, `PreToolUse`, `PostToolUse`, `Stop`) with camelCase JSON on stdin and requires strict JSON on stdout (`decision: "allow"` or `{}`). `agy/hook-adapter.sh` maps `PreInvocation` $\to$ lazy session start + `user-prompt-submit`, `PreToolUse` $\to$ `pre-tool-use`, `PostToolUse` $\to$ `post-tool-use` (or failure), `Stop` $\to$ `stop` + store checkpoint (`session-end.sh`). It maintains `<home>/current-session` and respects `ANTIGRAVITY_CONVERSATION_ID`. `agy/sidecars/session-reaper/sidecar.json` provides an AGY-native recurring background schedule for sweeping crashed sessions and running Solidtime sync. Skills are linked in `agy/skills/`.

## Hard rules

- **Hooks must never block the host environment.** Every hook must handle errors gracefully, guard critical steps, and ensure it exits 0 so internal tracker failures never abort host editor commands. Hook timeouts in `hooks.json` are 5s. Keep it that way.
- **Always quote `"${CLAUDE_PLUGIN_ROOT}"` in `hooks.json`** — the desktop app's plugin path contains a space and unquoted expansion word-splits under `sh -c`.
- **`session_id` is the identifier, never `$PPID`** — it is stable across context compaction. Read it from the hook's stdin JSON; in skills, from `CLAUDE_SESSION_ID` with `CLAUDE_CODE_SESSION_ID` and `ANTIGRAVITY_CONVERSATION_ID` as fallbacks.
- **The sync must never make a hook wait.** Hooks launch it detached (`( bash ... & )`) behind a config guard and exit; only `SessionEnd`/`SessionStart`/the manual command trigger it.
- **Deploy libs with temp-file + rename, never `cp -f`** — a detached `solidtime-sync.sh` from a previous session can be mid-execution, and bash reads scripts lazily by offset, so rewriting the inode makes it resume in the new bytes.
- **`SOLIDTIME_TOKEN` never reaches a log**, and verbose output goes to stderr — resolvers are read via command substitution, so anything on stdout becomes a payload field.
- **The start timestamp and `events.log` are one window**: whatever resets one truncates the other (`/clear`, reset-session). Leaving stale events behind over-bills every reader, sync included.
- **`st_migrate_home` runs before anything creates the new home.** It only moves into a home that does not exist yet (or is empty), so a `mkdir -p` ahead of it strands the old store. In `session-start.sh` the migration is the first thing after parsing stdin.
- **Never regenerate `config.yml` wholesale** — it holds the whole plugin's config. Writers go through `st_config_set`, which touches one key and leaves every other section byte-identical.
- **Never hardcode the store path.** Libs call `st_home`; hook entry points and the statusline snippet inline `${SESSION_TRACKER_HOME:-$HOME/.session-tracker}`. The only place the legacy path may appear is `st_legacy_home`.
- SQL values built in shell must go through `st_sql_escape`; an empty branch/issue/**project** becomes SQL `NULL`, not `''`. An unknown project means `sessions.project_id IS NULL` and *no* `projects` row — never a row keyed on the empty string, which would collect every unattributed session under one blank name. The read side renders that as `—`.
- **The opencode and agy plugins adapt, they never reimplement.** Any change to time accounting, storage, or sync goes in the shell; adapters only ever translate environment lifecycle events into `hooks/*.sh` invocations. If they start computing something, that logic belongs in the shell instead.
- `jq` and `bash` are required dependencies; `sqlite3` is optional — never make a code path hard-depend on it. Native Windows is unsupported (Bash/awk only).
- README is human-focused: describe behavior and reference files; don't paste raw scripts into it.

## Working docs

Design specs and implementation plans live in `docs/superpowers/{specs,plans}/`; `.superpowers/sdd/` holds task briefs and review diffs from past subagent-driven work — historical context, not source.
