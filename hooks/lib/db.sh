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
