#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
. "$DIR/../hooks/lib/db.sh"
SQ="$DIR/../hooks/lib/session-query.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
mkdir -p "$HOME/.claude/session-env"
# active-time.awk must be at the deployed path for `status`
cp "$DIR/../hooks/lib/active-time.awk" "$HOME/.claude/session-env/active-time.awk"
st_db_init

TODAY=$(date +%s)
st_upsert_session "s1" "/p/a" "/p/a" "main" "A-1" "$TODAY" "$TODAY" 100 100 0 "other" "$TODAY"
st_upsert_session "s2" "/p/a" "/p/a" "main" ""    "$TODAY" "$TODAY" 200 200 0 "other" "$TODAY"

# status: today total sums both (300), 2 sessions; source sqlite (no jsonl present)
out="$(bash "$SQ" status --session none)"
assert_eq "status is valid json" "0" "$(printf '%s' "$out" | jq -e . >/dev/null 2>&1; echo $?)"
assert_eq "status source sqlite" "sqlite" "$(printf '%s' "$out" | jq -r .source)"
assert_eq "status today total" "300" "$(printf '%s' "$out" | jq -r .today.active_seconds)"
assert_eq "status today count" "2" "$(printf '%s' "$out" | jq -r .today.sessions)"

# live session: fabricate a session dir with a closed bracket → active 60 + grace 120 = 180
SID="live-1"; SD="$HOME/.claude/session-env/$SID"; mkdir -p "$SD"
echo "1000" > "$SD/session-tracker"
printf 'P 1000\nS 1060\n' > "$SD/events.log"
out="$(bash "$SQ" status --session "$SID")"
assert_eq "status live active (60+grace120)" "180" "$(printf '%s' "$out" | jq -r .live.active_seconds)"
assert_eq "status live started_at" "1000" "$(printf '%s' "$out" | jq -r .live.started_at)"

# --- history ---
# s1 has issue A-1; s2 only a branch → branch_issue falls back to branch
outh="$(bash "$SQ" history --range today --project a)"
assert_eq "history valid json" "0" "$(printf '%s' "$outh" | jq -e . >/dev/null 2>&1; echo $?)"
assert_eq "history source sqlite" "sqlite" "$(printf '%s' "$outh" | jq -r .source)"
assert_eq "history count 2" "2" "$(printf '%s' "$outh" | jq -r .count)"
assert_eq "history total 300" "300" "$(printf '%s' "$outh" | jq -r .total_active_seconds)"
assert_eq "history row s1 branch_issue=issue" "A-1" "$(printf '%s' "$outh" | jq -r '.rows[] | select(.active_seconds==100) | .branch_issue')"
assert_eq "history row s2 branch_issue=branch" "main" "$(printf '%s' "$outh" | jq -r '.rows[] | select(.active_seconds==200) | .branch_issue')"
assert_eq "history row has start_local HH:MM" "5" "$(printf '%s' "$outh" | jq -r '.rows[0].start_local' | grep -cE '^[0-9]{2}:[0-9]{2}$' | sed 's/1/5/')"

# project filter miss → empty rows, still valid json, count 0
outm="$(bash "$SQ" history --range today --project nope)"
assert_eq "history filter miss count 0" "0" "$(printf '%s' "$outm" | jq -r .count)"
assert_eq "history filter miss valid json" "0" "$(printf '%s' "$outm" | jq -e . >/dev/null 2>&1; echo $?)"

# a session from 1970 (start_ts small) is excluded by --range today
st_upsert_session "old" "/p/a" "/p/a" "main" "" 1000 1100 50 50 0 "other" 1101
assert_eq "history today excludes old" "2" "$(bash "$SQ" history --range today --project a | jq -r .count)"
assert_eq "history 30d also excludes 1970" "2" "$(bash "$SQ" history --range 30d --project a | jq -r .count)"

