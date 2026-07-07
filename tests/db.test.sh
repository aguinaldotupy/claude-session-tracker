#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
. "$DIR/../hooks/lib/db.sh"

TMP=$(mktemp -d); TMP="$(cd "$TMP" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
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

finish
