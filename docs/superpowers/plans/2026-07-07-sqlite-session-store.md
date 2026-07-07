# SQLite Session Store — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the append-only `history.jsonl` aggregate store with a relational SQLite database (`projects`/`sessions`/`events`) that fixes the 78% total-inflation bug, groups worktrees by canonical git project root, and archives heartbeats durably — with automatic idempotent migration and graceful fallback when `sqlite3` is absent.

**Architecture:** Heartbeat hooks stay unchanged (text `events.log` hot-path). A shared sourceable library `hooks/lib/db.sh` (schema init, `project_root` derivation, session upsert, event import) is used by `session-start.sh` (ensure DB + migrate) and `session-end.sh` (upsert one row per session). Skills read SQLite directly via `sqlite3`, falling back to the legacy jq/awk paths when the DB or binary is absent.

**Tech Stack:** POSIX-ish bash, `sqlite3` CLI (WAL mode), `jq`, one-true-`awk`. Plain-bash test suite under `tests/`.

## Global Constraints

- **Never block a hook.** Every hook wraps work in `{ ... } || exit 0` and always `exit 0`. Copied from existing hooks.
- **`sqlite3` is a SOFT dependency.** If `command -v sqlite3` fails, the write path falls back to appending the legacy JSON line to `history.jsonl`; skills fall back to jq/awk reads. No crash, no block.
- **Detail level B.** Events carry tool *type* only — never arguments or paths. Unchanged from current hooks.
- **DB path:** `$HOME/.claude/session-env/history.db` (one global DB, all projects).
- **SQL safety:** never string-interpolate untrusted values (paths, branch, issue_key, tool) without escaping single quotes via `st_sql_escape` (doubles `'`). Numeric fields are coerced with `$((x+0))` before interpolation.
- **Schema:** exactly the DDL in the design doc §4.1. Tables `projects`, `sessions`, `events`, `meta`. Use `CREATE TABLE IF NOT EXISTS` (idempotent).
- **Upsert guard:** session upsert updates only `WHERE excluded.end_ts >= sessions.end_ts` (max-end_ts wins, order-independent).
- **Legacy migration defaults:** `project_root := project_dir`, `branch := NULL`, `active_seconds := active_seconds // duration_seconds // 0`.
- **Reference spec:** `docs/superpowers/specs/2026-07-07-sqlite-session-store-design.md`.
- **Tests require `sqlite3`** on PATH (present on macOS; document in README).

---

## File Structure

**Create:**
- `hooks/lib/schema.sql` — the DDL (single source of schema).
- `hooks/lib/db.sh` — sourceable helpers: `st_db_path`, `st_has_sqlite`, `st_sql_escape`, `st_db_init`, `st_project_root`, `st_upsert_session`, `st_import_events`.
- `hooks/lib/import-history.sh` — sourceable: `st_import_history` (idempotent JSONL → SQLite migration).
- `tests/db.test.sh`, `tests/import.test.sh`, `tests/read-queries.test.sh` — new suites.

**Modify:**
- `hooks/session-start.sh` — ensure DB/schema + run importer.
- `hooks/session-end.sh` — compute `project_root`/`branch`, call `st_upsert_session` + `st_import_events`, JSONL fallback.
- `skills/session-status/SKILL.md` — daily total from SQLite.
- `skills/session-history/SKILL.md` — table, project filter, Branch/Issue column, forensic timeline from `events`.
- `tests/run.sh` — register new test files.
- `README.md` — `sqlite3` soft dependency + automatic migration note.
- `CHANGELOG.md` — `[Unreleased]` entry.

---

## Task 1: Schema file + db.sh foundation (path, sqlite check, escape, init)

**Files:**
- Create: `hooks/lib/schema.sql`
- Create: `hooks/lib/db.sh`
- Test: `tests/db.test.sh`

**Interfaces:**
- Produces: `st_db_path() → stdout path`; `st_has_sqlite() → exit 0/1`; `st_sql_escape(str) → stdout escaped`; `st_db_init() → exit 0 on success` (applies `schema.sql`, sets PRAGMAs).

- [ ] **Step 1: Write `hooks/lib/schema.sql`**

```sql
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 2000;

CREATE TABLE IF NOT EXISTS projects (
  id            INTEGER PRIMARY KEY,
  project_root  TEXT NOT NULL UNIQUE,
  name          TEXT NOT NULL,
  first_seen_ts INTEGER NOT NULL,
  last_seen_ts  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  session_id       TEXT PRIMARY KEY,
  project_id       INTEGER REFERENCES projects(id),
  project_dir      TEXT,
  branch           TEXT,
  issue_key        TEXT,
  start_ts         INTEGER NOT NULL,
  end_ts           INTEGER NOT NULL,
  duration_seconds INTEGER NOT NULL,
  active_seconds   INTEGER NOT NULL,
  idle_seconds     INTEGER NOT NULL,
  reason           TEXT,
  updated_at       INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project_id);
CREATE INDEX IF NOT EXISTS idx_sessions_start   ON sessions(start_ts);

CREATE TABLE IF NOT EXISTS events (
  id         INTEGER PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(session_id),
  ts         INTEGER NOT NULL,
  kind       TEXT NOT NULL,
  tool       TEXT
);
CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id, ts);

CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT
);
```

- [ ] **Step 2: Write `hooks/lib/db.sh` (foundation functions)**

