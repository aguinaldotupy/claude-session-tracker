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

# missing log is a clean no-op: returns 0, inserts nothing new
before=$(one "SELECT COUNT(*) FROM events WHERE session_id='sE';")
st_import_events "sE" "$TMP/does-not-exist.log"; rc=$?
after=$(one "SELECT COUNT(*) FROM events WHERE session_id='sE';")
assert_eq "missing log returns 0" "0" "$rc"
assert_eq "missing log inserts nothing" "$before" "$after"

# a no-tool kind (S) is stored with tool IS NULL, not empty string
st_upsert_session "sNull" "$repo" "$repo" "" "" 4000 4100 100 80 20 "other" 4101
printf 'P 4000\nS 4100\n' > "$TMP/null.log"
st_import_events "sNull" "$TMP/null.log"
assert_eq "no-tool kind stores NULL" "2" "$(one "SELECT COUNT(*) FROM events WHERE session_id='sNull' AND tool IS NULL;")"

# --- st_backfill_worktrees (v3.0.2): fix DBs migrated before worktree collapsing ---
# simulate the OLD fragmented state: project_root == project_dir == worktree path
st_upsert_session "bf-main" "/r/app"                              "/r/app"                              "" "" 5000 5010 10 10 0 "other" 5011
st_upsert_session "bf-w1"   "/r/app/.claude/worktrees/happy-x"    "/r/app/.claude/worktrees/happy-x"    "" "" 5000 5020 20 20 0 "other" 5021
st_upsert_session "bf-w2"   "/r/app/.claude/worktrees/silly-y"    "/r/app/.claude/worktrees/silly-y"    "" "" 5000 5030 30 30 0 "other" 5031
assert_eq "before backfill: 3 fragmented projects" "3" "$(one "SELECT COUNT(*) FROM projects WHERE project_root LIKE '/r/app%';")"

st_backfill_worktrees
assert_eq "backfill: one /r/app project" "1" "$(one "SELECT COUNT(*) FROM projects WHERE project_root='/r/app';")"
assert_eq "backfill: all 3 sessions regrouped" "3" "$(one "SELECT COUNT(*) FROM sessions s JOIN projects p ON p.id=s.project_id WHERE p.project_root='/r/app';")"
assert_eq "backfill: orphan worktree projects removed" "0" "$(one "SELECT COUNT(*) FROM projects WHERE project_root LIKE '/r/app/.claude/worktrees/%';")"
assert_eq "backfill: worktree session keeps full project_dir" "/r/app/.claude/worktrees/happy-x" "$(one "SELECT project_dir FROM sessions WHERE session_id='bf-w1';")"

# idempotent: a second run (meta flag set) is a no-op and does not error
st_backfill_worktrees; rc=$?
assert_eq "backfill idempotent (rc 0)" "0" "$rc"
assert_eq "backfill still one /r/app project" "1" "$(one "SELECT COUNT(*) FROM projects WHERE project_root='/r/app';")"

finish
