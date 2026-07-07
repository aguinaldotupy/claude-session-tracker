# SQLite Session Store — Design

**Date:** 2026-07-07
**Status:** Approved (brainstorming) — pending implementation plan
**Target release:** v3.0.0 (breaking storage change, automatic migration)

## 1. Problem

The plugin's aggregate store, `~/.claude/session-env/history.jsonl`, is an
append-only log: every `SessionEnd` **appends** a new line. Empirical analysis of
the author's real data (3217 lines, 13-Apr → 07-Jul 2026) revealed two defects.

### 1.1 The headline bug: totals inflated ~78%

`SessionEnd` fires **once per instance close, not once per session** — and
`session_id` is stable across `--resume`/`--continue` (confirmed in docs and
data). A resumed session therefore ends many times, and because `start_ts` is
never updated (only written at `startup`/`clear`), each `SessionEnd` appends a
row with the **cumulative** `active_seconds` since the first start.

Measured impact:

| | Hours of "work" |
|---|---|
| Plugin counts today (sum of all rows) | **4259 h** |
| Correct (one row per session) | **2391 h** |
| Inflation | **+78 %** |

- 2986 unique `session_id`s across 3217 rows → 231 redundant rows (7 %).
- Worst offender: one `session_id` with **21 cumulative rows** over 5.4 days
  (`active` grows 429 → 509 → … → 69619; all 21 are summed today).
- `reason` distribution on the duplicates: `other` 203, `prompt_input_exit` 123,
  `resume` 2.

Root cause: **append-per-close + stable `session_id` + fixed `start_ts` =
cumulative duplicate rows.** The append-only model has no *update* semantics.

### 1.2 Worktree fragmentation

`SessionEnd` records `project_dir = cwd` raw. Claude Code runs worktrees at a
**dynamic, configurable path** (default `<repo>/.claude/worktrees/<name>`, but
not guaranteed). In the data, project `bel` is one logical project spread across
**35 distinct `project_dir` values** (203 sessions, 425.8 h): 113 render as
`bel`, 90 render as cryptic worktree hash-names (`funny-euler-a63540`, …). The
`session-history` "Projeto" column and any per-project grouping fragment.

The substring project filter *happens* to still match nested worktrees (path
contains the repo name) — but only by coincidence of the default path. A
configured external worktree path breaks it.

## 2. Goals / Non-goals

**Goals**
- Eliminate the 78 % double-count structurally (not by read-side patching).
- Group all worktrees of a repo under one canonical project identity, immune to
  the worktree path config.
- Keep per-worktree detail visible (branch / issue) in history.
- Safe concurrent writes for parallel worktree sessions.
- Automatic, idempotent migration of existing `history.jsonl`. No data loss.
- Never block a hook; degrade gracefully if `sqlite3` is absent.

**Non-goals (YAGNI at this scale)**
- A precomputed `summaries` cache (wakapi has one; unnecessary at ~3 k sessions,
  25 ms queries).
- File/language/editor/OS dimensions (WakaTime-style). We don't collect them.
- AI token/usage tracking. Schema leaves room; out of scope now.
- Retroactively re-grouping *legacy* worktree rows (their worktrees may be gone;
  path-strip heuristics are fragile — see §6.3).

## 3. Prior art

WakaTime / **wakapi** (self-hosted, SQLite/Postgres) use a 3-layer model:
`heartbeats` (raw atomic events, deduped by hash) → `summaries`/`summary_items`
(precomputed aggregates) → dimension tables. Durations are **derived** by joining
heartbeats within a timeout.

session-tracker already owns the heartbeat layer: `events.log` (`P/S/T/D/DF/SF`)
is the heartbeat stream and `active-time.awk` is the duration derivation (bracket
+ reading grace). What is missing is the **relational session and project
layer**. We adopt wakapi's "raw events + derive" split and its dedup-on-write
principle, but drop the summaries cache and the dimension explosion.

## 4. Architecture