```bash
#!/usr/bin/env bash
# Shared SQLite helpers for session-tracker. Source this file; functions never block.
# Callers are responsible for their own `|| exit 0` guards.

st_db_path() { printf '%s/.claude/session-env/history.db' "$HOME"; }

st_has_sqlite() { command -v sqlite3 >/dev/null 2>&1; }

# Double single quotes so a value is safe inside a single-quoted SQL literal.
st_sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# Create the DB and apply the (idempotent) schema. Returns non-zero if sqlite3
# or the schema file is missing.
st_db_init() {
  st_has_sqlite || return 1
  local db dir schema
  db="$(st_db_path)"; dir="$(dirname "$db")"
  schema="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/schema.sql"
  [ -f "$schema" ] || return 1
  mkdir -p "$dir"
  sqlite3 "$db" < "$schema" 2>/dev/null
}
```

- [ ] **Step 3: Write the failing test `tests/db.test.sh`**

```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
. "$DIR/../hooks/lib/db.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"

# escape doubles single quotes
assert_eq "escape doubles quotes" "O''Brien" "$(st_sql_escape "O'Brien")"

# db_init creates the three core tables + meta, idempotently
st_db_init
tables=$(sqlite3 "$(st_db_path)" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" | tr '\n' ',')
assert_eq "tables created" "events,meta,projects,sessions," "$tables"

# running init again does not error and keeps the tables
st_db_init; rc=$?
assert_eq "init idempotent" "0" "$rc"

finish
```

- [ ] **Step 4: Run test, expect PASS**

Run: `bash tests/db.test.sh`
Expected: 3 assertions pass (`escape doubles quotes`, `tables created`, `init idempotent`).

- [ ] **Step 5: Commit**

```bash
git add hooks/lib/schema.sql hooks/lib/db.sh tests/db.test.sh
git commit -m "feat(db): schema.sql + db.sh foundation (path, escape, init)"
```

---

## Task 2: `st_project_root` (canonical git root, worktree-immune)

**Files:**
- Modify: `hooks/lib/db.sh` (append function)
- Test: `tests/db.test.sh` (append cases)

**Interfaces:**
- Produces: `st_project_root(cwd) → stdout` — dirname of `git-common-dir` (absolute); the raw `cwd` when not a git repo.

- [ ] **Step 1: Write failing tests (append to `tests/db.test.sh`, before `finish`)**

```bash
# --- st_project_root ---
# main checkout: root is the repo toplevel
repo="$TMP/repo"; mkdir -p "$repo"; ( cd "$repo" && git init -q && git commit -q --allow-empty -m init )
assert_eq "root of main checkout" "$repo" "$(st_project_root "$repo")"

# worktree: root resolves to the MAIN repo, not the worktree path
wt="$TMP/wt-feature"
( cd "$repo" && git worktree add -q "$wt" -b feature ) 2>/dev/null
assert_eq "root of worktree is main repo" "$repo" "$(st_project_root "$wt")"

# non-git dir: falls back to the cwd itself
plain="$TMP/plain"; mkdir -p "$plain"
assert_eq "root of non-git is cwd" "$plain" "$(st_project_root "$plain")"
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash tests/db.test.sh`
Expected: FAIL — `st_project_root: command not found` (function missing).

- [ ] **Step 3: Implement `st_project_root` (append to `hooks/lib/db.sh`)**

```bash
# Canonical project root for a cwd, immune to the worktree path config:
# dirname(git-common-dir). Falls back to the cwd for non-git directories.
st_project_root() {
  local cwd="$1" common
  command -v git >/dev/null 2>&1 || { printf '%s' "$cwd"; return; }
  common="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || common="$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)"
  case "$common" in
    '') printf '%s' "$cwd" ;;
    /*) (cd "$(dirname "$common")" 2>/dev/null && pwd) || printf '%s' "$cwd" ;;
    *)  (cd "$cwd/$(dirname "$common")" 2>/dev/null && pwd) || printf '%s' "$cwd" ;;
  esac
}
```

- [ ] **Step 4: Run test, expect PASS**

Run: `bash tests/db.test.sh`
Expected: all assertions pass (including the 3 new root cases). Note: `git worktree` must be available; it ships with git.

- [ ] **Step 5: Commit**

```bash
git add hooks/lib/db.sh tests/db.test.sh
git commit -m "feat(db): st_project_root via git-common-dir (worktree-immune)"
```

---

## Task 3: `st_upsert_session` (one row per session, dedup by upsert)

**Files:**
- Modify: `hooks/lib/db.sh` (append function)
- Test: `tests/db.test.sh` (append cases)

**Interfaces:**
- Consumes: `st_db_init`, `st_project_root`, `st_sql_escape`.
- Produces: `st_upsert_session sid root dir branch issue start end dur active idle reason now → exit 0`. Upserts the `projects` row (by `project_root`) then the `sessions` row (by `session_id`) with the max-end_ts guard.

- [ ] **Step 1: Write failing tests (append to `tests/db.test.sh`, before `finish`)**

