# session-query CLI — Design

**Date:** 2026-07-14
**Status:** Approved (brainstorming) — pending implementation plan
**Target release:** v3.1.0 (refactor; no behavior change for the user)

## 1. Problem

The read logic lives as large inline bash blocks inside the skill Markdown
(`session-status/SKILL.md`, `session-history/SKILL.md`): the SQLite-vs-JSONL
fallback guard, the SQL queries, and the forensic-timeline `awk`. This has three
concrete costs, all felt during the v3.0.x work:

1. **Duplication.** The SQLite/JSONL guard is copied across three blocks (the
   session-status daily total, and the session-history table + daily sum). The
   v3.0.2 guard fix required editing all three; a single owner would have been a
   one-line change.
2. **Copy/adapt fragility.** The agent copies these large snippets and sometimes
   *adapts* them (quoting, awk quotes, `$SID` interpolation) — the source of the
   "conflicts" the maintainer observed.
3. **No test coverage.** Skill Markdown bash never runs in the suite. Only
   `db.sh` (the write path) is tested; the entire read path is a blind spot.

## 2. Goals / Non-goals

**Goals**
- Extract all read logic into one tested bash CLI, `session-query`, that returns
  structured JSON for the agent to render.
- Remove the duplicated guard and the inline timeline `awk` from the skills.
- Make the read path covered by the plain-bash test suite.
- Preserve current behavior exactly (same numbers, same fallback semantics).
- Keep the zero-extra-runtime philosophy: bash + `jq` + `sqlite3` only. **No
  bun/Node.**

**Non-goals**
- No change to the write path (`session-end.sh`, `db.sh` write functions,
  `import-history`) — untouched.
- No new user-facing features; this is a refactor.
- The `/worklog` MCP-posting proposal stays in the command; the CLI only returns
  the grouping data.
- `reset-session`, `tag`, `tag-session` (writes) are out of scope.

## 3. CLI surface

One executable `session-query` (bash). **Output is always JSON** with a
`source` field (`"sqlite"` | `"jsonl"` | `"none"`) telling the agent where the
data came from. Default `--range today`; dates in local time (unchanged).

### 3.1 `session-query status [--session <id>]`
For `/session-status`. Bundles the live session (active/elapsed via
`active-time.awk` over the current `events.log`) with today's aggregate.
`--session` defaults to `$CLAUDE_SESSION_ID`.
```json
{ "source":"sqlite",
  "live":  { "elapsed_seconds":4200, "active_seconds":3100, "started_at":1780000000, "issue_key":"BEL-12" },
  "today": { "active_seconds":18300, "sessions":5 } }
```

### 3.2 `session-query history [--range today|yesterday|7d|30d|FROM..TO] [--project <substr>]`
For `/session-history` (table + total).
```json
{ "source":"sqlite", "total_active_seconds":10860, "count":2,
  "rows":[ {"start":1780,"start_local":"09:12","end":1795,"end_local":"10:45",
            "active_seconds":5580,"project":"bel","branch_issue":"BEL-12"} ] }
```
Each row carries raw epochs (`start`/`end`) and portable preformatted local
`HH:MM` (`start_local`/`end_local`, via `sqlite strftime` / `jq strflocaltime` —
see §8). `branch_issue` = `COALESCE(NULLIF(issue_key,''), NULLIF(branch,''), '—')`.
Project filter matches `projects.project_root` OR `sessions.project_dir`
(substring, case-insensitive).

### 3.3 `session-query timeline <session_id>`
For the forensic "filme". The CLI runs the timeline `awk` internally (moved out
of the skill), sourcing events from the `events` table when present, else the
live `events.log`.
```json
{ "source":"sqlite",
  "intervals":[ {"prompt":1780,"prompt_local":"09:13","stop":1795,"stop_local":"09:31",
                 "work_seconds":1082,"api_error":false,
                 "tools":[{"tool":"Read","seconds":12,"failed":false},
                          {"tool":"Bash","seconds":242,"failed":true}]} ] }
```
`failed` reflects a `DF` mark; `api_error` reflects an `SF` mark. `*_local` are
portable preformatted `HH:MM` (see §8).