Three core tables — `projects`, `sessions`, `events` — in one SQLite database at
`~/.claude/session-env/history.db`, plus a tiny key/value `meta` table for schema
version and import bookkeeping, and an unchanged text hot-path.

```
projects  1 ── ∞  sessions  1 ── ∞  events        (meta: schema version, import state)
```

- **Hot-path stays text.** Heartbeat hooks (`PreToolUse`, `PostToolUse`,
  `UserPromptSubmit`, `Stop`, `PostToolUseFailure`, `StopFailure`) keep appending
  to the per-session `events.log`. Fast, lock-free, no cross-session contention.
  `sqlite3` never runs in the per-tool-call path.
- **SQLite writes happen once, at `SessionEnd`** (low frequency): one transaction
  upserts the project, upserts the session, and bulk-imports that session's
  events.
- `events.log` is the **live buffer** (statusline + live active-time read it in
  real time); the `events` table is the **durable archive** (today `events.log`
  is deleted after `cleanupPeriodDays`).

### 4.1 Schema (DDL)

```sql
PRAGMA journal_mode = WAL;     -- concurrent readers + one writer: safe for parallel worktrees
PRAGMA busy_timeout = 2000;    -- wait out a concurrent writer instead of erroring

CREATE TABLE IF NOT EXISTS projects (
  id            INTEGER PRIMARY KEY,
  project_root  TEXT NOT NULL UNIQUE,  -- dirname(git-common-dir); same for every worktree of a repo
  name          TEXT NOT NULL,         -- basename(project_root), for display
  first_seen_ts INTEGER NOT NULL,
  last_seen_ts  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  session_id       TEXT PRIMARY KEY,   -- stable across resume → upsert updates in place
  project_id       INTEGER REFERENCES projects(id),
  project_dir      TEXT,               -- real cwd (worktree path) — detail
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
  kind       TEXT NOT NULL,            -- P | S | T | D | DF | SF
  tool       TEXT                      -- for T | D | DF
);
CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id, ts);

CREATE TABLE IF NOT EXISTS meta (      -- schema version + import bookkeeping
  key   TEXT PRIMARY KEY,
  value TEXT
);
```

### 4.2 How each defect dies

| Defect | Structural fix |
|---|---|
| 78 % inflation | `session_id` PRIMARY KEY + `ON CONFLICT DO UPDATE`. Repeated `SessionEnd` updates one row. Duplicates impossible. |
| Worktree fragmentation | `projects.project_root` (git-common-dir) unique per repo; worktrees share one `project_id`. `GROUP BY project_id`. |
| Distinguishing worktrees | `sessions.branch` + `issue_key` preserved; history shows a Branch/Issue column. |
| Parallel concurrency | WAL + `busy_timeout`; `SessionEnd` writes serialize safely, reads never block. |
| Forensic timeline after cleanup | `events` is durable; today `events.log` vanishes after 30 days. |

## 5. Write flow

### 5.1 SessionStart (`session-start.sh`)
Unchanged core (writes `start_ts`, deploys `active-time.awk`). **New:**
1. Ensure the DB exists and schema is applied (`CREATE TABLE IF NOT EXISTS …`,
   idempotent, ~instant).
2. Run the idempotent importer (§6) if `history.jsonl` is present. This covers
   both the one-time migration and reconciliation of any fallback lines (§7).
   Guard with `flock`; skip instantly when `history.jsonl` is absent (steady
   state).

If `sqlite3` is unavailable, skip all DB work silently (never block).

### 5.2 Heartbeat hooks
**Unchanged.** Continue appending `P/S/T/D/DF/SF` to the per-session
`events.log`.

### 5.3 SessionEnd (`session-end.sh`)
Compute `duration`, `active_seconds`, `idle_seconds`, `issue_key` exactly as
today. **Additionally** compute:

```sh
# canonical project root — immune to worktree path config
COMMON=$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || COMMON=$(git -C "$CWD" rev-parse --git-common-dir 2>/dev/null)   # older git: may be relative
case "$COMMON" in
  "")  PROJECT_ROOT="$CWD" ;;                                   # non-git → cwd
  /*)  PROJECT_ROOT=$(cd "$(dirname "$COMMON")" && pwd) ;;      # absolute
  *)   PROJECT_ROOT=$(cd "$CWD/$(dirname "$COMMON")" && pwd) ;; # relative to cwd
esac
BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || true)
```