```bash
# --- st_upsert_session ---
st_db_init
one() { sqlite3 "$(st_db_path)" "$1"; }

# insert 3 cumulative snapshots of the SAME session (simulating repeated SessionEnd)
st_upsert_session "sX" "$repo" "$repo" "main" "" 1000 1100 100 40  60  "other" 1101
st_upsert_session "sX" "$repo" "$repo" "main" "" 1000 1300 300 120 180 "other" 1301
st_upsert_session "sX" "$repo" "$repo" "main" "" 1000 1600 600 250 350 "other" 1601

assert_eq "upsert keeps one row" "1" "$(one "SELECT COUNT(*) FROM sessions WHERE session_id='sX';")"
assert_eq "upsert keeps latest active" "250" "$(one "SELECT active_seconds FROM sessions WHERE session_id='sX';")"

# older snapshot must NOT overwrite the newer one (max-end_ts guard)
st_upsert_session "sX" "$repo" "$repo" "main" "" 1000 1200 200 90 110 "other" 1700
assert_eq "older snapshot ignored" "250" "$(one "SELECT active_seconds FROM sessions WHERE session_id='sX';")"

# project row deduped, name is basename
assert_eq "one project row" "1" "$(one "SELECT COUNT(*) FROM projects;")"
assert_eq "project name basename" "repo" "$(one "SELECT name FROM projects;")"

# injection safety: a single quote in the path stores verbatim, no SQL error
st_upsert_session "sQ" "$TMP/o'brien" "$TMP/o'brien" "" "" 5 6 1 1 0 "other" 7; rc=$?
assert_eq "quote path no error" "0" "$rc"
assert_eq "quote path stored" "$TMP/o'brien" "$(one "SELECT project_dir FROM sessions WHERE session_id='sQ';")"
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash tests/db.test.sh`
Expected: FAIL — `st_upsert_session: command not found`.

- [ ] **Step 3: Implement `st_upsert_session` (append to `hooks/lib/db.sh`)**

```bash
# st_upsert_session sid root dir branch issue start end dur active idle reason now
# Upserts projects (by project_root) and sessions (by session_id, max-end_ts wins).
st_upsert_session() {
  st_has_sqlite || return 1
  local sid="$1" root="$2" dir="$3" branch="$4" issue="$5"
  local start="$(( $6 + 0 ))" end="$(( $7 + 0 ))" dur="$(( $8 + 0 ))"
  local active="$(( $9 + 0 ))" idle="$(( ${10} + 0 ))" reason="${11}" now="$(( ${12} + 0 ))"
  local name; name="$(basename "$root")"
  local e_sid e_root e_dir e_branch e_issue e_name e_reason
  e_sid="$(st_sql_escape "$sid")";     e_root="$(st_sql_escape "$root")"
  e_dir="$(st_sql_escape "$dir")";     e_branch="$(st_sql_escape "$branch")"
  e_issue="$(st_sql_escape "$issue")"; e_name="$(st_sql_escape "$name")"
  e_reason="$(st_sql_escape "$reason")"
  sqlite3 "$(st_db_path)" <<SQL 2>/dev/null
BEGIN;
INSERT INTO projects(project_root,name,first_seen_ts,last_seen_ts)
  VALUES('$e_root','$e_name',$now,$now)
  ON CONFLICT(project_root) DO UPDATE SET last_seen_ts=$now;
INSERT INTO sessions(session_id,project_id,project_dir,branch,issue_key,
                     start_ts,end_ts,duration_seconds,active_seconds,idle_seconds,reason,updated_at)
  VALUES('$e_sid',(SELECT id FROM projects WHERE project_root='$e_root'),'$e_dir','$e_branch','$e_issue',
         $start,$end,$dur,$active,$idle,'$e_reason',$now)
  ON CONFLICT(session_id) DO UPDATE SET
    end_ts=excluded.end_ts, duration_seconds=excluded.duration_seconds,
    active_seconds=excluded.active_seconds, idle_seconds=excluded.idle_seconds,
    reason=excluded.reason, branch=excluded.branch, issue_key=excluded.issue_key,
    project_id=excluded.project_id, project_dir=excluded.project_dir, updated_at=excluded.updated_at
  WHERE excluded.end_ts >= sessions.end_ts;
COMMIT;
SQL
}
```

- [ ] **Step 4: Run test, expect PASS**

Run: `bash tests/db.test.sh`
Expected: all upsert assertions pass (one row, latest active 250, older ignored, one project, basename, injection safe).

- [ ] **Step 5: Commit**

```bash
git add hooks/lib/db.sh tests/db.test.sh
git commit -m "feat(db): st_upsert_session with max-end_ts dedup guard"
```

---

## Task 4: `st_import_events` (heartbeats → events table, idempotent)

**Files:**
- Modify: `hooks/lib/db.sh` (append function)
- Test: `tests/db.test.sh` (append cases)

**Interfaces:**
- Consumes: `st_has_sqlite`, `st_sql_escape`, `st_db_path`.
- Produces: `st_import_events sid events_log → exit 0`. Clears then re-inserts that session's events (idempotent). Ignores malformed lines.

- [ ] **Step 1: Write failing tests (append to `tests/db.test.sh`, before `finish`)**

