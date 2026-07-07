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
  sqlite3 "$db" < "$schema" >/dev/null 2>&1
}

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