Then, if `sqlite3` is available, in **one transaction**:

```sql
BEGIN;
INSERT INTO projects(project_root, name, first_seen_ts, last_seen_ts)
  VALUES(:root, :name, :now, :now)
  ON CONFLICT(project_root) DO UPDATE SET last_seen_ts = :now;

INSERT INTO sessions(session_id, project_id, project_dir, branch, issue_key,
                     start_ts, end_ts, duration_seconds, active_seconds,
                     idle_seconds, reason, updated_at)
  VALUES(:sid, (SELECT id FROM projects WHERE project_root = :root), :dir, :branch,
         :issue, :start, :end, :dur, :active, :idle, :reason, :now)
  ON CONFLICT(session_id) DO UPDATE SET
    end_ts           = excluded.end_ts,
    duration_seconds = excluded.duration_seconds,
    active_seconds   = excluded.active_seconds,
    idle_seconds     = excluded.idle_seconds,
    reason           = excluded.reason,
    branch           = excluded.branch,
    issue_key        = excluded.issue_key,
    project_id       = excluded.project_id,
    project_dir      = excluded.project_dir,
    updated_at       = excluded.updated_at
  WHERE excluded.end_ts >= sessions.end_ts;   -- max-end_ts wins, order-independent

-- bulk import this session's heartbeats (idempotent: clear then re-insert)
DELETE FROM events WHERE session_id = :sid;
-- one INSERT per events.log line, values parsed by the hook
INSERT INTO events(session_id, ts, kind, tool) VALUES …;
COMMIT;
```

The `WHERE excluded.end_ts >= sessions.end_ts` guard makes the upsert
order-independent: an older cumulative snapshot can never overwrite a newer one.

**Fallback:** if `sqlite3` is unavailable or the transaction fails, append the
legacy JSON line to `history.jsonl` (current behavior). No data lost; the next
SessionStart imports it.

Values are passed to `sqlite3` via parameter binding (`.param set` / here-doc
with quoting) — never string-interpolated — to avoid SQL injection from paths /
branch names / issue keys.

## 6. Migration (importer)

A single idempotent routine, `hooks/lib/import-history.sh`, invoked from
SessionStart. It reads `history.jsonl` and upserts every line into SQLite.

### 6.1 Dedup is automatic
Importing in file order and upserting on `session_id` with the `max-end_ts`
guard means the last (largest-cumulative) row per session wins — reproducing the
correct **2391 h**. Verified against the real file via jq
(`group_by(session_id) | max_by(end_ts)`).

### 6.2 Legacy field defaults
- `project_root := project_dir` (cwd as-is). Legacy worktree rows keep their
  worktree path as their own project — **not** retroactively regrouped.
- `branch := NULL`, so the Branch/Issue column shows `—` for old sessions.
- Rows lacking `active_seconds` (pre-2.5.0) fall back to `duration_seconds`,
  matching current read behavior.

### 6.3 Why no legacy regrouping
Deriving a legacy row's real repo root would require either running git on a
worktree that may no longer exist, or stripping the worktree path — which depends
on the (configurable, possibly changed) worktree path and is fragile. We record
the honest cwd and let only **new** sessions carry the exact git-derived root.

### 6.4 Bookkeeping & cleanup
After a successful full import, record `meta('history_imported_at', <ts>)` and
rename `history.jsonl → history.jsonl.imported` so subsequent starts skip
instantly. A fallback write (§5.3) recreates `history.jsonl`; the next start
imports and renames again. Import is guarded by `flock` so concurrent SessionStart
runs don't double-work (and upsert makes a double-run harmless anyway).

## 7. Reads (skills)

Skills read SQLite as the single source of truth. Any residual `history.jsonl`
(fallback) is folded in at the next SessionStart, so it always surfaces.