```bash
# --- st_import_events ---
st_db_init
# session row must exist first (FK target)
st_upsert_session "sE" "$repo" "$repo" "main" "" 2000 2100 100 80 20 "other" 2101
printf 'P 2000\nT 2005 Read\nD 2017 Read\nDF 2050 Bash\nSF 2100\n' > "$TMP/ev.log"

st_import_events "sE" "$TMP/ev.log"
assert_eq "events imported" "5" "$(one "SELECT COUNT(*) FROM events WHERE session_id='sE';")"
assert_eq "DF kind stored" "1" "$(one "SELECT COUNT(*) FROM events WHERE session_id='sE' AND kind='DF';")"
assert_eq "tool captured" "Read" "$(one "SELECT tool FROM events WHERE session_id='sE' AND kind='T';")"

# re-import is idempotent (delete-then-insert), not additive
st_import_events "sE" "$TMP/ev.log"
assert_eq "re-import no dup" "5" "$(one "SELECT COUNT(*) FROM events WHERE session_id='sE';")"

# malformed lines are skipped
printf 'garbage\nP notanumber\nP 2200\n' > "$TMP/bad.log"
st_import_events "sE" "$TMP/bad.log"
assert_eq "only valid line kept" "1" "$(one "SELECT COUNT(*) FROM events WHERE session_id='sE';")"
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash tests/db.test.sh`
Expected: FAIL — `st_import_events: command not found`.

- [ ] **Step 3: Implement `st_import_events` (append to `hooks/lib/db.sh`)**

```bash
# st_import_events sid events_log — replace this session's events with the log's
# contents (idempotent). Lines are "KIND TS [TOOL]"; malformed lines skipped.
st_import_events() {
  st_has_sqlite || return 1
  local sid="$1" log="$2"
  [ -f "$log" ] || return 0
  local e_sid; e_sid="$(st_sql_escape "$sid")"
  {
    printf 'BEGIN;\n'
    printf "DELETE FROM events WHERE session_id='%s';\n" "$e_sid"
    local kind ts tool _rest e_tool
    while read -r kind ts tool _rest; do
      case "$kind" in P|S|T|D|DF|SF) ;; *) continue ;; esac
      case "$ts" in ''|*[!0-9]*) continue ;; esac
      if [ -n "$tool" ]; then
        e_tool="$(st_sql_escape "$tool")"
        printf "INSERT INTO events(session_id,ts,kind,tool) VALUES('%s',%s,'%s','%s');\n" "$e_sid" "$ts" "$kind" "$e_tool"
      else
        printf "INSERT INTO events(session_id,ts,kind,tool) VALUES('%s',%s,'%s',NULL);\n" "$e_sid" "$ts" "$kind"
      fi
    done < "$log"
    printf 'COMMIT;\n'
  } | sqlite3 "$(st_db_path)" 2>/dev/null
}
```

- [ ] **Step 4: Run test, expect PASS**

Run: `bash tests/db.test.sh`
Expected: all event-import assertions pass (5 imported, DF stored, tool captured, re-import no dup, malformed skipped).

- [ ] **Step 5: Commit**

```bash
git add hooks/lib/db.sh tests/db.test.sh
git commit -m "feat(db): st_import_events (idempotent heartbeat archive)"
```

---

## Task 5: `st_import_history` (idempotent JSONL → SQLite migration)

**Files:**
- Create: `hooks/lib/import-history.sh`
- Test: `tests/import.test.sh`

**Interfaces:**
- Consumes: `st_db_init`, `st_upsert_session`, `st_db_path` (sources `db.sh`).
- Produces: `st_import_history → exit 0`. Reads `$HOME/.claude/session-env/history.jsonl`, upserts each line (legacy defaults: `project_root := project_dir`, `branch := NULL`), renames the file `.imported` and records `meta('history_imported_at')` on success.

- [ ] **Step 1: Write `hooks/lib/import-history.sh`**

```bash
#!/usr/bin/env bash
# Idempotent migration of the legacy history.jsonl into SQLite. Sourceable.
# Safe to run repeatedly: upsert by session_id means re-runs never duplicate.

_ST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_ST_LIB_DIR/db.sh"

st_import_history() {
  st_has_sqlite || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local hist; hist="$HOME/.claude/session-env/history.jsonl"
  [ -f "$hist" ] || return 0
  st_db_init || return 1
  local now; now="$(date +%s)"

  # Emit one TSV row per line: sid, project_dir, active, dur, idle, start, end, issue, reason.
  # Legacy rows: project_root := project_dir, branch := NULL, active := active // duration // 0.
  # Flock so parallel SessionStart runs don't both import (upsert makes it harmless anyway).
  {
    flock 9 2>/dev/null || true
    jq -rc '[.session_id, (.project_dir // ""), (.active_seconds // .duration_seconds // 0),
             (.duration_seconds // 0), (.idle_seconds // 0), (.start_ts // 0), (.end_ts // 0),
             (.issue_key // ""), (.reason // "")] | @tsv' "$hist" 2>/dev/null \
    | while IFS=$'\t' read -r sid dir active dur idle start end issue reason; do
        [ -z "$sid" ] && continue
        # branch NULL for legacy → pass empty string; root := dir
        st_upsert_session "$sid" "$dir" "$dir" "" "$issue" "$start" "$end" "$dur" "$active" "$idle" "$reason" "$now"
      done
    sqlite3 "$(st_db_path)" "INSERT INTO meta(key,value) VALUES('history_imported_at','$now')
      ON CONFLICT(key) DO UPDATE SET value='$now';" 2>/dev/null
    mv -f "$hist" "$hist.imported" 2>/dev/null || true
  } 9>>"$hist.lock"
}
```

- [ ] **Step 2: Write the failing test `tests/import.test.sh`**