### 3.4 `session-query worklog [--range ...] [--project ...]`
For `/worklog` (grouping only; MCP posting stays in the command).
```json
{ "source":"sqlite",
  "by_issue":[ {"issue_key":"BEL-12","project":"bel","active_seconds":7200,"sessions":3} ],
  "untagged": {"active_seconds":1800,"sessions":2} }
```

### 3.5 Contract
- Every subcommand emits parseable JSON and exits 0 — even when empty or on an
  internal error (empty arrays + a `source`, never stderr leaking to the agent).
- `--range` accepts `today` (default), `yesterday`, `7d`, `30d`,
  `YYYY-MM-DD..YYYY-MM-DD`. An unrecognized range falls back to `today`.

## 4. Architecture

### 4.1 File + deploy
- `hooks/lib/session-query.sh` in the repo.
- `SessionStart` deploys three files to `~/.claude/session-env/` (today it
  deploys only `active-time.awk`): `active-time.awk`, `db.sh`, and
  `session-query.sh`. `cp -f` on every start keeps them fresh across plugin
  updates. Skills invoke the stable path because they run outside the plugin dir
  (the same reason `active-time.awk` is deployed today).

### 4.2 Internal structure
- `session-query.sh` does `source "$(dirname "$0")/db.sh"` and reuses
  `st_db_path`, `st_has_sqlite`, `st_sql_escape` — no duplicated helpers. `db.sh`
  write functions are present but unused (harmless).
- **The guard lives here, once**: when `history.jsonl` exists (migration pending
  or `sqlite3` absent) read the deduped JSONL; otherwise read SQLite. This is the
  single owner of the logic that was copied across three skill blocks.
- **The timeline `awk`** (previously inline in `session-history/SKILL.md`) moves
  into `session-query.sh` behind `timeline`.
- `status` invokes the deployed `active-time.awk` over the current session's
  `events.log` for the live figures.
- JSON is produced with `sqlite3 -json` / `jq` (no hand-built JSON strings).

### 4.3 Soft-dependency behavior
- `sqlite3` absent → deduped JSONL fallback → `"source":"jsonl"`.
- No DB and no `history.jsonl` → `"source":"none"`, empty arrays.
- Any internal failure is swallowed; the command still emits valid JSON and
  exits 0. Never blocks, never leaks stderr into the agent's context.

## 5. Skill changes

Each skill keeps its **prose** (when to trigger, how to render in PT/EN) and
replaces the large bash block with a single invocation plus a "render this JSON
like so" instruction:
- `session-status/SKILL.md` → one `status` call; render live + daily.
- `session-history/SKILL.md` → `history` for the table, `timeline <sid>` for the
  filme; the inline SQL, the JSONL fallback, and the timeline `awk` are removed.
- `worklog` command → `worklog` call for grouping; MCP-posting prose unchanged.

The skills remain untested Markdown, but now contain only a one-line call and
prose — almost nothing to break. All logic lives in the tested CLI.

## 6. Testing

New `tests/session-query.test.sh` (plain-bash harness: `lib.sh`, temp `$HOME`,
build a DB via `st_upsert_session`, invoke the repo's `hooks/lib/session-query.sh`
— which sources its sibling `db.sh`, so no deploy needed — and assert on
`jq`-extracted fields).

- **status**: live active/elapsed from a fabricated `events.log` + today total
  from the DB; JSON shape.
- **history**: `--range` (today/7d/FROM..TO) and `--project`; `rows`,
  `total_active_seconds`, `count`; `branch_issue` precedence (issue→branch→`—`).