# --- jsonl-fallback history (Fix 2 + injection guard) ---
HJ2="$HOME/.claude/session-env/history.jsonl"
cat > "$HJ2" <<JSON
{"session_id":"hj1","project_dir":"/p/bel","active_seconds":30,"duration_seconds":30,"idle_seconds":0,"start_ts":$TODAY,"end_ts":$TODAY,"issue_key":"","reason":"other"}
{"session_id":"hj2","project_dir":"/p/bel","active_seconds":40,"duration_seconds":40,"idle_seconds":0,"start_ts":$TODAY,"end_ts":$TODAY,"issue_key":"BEL-9","reason":"other"}
JSON
assert_eq "jsonl source" "jsonl" "$(bash "$SQ" history --range today | jq -r .source)"
assert_eq "jsonl empty issue_key renders dash" "—" "$(bash "$SQ" history --range today | jq -r '.rows[]|select(.active_seconds==30).branch_issue')"
assert_eq "jsonl issue_key shown" "BEL-9" "$(bash "$SQ" history --range today | jq -r '.rows[]|select(.active_seconds==40).branch_issue')"
# --project injection must NOT bypass the filter (both rows are /p/bel; zzz should match none)
assert_eq "jsonl project filter not bypassable" "0" "$(bash "$SQ" history --range today --project 'zzz") or true or ("' | jq -r .count)"
# FROM..TO injection must NOT bypass (narrow future range → 0)
assert_eq "jsonl range FROM..TO not bypassable" "0" "$(bash "$SQ" history --range '2999-01-01" or true or "..2999-01-02' | jq -r .count)"
rm -f "$HJ2"

# --- timeline ---
# build events for s1 directly in the events table
sqlite3 "$(st_db_path)" "DELETE FROM events WHERE session_id='s1';
  INSERT INTO events(session_id,ts,kind,tool) VALUES
   ('s1',2000,'P',NULL),('s1',2005,'T','Read'),('s1',2017,'D','Read'),
   ('s1',2020,'T','Bash'),('s1',2262,'DF','Bash'),('s1',2400,'SF',NULL);"
outt="$(bash "$SQ" timeline s1)"
assert_eq "timeline valid json" "0" "$(printf '%s' "$outt" | jq -e . >/dev/null 2>&1; echo $?)"
assert_eq "timeline one interval" "1" "$(printf '%s' "$outt" | jq -r '.intervals|length')"
assert_eq "timeline api_error (SF)" "true" "$(printf '%s' "$outt" | jq -r '.intervals[0].api_error')"
assert_eq "timeline Read seconds" "12" "$(printf '%s' "$outt" | jq -r '.intervals[0].tools[]|select(.tool=="Read").seconds')"
assert_eq "timeline Bash failed (DF)" "true" "$(printf '%s' "$outt" | jq -r '.intervals[0].tools[]|select(.tool=="Bash").failed')"

# unknown session → empty intervals, valid json
oute="$(bash "$SQ" timeline nope-xyz)"
assert_eq "timeline unknown empty" "0" "$(printf '%s' "$oute" | jq -r '.intervals|length')"
assert_eq "timeline unknown valid json" "0" "$(printf '%s' "$oute" | jq -e . >/dev/null 2>&1; echo $?)"

# --- worklog ---
# s1 has issue A-1 (100s); s2 untagged (200s); add s3 with A-1 (50s) today
st_upsert_session "s3" "/p/a" "/p/a" "main" "A-1" "$TODAY" "$TODAY" 50 50 0 "other" "$TODAY"
outw="$(bash "$SQ" worklog --range today --project a)"
assert_eq "worklog valid json" "0" "$(printf '%s' "$outw" | jq -e . >/dev/null 2>&1; echo $?)"
assert_eq "worklog A-1 total (100+50)" "150" "$(printf '%s' "$outw" | jq -r '.by_issue[]|select(.issue_key=="A-1").active_seconds')"
assert_eq "worklog A-1 sessions" "2" "$(printf '%s' "$outw" | jq -r '.by_issue[]|select(.issue_key=="A-1").sessions')"
assert_eq "worklog untagged total (s2)" "200" "$(printf '%s' "$outw" | jq -r '.untagged.active_seconds')"

finish