```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
. "$DIR/../hooks/lib/import-history.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
SE="$TMP/.claude/session-env"; mkdir -p "$SE"
one() { sqlite3 "$(st_db_path)" "$1"; }

# history with a DUPLICATED session_id (3 cumulative snapshots) + one distinct session
cat > "$SE/history.jsonl" <<'JSON'
{"session_id":"dup","project_dir":"/p/bel","active_seconds":100,"duration_seconds":100,"idle_seconds":0,"start_ts":1000,"end_ts":1100,"issue_key":"","reason":"other"}
{"session_id":"dup","project_dir":"/p/bel","active_seconds":300,"duration_seconds":300,"idle_seconds":0,"start_ts":1000,"end_ts":1300,"issue_key":"","reason":"other"}
{"session_id":"dup","project_dir":"/p/bel","active_seconds":600,"duration_seconds":600,"idle_seconds":0,"start_ts":1000,"end_ts":1600,"issue_key":"BEL-1","reason":"other"}
{"session_id":"solo","project_dir":"/p/onspot","active_seconds":50,"duration_seconds":50,"idle_seconds":0,"start_ts":2000,"end_ts":2050,"issue_key":"","reason":"other"}
JSON

st_import_history

# dedup: dup collapses to 1 row keeping the last (largest) snapshot
assert_eq "dup collapsed to one row" "1" "$(one "SELECT COUNT(*) FROM sessions WHERE session_id='dup';")"
assert_eq "dup keeps last active" "600" "$(one "SELECT active_seconds FROM sessions WHERE session_id='dup';")"
assert_eq "two sessions total" "2" "$(one "SELECT COUNT(*) FROM sessions;")"
# correct deduped total = 600 + 50
assert_eq "deduped total active" "650" "$(one "SELECT SUM(active_seconds) FROM sessions;")"

# legacy defaults: project_root == project_dir, branch NULL
assert_eq "legacy root is dir" "/p/bel" "$(one "SELECT p.project_root FROM sessions s JOIN projects p ON p.id=s.project_id WHERE s.session_id='dup';")"
assert_eq "legacy branch null" "" "$(one "SELECT COALESCE(branch,'') FROM sessions WHERE session_id='dup';")"

# file renamed, so re-run is a no-op
assert_eq "history renamed" "no" "$([ -f "$SE/history.jsonl" ] && echo yes || echo no)"
st_import_history; rc=$?
assert_eq "second run clean" "0" "$rc"
assert_eq "still two sessions" "2" "$(one "SELECT COUNT(*) FROM sessions;")"

finish
```

- [ ] **Step 3: Run test, expect FAIL then implement**

Run: `bash tests/import.test.sh`
Expected: FAIL first if the file is stubbed; after Step 1's implementation is in place, expect PASS. (Write the implementation in Step 1, the test in Step 2, then run.)

- [ ] **Step 4: Run test, expect PASS**

Run: `bash tests/import.test.sh`
Expected: all assertions pass — dup collapsed to one row, last active 600, deduped total 650, legacy root/branch defaults, file renamed, idempotent re-run.

- [ ] **Step 5: Commit**

```bash
git add hooks/lib/import-history.sh tests/import.test.sh
git commit -m "feat(db): idempotent history.jsonl → SQLite migration"
```

---

## Task 6: Wire SessionStart (ensure DB + migrate)

**Files:**
- Modify: `hooks/session-start.sh`
- Test: `tests/session-start.test.sh` (append cases)

**Interfaces:**
- Consumes: `st_db_init`, `st_import_history`.

- [ ] **Step 1: Write failing tests (append to `tests/session-start.test.sh`, before `finish`)**

```bash
# --- SQLite store bootstrap ---
SE2="$TMP/.claude/session-env"; mkdir -p "$SE2"
cat > "$SE2/history.jsonl" <<'JSON'
{"session_id":"m1","project_dir":"/p/x","active_seconds":42,"duration_seconds":42,"idle_seconds":0,"start_ts":10,"end_ts":52,"reason":"other"}
JSON
echo '{"session_id":"boot-1","source":"startup"}' | bash "$ROOT/hooks/session-start.sh" >/dev/null
db="$SE2/history.db"
assert_eq "db created on start" "yes" "$([ -f "$db" ] && echo yes || echo no)"
assert_eq "history migrated on start" "42" "$(sqlite3 "$db" "SELECT active_seconds FROM sessions WHERE session_id='m1';")"
assert_eq "history file renamed" "no" "$([ -f "$SE2/history.jsonl" ] && echo yes || echo no)"
```

Note: `tests/session-start.test.sh` already defines `TMP`, `ROOT`, and `export HOME="$TMP"`; reuse them (these lines go after the existing assertions, before `finish`). If the file lacks `ROOT`, add `ROOT="$DIR/.."` near the top.

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash tests/session-start.test.sh`
Expected: FAIL — `db created on start` (no DB yet).

- [ ] **Step 3: Modify `hooks/session-start.sh`**

Add, immediately after the `mkdir -p "$SESSION_DIR"` line and before the timestamp block:

```bash
# Ensure the SQLite store exists and migrate any legacy history.jsonl.
# Soft dependency: all of this is skipped silently when sqlite3 is unavailable.
DB_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/import-history.sh"
if [ -f "$DB_LIB" ]; then
  # shellcheck source=/dev/null
  . "$DB_LIB"
  st_db_init 2>/dev/null || true
  st_import_history 2>/dev/null || true