- **timeline**: intervals + tools; `failed` (DF) and `api_error` (SF) flags.
- **worklog**: grouping by `issue_key` + `untagged` bucket.
- **guard (key)**: (1) jsonl absent + DB → `source:"sqlite"`; (2) **jsonl present
  + partial DB → `source:"jsonl"`** (reads the complete deduped log — locks in
  the v3.0.1/v3.0.2 fix at the read layer); (3) `sqlite3` stubbed off `PATH` →
  `source:"jsonl"`; (4) no DB, no jsonl → `source:"none"`, empty.
- **robustness**: every subcommand emits parseable JSON and exits 0 even when
  empty; an invalid `--range` does not error; empty-after-filter → valid empty
  JSON.

**Test migration**: `read-queries.test.sh` currently asserts loose SQL. That
logic now lives in the CLI, so those assertions move into
`session-query.test.sh` (testing real CLI output), and `read-queries.test.sh` is
removed. `tests/run.sh` globs `*.test.sh`, so the new file is picked up
automatically.

## 7. Rollout

- v3.1.0 (minor; refactor, behavior-preserving).
- SessionStart deploys the two additional files; existing sessions get them on
  their next start.
- README: note the `session-query` helper as the single read entry point (brief;
  keep README human-focused).
- CHANGELOG `[Unreleased]`: Changed — read path consolidated into the
  `session-query` CLI; skills now call it instead of embedding SQL/awk.

## 8. Portability (multi-OS)

The plugin is bash + POSIX tools, so `session-query` must run wherever the rest
of the plugin does:

- **Supported:** macOS (darwin), any Linux (Arch, Debian, …), and Windows **via
  WSL or Git Bash**. **Not** native Windows (cmd/PowerShell) — the whole plugin
  is bash (`#!/usr/bin/env bash`, uses `<<<`, `< <()`, `${x##}`); this is already
  true today and unchanged by this work.
- **Hard deps everywhere:** `bash` (real bash, ≥3.2), `jq`, and coreutils (`awk`,
  `sed`, `grep`, `mkdir`, `date`). `jq` is not preinstalled on any OS — it is a
  documented requirement.
- **Soft dep:** `sqlite3` (Debian `sqlite3`, Arch `sqlite`, macOS built-in) —
  absence falls back to the deduped JSONL path (`source:"jsonl"`).
- **Optional:** `flock` (Linux only; macOS/Git-Bash lack it → guarded no-op).

**Rules the CLI must follow to stay portable (BSD ↔ GNU differences):**
1. **No `date -r` / `date -d`.** The only `date` call is `date +%s` (universal).
   All human times are formatted via `sqlite3 strftime(..., 'unixepoch',
   'localtime')` on the SQLite path and `jq strflocaltime` on the JSONL fallback
   — both portable. JSON therefore carries raw epochs **plus** preformatted
   local strings, so the agent never does timezone math and no `date`
   formatting runs. (E.g. `history` rows gain `start_local`/`end_local` "HH:MM".)
2. **`awk` stays one-true-awk safe** — arrays only, no `strftime`/`gensub`/
   `asort`/`systime`. The timeline awk moving into the CLI keeps this constraint
   (it already holds).
3. **No `readlink -f` / `realpath`** — use `cd … && pwd` / `pwd -P`.
4. **`sed` uses only basic substitution** (`st_sql_escape`'s `s/'/''/g`), which
   is identical on BSD and GNU sed.
5. **`flock` guarded** (`command -v flock` / `2>/dev/null || true`).

## 9. Edge cases

- `status` with no current `events.log` (session just started) → `live` zeros,
  `today` still populated.
- `timeline <sid>` for a session not in the DB and whose `events.log` was cleaned
  up → `intervals: []` (valid JSON), and the skill reports "sem timeline".
- A `--project` substring with a quote is escaped via `st_sql_escape` (no SQL
  injection through the filter).
- Deployed copies going stale is prevented by the `cp -f` on every SessionStart
  (same guarantee as `active-time.awk` today).
