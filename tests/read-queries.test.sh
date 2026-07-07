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