fi
```

Note: `session-start.sh` uses `set -euo pipefail`; the `|| true` guards keep a failed init/import from aborting the hook.

- [ ] **Step 4: Run test, expect PASS**

Run: `bash tests/session-start.test.sh`
Expected: all pass — db created, `m1` migrated with active 42, history renamed. Existing assertions still pass.

- [ ] **Step 5: Commit**

```bash
git add hooks/session-start.sh tests/session-start.test.sh
git commit -m "feat(hooks): SessionStart ensures DB and migrates history.jsonl"
```

---

## Task 7: Wire SessionEnd (upsert + events archive + JSONL fallback)

**Files:**
- Modify: `hooks/session-end.sh`
- Test: `tests/session-end.test.sh` (append cases)

**Interfaces:**
- Consumes: `st_project_root`, `st_upsert_session`, `st_import_events`, `st_has_sqlite`, `st_db_init`.

- [ ] **Step 1: Write failing tests (append to `tests/session-end.test.sh`, before `finish`)**

```bash
# --- SQLite write path ---
SIDB="sql-end-1"; SD="$TMP/.claude/session-env/$SIDB"; mkdir -p "$SD"
echo "1000" > "$SD/session-tracker"
printf 'P 1000\nT 1005 Read\nD 1040 Read\nS 1060\n' > "$SD/events.log"
echo '{"session_id":"'"$SIDB"'","reason":"other","cwd":"'"$TMP"'"}' | bash "$ROOT/hooks/session-end.sh" >/dev/null
DB="$TMP/.claude/session-env/history.db"
assert_eq "session row written" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE session_id='$SIDB';")"
assert_eq "events archived" "4" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE session_id='$SIDB';")"

# repeated SessionEnd (resume): still one row
echo '{"session_id":"'"$SIDB"'","reason":"resume","cwd":"'"$TMP"'"}' | bash "$ROOT/hooks/session-end.sh" >/dev/null
assert_eq "resume keeps one row" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE session_id='$SIDB';")"

# fallback: with sqlite3 masked off PATH, SessionEnd appends legacy JSONL
SIDF="fallback-1"; SDF="$TMP/.claude/session-env/$SIDF"; mkdir -p "$SDF"
echo "3000" > "$SDF/session-tracker"
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
for b in jq date git awk cat basename dirname mkdir sed printf head tr; do ln -sf "$(command -v $b)" "$FAKEBIN/$b" 2>/dev/null; done
PATH="$FAKEBIN" bash "$ROOT/hooks/session-end.sh" <<< '{"session_id":"'"$SIDF"'","reason":"other","cwd":"'"$TMP"'"}' >/dev/null
assert_eq "fallback wrote jsonl" "yes" "$([ -f "$TMP/.claude/session-env/history.jsonl" ] && grep -q "$SIDF" "$TMP/.claude/session-env/history.jsonl" && echo yes || echo no)"
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash tests/session-end.test.sh`
Expected: FAIL — `session row written` (session-end still only appends JSONL).

- [ ] **Step 3: Modify `hooks/session-end.sh`**

Replace the final write block (the `mkdir -p "$(dirname "$HISTORY_FILE")"` … `flock`/`printf` section that appends `$LINE`) with a SQLite-first path that falls back to the JSONL append. Keep all the earlier computation (`START_TS`, `DURATION`, `ACTIVE_SECONDS`, `IDLE_SECONDS`, `ISSUE_KEY`, `CWD`) unchanged. Insert before building `$LINE`:

```bash
# Canonical project root (worktree-immune) + branch, via the shared lib.
DB_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/db.sh"
PROJECT_ROOT="$CWD"; BRANCH=""
if [ -f "$DB_LIB" ]; then
  # shellcheck source=/dev/null
  . "$DB_LIB"
  PROJECT_ROOT="$(st_project_root "$CWD")"
  BRANCH="$(git -C "$CWD" branch --show-current 2>/dev/null || true)"
fi

NOW="$(date +%s)"
if [ -f "$DB_LIB" ] && st_has_sqlite; then
  st_db_init 2>/dev/null || true
  if st_upsert_session "$SESSION_ID" "$PROJECT_ROOT" "$CWD" "$BRANCH" "$ISSUE_KEY" \
       "$START_TS" "$END_TS" "$DURATION" "$ACTIVE_SECONDS" "$IDLE_SECONDS" "$REASON" "$NOW"; then
    st_import_events "$SESSION_ID" "$EVENTS_FILE" 2>/dev/null || true
    exit 0
  fi
fi
# Fallback: sqlite3 unavailable or upsert failed → legacy JSONL append (imported next start).
```

Leave the existing `$LINE` construction and `flock`/`printf >> "$HISTORY_FILE"` block **after** this, unchanged, as the fallback path. (`EVENTS_FILE` is already defined earlier in the hook.)

- [ ] **Step 4: Run test, expect PASS**

Run: `bash tests/session-end.test.sh`
Expected: all pass — session row written, 4 events archived, resume keeps one row, fallback wrote JSONL. Existing assertions still pass.

- [ ] **Step 5: Commit**

```bash
git add hooks/session-end.sh tests/session-end.test.sh
git commit -m "feat(hooks): SessionEnd upserts to SQLite with JSONL fallback"
```

---

## Task 8: session-status skill reads daily total from SQLite

**Files:**
- Modify: `skills/session-status/SKILL.md`
- Test: `tests/read-queries.test.sh` (create)

**Interfaces:**
- Consumes: the `sessions` table produced by Tasks 3/7.

- [ ] **Step 1: Write the failing test `tests/read-queries.test.sh`**

```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
. "$DIR/../hooks/lib/db.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
st_db_init
one() { sqlite3 "$(st_db_path)" "$1"; }

