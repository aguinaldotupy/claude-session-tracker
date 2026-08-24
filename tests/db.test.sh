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

# --- SessionEnd stays fast on huge event logs (v3.1.2 timeout fix) ---
# 20k lines through the whole hook must finish well inside the 5s hook budget.
big_sid="perf-big"
mkdir -p "$HOME/.claude/session-env/$big_sid"
echo 1700000000 > "$HOME/.claude/session-env/$big_sid/session-tracker"
awk 'BEGIN{ts=1700000000; for(i=0;i<5000;i++){printf "P %d\nT %d Bash\nD %d Bash\nS %d\n", ts, ts+1, ts+2, ts+3; ts+=10}}' \
  > "$HOME/.claude/session-env/$big_sid/events.log"
t0=$(date +%s)
printf '{"session_id":"%s","reason":"exit","cwd":"%s"}' "$big_sid" "$repo" \
  | bash "$DIR/../hooks/session-end.sh"
t1=$(date +%s)
elapsed=$((t1 - t0))
assert_eq "session-end under 5s on 20k events" "1" "$([ "$elapsed" -lt 5 ] && echo 1 || echo 0)"
one2() { sqlite3 "$(st_db_path)" "$1"; }
assert_eq "big session row recorded" "1" "$(one2 "SELECT COUNT(*) FROM sessions WHERE session_id='$big_sid';")"

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