- **session-status** — daily total: `SELECT SUM(active_seconds) FROM sessions
  WHERE start_ts` in today's local range. One row per session → correct.
  Live running session still read from `events.log` (unchanged) and added.
- **session-history** — table:
  ```sql
  SELECT s.start_ts, s.end_ts, s.active_seconds, p.name,
         COALESCE(NULLIF(s.issue_key,''), NULLIF(s.branch,''), '—') AS branch_issue
  FROM sessions s LEFT JOIN projects p ON p.id = s.project_id
  WHERE <date filter>
  ORDER BY s.start_ts;
  ```
  Columns: `Data | Início | Fim | Trabalho | Projeto | Branch/Issue`. Project
  filter: `WHERE p.project_root LIKE '%q%' OR s.project_dir LIKE '%q%'`.
- **Forensic timeline** — `SELECT kind, ts, tool FROM events WHERE session_id = ?
  ORDER BY ts`, replacing the events.log read. Falls back to the live
  `events.log` when the session is the current one / not yet imported. The
  `DF`/`SF` failure marks render as before (`✗`, "erro de API").

If `sqlite3` is unavailable, skills fall back to reading `history.jsonl` with the
current jq/awk paths (best-effort, un-deduped — documented limitation).

## 8. Dependency & compatibility

- Adds `sqlite3` (CLI) as a **soft** dependency: required for the new store,
  but every hook degrades to the legacy JSONL path when it is missing, so the
  plugin still functions. Present by default on macOS; `sqlite3` package on most
  Linux. Documented in README next to the existing `jq` requirement.
- `history.jsonl` is never destroyed, only renamed `.imported` — trivial
  rollback.
- **v3.0.0**: major bump (storage format change), but migration is automatic and
  requires no user action.

## 9. Testing

Extend the plain-bash suite under `tests/` (source `lib.sh`, use a temp `$HOME`).

1. **Schema idempotent** — apply schema twice; no error, tables present.
2. **Upsert dedupe** — insert 21 cumulative rows for one `session_id`; assert
   `COUNT(*)=1` and `active_seconds` = last (largest).
3. **Order-independent upsert** — insert a newer then an older snapshot; assert
   the newer survives (max-end_ts guard).
4. **Migration correctness** — synthetic `history.jsonl` with duplicates; assert
   imported `SUM(active_seconds)` equals the jq `group_by|max_by(end_ts)` value.
5. **project_root grouping** — main path + two worktree paths sharing a
   `project_root`; assert one `projects` row and grouped total.
6. **Legacy defaults** — line without `project_root`/`branch` → `project_root =
   project_dir`, `branch` NULL, Branch/Issue renders `—`.
7. **sqlite3 absent** — stub `sqlite3` off `PATH`; SessionEnd appends to
   `history.jsonl`; next import folds it in with no duplication.
8. **Injection safety** — path/branch containing a quote is stored verbatim, no
   SQL error.
9. **Events import** — `events.log` with `P/T/D/DF/SF/S` → `events` rows match;
   re-import (idempotent) does not duplicate.

## 10. Edge cases

- **Non-git cwd** → git-common-dir empty → `project_root = cwd` (= legacy
  fallback). Fine.
- **Relative git-common-dir** (older git without `--path-format`) → resolved
  against `$CWD` (§5.3).
- **events.log missing at SessionEnd** → session row still written (wall-clock
  active fallback); events import skipped.
- **DB locked by a parallel session** → `busy_timeout` waits; on hard failure,
  JSONL fallback.
- **First session ever** → SessionStart creates schema before any read.
- **The `/Users/tupy` home-dir bucket** (2525 rows, no issue_key) is out of
  scope here; it imports as `project_root = /Users/tupy`. A future "(no project)"
  label is noted, not built.

## 11. Rollout

1. Ship schema + write path + importer behind automatic migration (v3.0.0).
2. First SessionStart after upgrade imports and renames `history.jsonl`.
3. Skills switch to SQLite reads with JSONL fallback.
4. README documents the `sqlite3` soft dependency and the automatic migration.