# two sessions today on the same repo root (main + worktree), one yesterday
TODAY_TS=$(date +%s)
st_upsert_session "a" "/p/bel" "/p/bel"                 "main"    "BEL-1" "$TODAY_TS" "$TODAY_TS" 100 100 0 "other" "$TODAY_TS"
st_upsert_session "b" "/p/bel" "/p/bel/.claude/wt/feat" "feature" ""      "$TODAY_TS" "$TODAY_TS" 200 200 0 "other" "$TODAY_TS"
st_upsert_session "c" "/p/bel" "/p/bel"                 "main"    ""      "1000"      "1100"      50  50  0 "other" "1101"

# DAILY TOTAL query (the one session-status uses): sum active for sessions starting today
today=$(date +%Y-%m-%d)
total=$(one "SELECT COALESCE(SUM(active_seconds),0) FROM sessions WHERE date(start_ts,'unixepoch','localtime')='$today';")
assert_eq "daily total sums today only" "300" "$total"

finish
```

- [ ] **Step 2: Run test, expect FAIL then PASS**

Run: `bash tests/read-queries.test.sh`
Expected: PASS (this validates the query the skill will embed; the query uses only Task-3 data). If it fails, fix the query, not the skill prose.

- [ ] **Step 3: Modify `skills/session-status/SKILL.md`**

In the "today's accumulated total" section, replace the jq-over-`history.jsonl` snippet with a SQLite-first read that keeps the jq path as fallback:

````markdown
Compute today's finished-session total from the SQLite store (one row per
session — no double-counting). Falls back to the legacy JSONL when `sqlite3`
or the DB is absent:

```bash
DB="$HOME/.claude/session-env/history.db"
today=$(date +%Y-%m-%d)
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB" ]; then
  today_past=$(sqlite3 "$DB" "SELECT COALESCE(SUM(active_seconds),0) FROM sessions WHERE date(start_ts,'unixepoch','localtime')='$today';")
else
  HIST="$HOME/.claude/session-env/history.jsonl"
  today_past=$([ -f "$HIST" ] && jq -s --arg t "$today" 'map(select((.start_ts|strflocaltime("%Y-%m-%d"))==$t)) | group_by(.session_id) | map(max_by(.end_ts).active_seconds) | add // 0' "$HIST" || echo 0)
