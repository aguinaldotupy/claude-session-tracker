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
# (written to a real temp file, not /dev/stdin: st_import_events's `[ -f "$log" ]`
# guard sees a pipe rather than a regular file when a heredoc is attached to a
# function call under some bash builds, e.g. Homebrew bash 5.x — this sidesteps
# that portability gap while keeping the same event data and assertion.)
cat > "$TMP/tl-events.log" <<'EVLOG'
P 500
T 505 Read
D 517 Read
S 560
EVLOG
st_import_events "a" "$TMP/tl-events.log"
tl=$(one "SELECT group_concat(kind||'@'||ts, ',') FROM (SELECT kind,ts FROM events WHERE session_id='a' ORDER BY ts);")
assert_eq "timeline ordered" "P@500,T@505,D@517,S@560" "$tl"

# a worktree whose PATH lacks the repo name still groups via project_root (the feature's core claim)
st_upsert_session "d" "/p/bel" "/tmp/wt-xyz" "feature2" "" "$TODAY_TS" "$TODAY_TS" 10 10 0 "other" "$TODAY_TS"
cnt2=$(one "SELECT COUNT(*) FROM sessions s JOIN projects p ON p.id=s.project_id WHERE p.project_root LIKE '%bel%' OR s.project_dir LIKE '%bel%';")
assert_eq "grouping catches path without repo name" "4" "$cnt2"

finish
