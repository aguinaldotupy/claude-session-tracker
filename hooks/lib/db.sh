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
  local start="$(( 10#${6:-0} ))" end="$(( 10#${7:-0} ))" dur="$(( 10#${8:-0} ))"
  local active="$(( 10#${9:-0} ))" idle="$(( 10#${10:-0} ))" reason="${11}" now="$(( 10#${12:-0} ))"
  local name; name="$(basename "$root")"
  local e_sid e_root e_dir e_name e_reason
  e_sid="$(st_sql_escape "$sid")";     e_root="$(st_sql_escape "$root")"
  e_dir="$(st_sql_escape "$dir")";     e_name="$(st_sql_escape "$name")"
  e_reason="$(st_sql_escape "$reason")"
  # branch / issue_key: emit SQL NULL when empty, else an escaped quoted literal
  local branch_sql issue_sql
  if [ -n "$branch" ]; then branch_sql="'$(st_sql_escape "$branch")'"; else branch_sql="NULL"; fi
  if [ -n "$issue" ];  then issue_sql="'$(st_sql_escape "$issue")'";  else issue_sql="NULL";  fi
  sqlite3 "$(st_db_path)" <<SQL 2>/dev/null
BEGIN;
INSERT INTO projects(project_root,name,first_seen_ts,last_seen_ts)
  VALUES('$e_root','$e_name',$now,$now)
  ON CONFLICT(project_root) DO UPDATE SET last_seen_ts=$now;
INSERT INTO sessions(session_id,project_id,project_dir,branch,issue_key,
                     start_ts,end_ts,duration_seconds,active_seconds,idle_seconds,reason,updated_at)
  VALUES('$e_sid',(SELECT id FROM projects WHERE project_root='$e_root'),'$e_dir',$branch_sql,$issue_sql,
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

# st_backfill_worktrees — one-time cleanup for DBs migrated before worktree
# collapsing existed: regroup already-imported sessions whose project_dir is a
# default-layout Claude Code worktree (<repo>/.claude/worktrees/<name>) under the
# canonical repo root, then drop the orphaned per-worktree project rows. Idempotent
# and guarded by a meta flag so it runs at most once. Only the exact, Claude-Code-
# owned `/.claude/worktrees/` marker triggers it — custom worktree paths are left
# untouched, matching the migration's own heuristic.
st_backfill_worktrees() {
  st_has_sqlite || return 1
  local db; db="$(st_db_path)"
  [ -f "$db" ] || return 0
  [ -n "$(sqlite3 "$db" "SELECT value FROM meta WHERE key='worktrees_backfilled';" 2>/dev/null)" ] && return 0
  local now; now="$(date +%s)"
  # Distinct collapsed repo roots among worktree sessions (basename computed in
  # bash — SQLite has no basename()).
  local roots; roots="$(sqlite3 "$db" "SELECT DISTINCT substr(project_dir,1,instr(project_dir,'/.claude/worktrees/')-1) FROM sessions WHERE project_dir LIKE '%/.claude/worktrees/%';" 2>/dev/null)"
  {
    printf 'BEGIN;\n'
    local root name e_root e_name
    while IFS= read -r root; do
      [ -z "$root" ] && continue
      name="${root##*/}"
      e_root="$(st_sql_escape "$root")"; e_name="$(st_sql_escape "$name")"
      printf "INSERT INTO projects(project_root,name,first_seen_ts,last_seen_ts) VALUES('%s','%s',%s,%s) ON CONFLICT(project_root) DO UPDATE SET last_seen_ts=%s;\n" "$e_root" "$e_name" "$now" "$now" "$now"
    done <<EOF
$roots
EOF
    # Re-link every default-layout worktree session to its collapsed repo root.
    printf "UPDATE sessions SET project_id=(SELECT id FROM projects WHERE project_root=substr(project_dir,1,instr(project_dir,'/.claude/worktrees/')-1)) WHERE project_dir LIKE '%%/.claude/worktrees/%%';\n"
    # Drop project rows left with no sessions (the old per-worktree hash names).
    printf "DELETE FROM projects WHERE id NOT IN (SELECT project_id FROM sessions WHERE project_id IS NOT NULL);\n"
    printf "INSERT INTO meta(key,value) VALUES('worktrees_backfilled','%s') ON CONFLICT(key) DO UPDATE SET value='%s';\n" "$now" "$now"
    printf 'COMMIT;\n'
  } | sqlite3 "$db" 2>/dev/null
}