fi
total_today=$((today_past + active))
```
````

Note the fallback jq now also dedups (`group_by(.session_id)|max_by(.end_ts)`) so even the legacy path reports the corrected total.

- [ ] **Step 4: Run test, expect PASS**

Run: `bash tests/read-queries.test.sh`
Expected: `daily total sums today only` = 300.

- [ ] **Step 5: Commit**

```bash
git add skills/session-status/SKILL.md tests/read-queries.test.sh
git commit -m "feat(skill): session-status daily total from SQLite (deduped)"
```

---

## Task 9: session-history skill — table, project filter, Branch/Issue, timeline

**Files:**
- Modify: `skills/session-history/SKILL.md`
- Test: `tests/read-queries.test.sh` (append cases)

**Interfaces:**
- Consumes: `sessions`, `projects`, `events` tables.

- [ ] **Step 1: Write failing tests (append to `tests/read-queries.test.sh`, before `finish`)**

```bash
# --- session-history table row (project grouped, Branch/Issue coalesced) ---
# session 'a' has issue BEL-1, 'b' has only a branch → coalesce falls back to branch
rowA=$(one "SELECT p.name || '|' || COALESCE(NULLIF(s.issue_key,''),NULLIF(s.branch,''),'—')
           FROM sessions s LEFT JOIN projects p ON p.id=s.project_id WHERE s.session_id='a';")
assert_eq "row A project+issue" "bel|BEL-1" "$rowA"
rowB=$(one "SELECT p.name || '|' || COALESCE(NULLIF(s.issue_key,''),NULLIF(s.branch,''),'—')
           FROM sessions s LEFT JOIN projects p ON p.id=s.project_id WHERE s.session_id='b';")
assert_eq "row B project+branch" "bel|feature" "$rowB"

# project filter matches BOTH the main checkout and the worktree via project_root
cnt=$(one "SELECT COUNT(*) FROM sessions s JOIN projects p ON p.id=s.project_id
           WHERE p.project_root LIKE '%bel%' OR s.project_dir LIKE '%bel%';")
assert_eq "filter groups worktrees" "3" "$cnt"

# forensic timeline pulls ordered events for one session
st_import_events "a" /dev/stdin <<'EVLOG'
P 500
T 505 Read
D 517 Read
S 560
EVLOG
tl=$(one "SELECT group_concat(kind||'@'||ts, ',') FROM (SELECT kind,ts FROM events WHERE session_id='a' ORDER BY ts);")
assert_eq "timeline ordered" "P@500,T@505,D@517,S@560" "$tl"
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash tests/read-queries.test.sh`
Expected: FAIL on `row A project+issue` until the queries are validated (they exercise only Task 3/4 data, so they should pass once written correctly — if they fail, fix the SQL).

- [ ] **Step 3: Modify `skills/session-history/SKILL.md`**

(a) Replace the "quanto trabalhei hoje" jq render with a SQLite-first query producing the new **Branch/Issue** column, keeping a jq fallback:

````markdown
```bash
DB="$HOME/.claude/session-env/history.db"
today=$(date +%Y-%m-%d)
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB" ]; then
  sqlite3 -separator $'\t' "$DB" "
    SELECT strftime('%H:%M', s.start_ts, 'unixepoch','localtime'),
           strftime('%H:%M', s.end_ts,   'unixepoch','localtime'),
           s.active_seconds,
           p.name,
           COALESCE(NULLIF(s.issue_key,''), NULLIF(s.branch,''), '—')
    FROM sessions s LEFT JOIN projects p ON p.id = s.project_id
    WHERE date(s.start_ts,'unixepoch','localtime') = '$today'
    ORDER BY s.start_ts;"
else
  # legacy fallback (deduped): one row per session_id
  HIST="$HOME/.claude/session-env/history.jsonl"
  jq -rs --arg today "$today" '
    map(select((.start_ts|strflocaltime("%Y-%m-%d"))==$today))
    | group_by(.session_id) | map(max_by(.end_ts))
    | .[] | [ (.start_ts|strflocaltime("%H:%M")), (.end_ts|strflocaltime("%H:%M")),
              .active_seconds, (.project_dir|split("/")|last), (.issue_key // "—") ] | @tsv' "$HIST"
fi
```
````

Update the **Filters → Project** line to: "substring match on `projects.project_root` OR `sessions.project_dir` (case-insensitive) — worktrees of the same repo group under the canonical root."

Update the **Output Format** table to add the `Branch/Issue` column:

```
| Data | Início | Fim | Trabalho | Projeto | Branch/Issue |
```

(b) Replace the forensic-timeline **source** — feed the existing timeline `awk` from the `events` table instead of `cat events.log`, falling back to the live log:

````markdown
```bash
SID="$1"
DB="$HOME/.claude/session-env/history.db"
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB" ] \
   && [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE session_id='$SID';")" -gt 0 ]; then
  EVENTS_SRC() { sqlite3 -separator ' ' "$DB" "SELECT kind, ts, COALESCE(tool,'') FROM events WHERE session_id='$SID' ORDER BY ts;"; }
else
  EV="$HOME/.claude/session-env/$SID/events.log"
  [ -f "$EV" ] || { echo "Sem timeline para a sessão $SID."; exit 0; }
  EVENTS_SRC() { cat "$EV"; }
fi
EVENTS_SRC | awk '
  # ... UNCHANGED timeline awk from this file (P/T/D/DF/S/SF, ✗ + erro de API) ...
' | while read -r _tag pts sts err summary; do
  # ... UNCHANGED shell formatting loop ...
done
```
````

The timeline `awk` block and the formatting `while` loop are the ones already in this file (Tasks from v2.6.0) — reuse them verbatim; only the event **source** changes.

- [ ] **Step 4: Run test, expect PASS**

Run: `bash tests/read-queries.test.sh`
Expected: all pass — row A `bel|BEL-1`, row B `bel|feature`, filter groups worktrees = 3, timeline ordered.

- [ ] **Step 5: Commit**

```bash
git add skills/session-history/SKILL.md tests/read-queries.test.sh
git commit -m "feat(skill): session-history reads SQLite (grouped, Branch/Issue, timeline)"
```

---

## Task 10: Register tests + README + CHANGELOG

**Files:**
- Modify: `tests/run.sh`
- Modify: `README.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Register the new test files in `tests/run.sh`**

Ensure `run.sh` runs every `*.test.sh` (it likely globs already). If it lists files explicitly, add `db.test.sh`, `import.test.sh`, `read-queries.test.sh`. Confirm by reading `tests/run.sh` first.

- [ ] **Step 2: Run the full suite**

Run: `bash tests/run.sh`
Expected: every suite reports `0 failed`, including the three new ones.

- [ ] **Step 3: Update `README.md`**

Under requirements, add next to `jq`:

```markdown
- **`sqlite3`** (soft dependency) — the session history is stored in a local
  SQLite database at `~/.claude/session-env/history.db`. If `sqlite3` is not
  installed the plugin still works, falling back to a JSON-lines log; install
  `sqlite3` to get the relational store, correct cross-session totals, and
  per-project (worktree-aware) grouping. Present by default on macOS.
```

Add a short "Migration" note: on first session after upgrading to v3.0.0 the
existing `history.jsonl` is imported into SQLite automatically and renamed
`history.jsonl.imported`; no action needed.

- [ ] **Step 4: Update `CHANGELOG.md` `[Unreleased]`**

```markdown
## [Unreleased]

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
```

- [ ] **Step 5: Commit**

```bash
git add tests/run.sh README.md CHANGELOG.md
git commit -m "docs+test: register SQLite suites, document sqlite3 dep + migration"
```

---

## Self-Review notes (already reconciled)

- **Spec coverage:** §4 schema → T1; §5.3 project_root/branch/upsert → T2/T3/T7; §4 events archive → T4; §6 migration → T5; §5.1 SessionStart wiring → T6; §7 reads → T8/T9; §8 dependency/README → T10; §9 tests → T1–T9. All covered.
- **Placeholder scan:** timeline `awk`/formatting loop in T9 are "reuse verbatim" of an *existing, present* block in the same file (allowed — not a forward reference), and their content is the v2.6.0 code already in `session-history/SKILL.md`.
- **Type consistency:** `st_*` function names and argument order match across T3/T5/T6/T7. `st_upsert_session` arg order (sid root dir branch issue start end dur active idle reason now) is identical everywhere it is called.
