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

# zero-padded numerics are read as base-10, not octal
st_upsert_session "sPad" "$repo" "$repo" "" "" 0100 0100 0100 0100 0 "other" 0100
assert_eq "zero-padded active is base-10" "100" "$(one "SELECT active_seconds FROM sessions WHERE session_id='sPad';")"

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

finish
