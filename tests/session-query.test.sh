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

# --- worklog jsonl-mode (source + FROM..TO + injection) ---
HJW="$HOME/.claude/session-env/history.jsonl"
cat > "$HJW" <<JSON
{"session_id":"w1","project_dir":"/p/bel","active_seconds":60,"duration_seconds":60,"idle_seconds":0,"start_ts":$TODAY,"end_ts":$TODAY,"issue_key":"BEL-7","reason":"other"}
{"session_id":"w2","project_dir":"/p/bel","active_seconds":90,"duration_seconds":90,"idle_seconds":0,"start_ts":$TODAY,"end_ts":$TODAY,"issue_key":"","reason":"other"}
JSON
assert_eq "worklog jsonl source" "jsonl" "$(bash "$SQ" worklog --range today | jq -r .source)"
assert_eq "worklog jsonl by_issue BEL-7" "60" "$(bash "$SQ" worklog --range today | jq -r '.by_issue[]|select(.issue_key=="BEL-7").active_seconds')"
assert_eq "worklog jsonl untagged" "90" "$(bash "$SQ" worklog --range today | jq -r '.untagged.active_seconds')"
# FROM..TO (broad range incl. today) must return the data, not empty (the bug)
YEAR_AGO="$(date -v-1y +%Y-%m-%d 2>/dev/null || date -d '1 year ago' +%Y-%m-%d)"
YEAR_AHEAD="$(date -v+1y +%Y-%m-%d 2>/dev/null || date -d '1 year' +%Y-%m-%d)"
assert_eq "worklog jsonl FROM..TO returns data" "60" "$(bash "$SQ" worklog --range "$YEAR_AGO..$YEAR_AHEAD" | jq -r '.by_issue[]|select(.issue_key=="BEL-7").active_seconds')"
# injection in --project must not bypass
assert_eq "worklog jsonl project not bypassable" "0" "$(bash "$SQ" worklog --range today --project 'zzz") or true or ("' | jq -r '.by_issue|length')"
rm -f "$HJW"

# --- guard: source resolution ---
# (a) with a history.jsonl present, reads the COMPLETE deduped JSONL (source jsonl),
#     even though the partial DB exists — this is the v3.0.1/3.0.2 regression guard.
HJ="$HOME/.claude/session-env/history.jsonl"
cat > "$HJ" <<JSON
{"session_id":"j1","project_dir":"/p/z","active_seconds":10,"duration_seconds":10,"idle_seconds":0,"start_ts":$TODAY,"end_ts":$TODAY,"issue_key":"","reason":"other"}
{"session_id":"j1","project_dir":"/p/z","active_seconds":40,"duration_seconds":40,"idle_seconds":0,"start_ts":$TODAY,"end_ts":$((TODAY+5)),"issue_key":"","reason":"other"}
{"session_id":"j2","project_dir":"/p/z","active_seconds":25,"duration_seconds":25,"idle_seconds":0,"start_ts":$TODAY,"end_ts":$TODAY,"issue_key":"","reason":"other"}
JSON
gj="$(bash "$SQ" history --range today)"
assert_eq "guard prefers jsonl when present" "jsonl" "$(printf '%s' "$gj" | jq -r .source)"
# deduped: j1 keeps 40 (max end), j2 25 → total 65, 2 rows
assert_eq "jsonl deduped total" "65" "$(printf '%s' "$gj" | jq -r .total_active_seconds)"
assert_eq "jsonl deduped count" "2" "$(printf '%s' "$gj" | jq -r .count)"
rm -f "$HJ"

# (b) sqlite3 stubbed off PATH + jsonl present → source jsonl
cat > "$HJ" <<JSON
{"session_id":"k1","project_dir":"/p/z","active_seconds":7,"duration_seconds":7,"idle_seconds":0,"start_ts":$TODAY,"end_ts":$TODAY,"issue_key":"","reason":"other"}
JSON
FAKEBIN="$HOME/fakebin"; mkdir -p "$FAKEBIN"
for b in jq awk sed grep cat head printf date tr dirname basename mkdir bash; do ln -sf "$(command -v $b)" "$FAKEBIN/$b" 2>/dev/null; done
assert_eq "no sqlite3 → jsonl" "jsonl" "$(PATH="$FAKEBIN" bash "$SQ" history --range today | jq -r .source)"
rm -f "$HJ"

# (c) no DB and no jsonl → source none, empty
rm -f "$(st_db_path)"
gn="$(bash "$SQ" history --range today)"
assert_eq "no store → source none" "none" "$(printf '%s' "$gn" | jq -r .source)"
assert_eq "no store → count 0" "0" "$(printf '%s' "$gn" | jq -r .count)"
assert_eq "no store → valid json" "0" "$(printf '%s' "$gn" | jq -e . >/dev/null 2>&1; echo $?)"

# --project filter must catch a worktree session via project_root even when its
# project_dir lacks the filter substring (the project_root LIKE OR project_dir LIKE predicate).
rm -f "$HOME/.claude/session-env/history.jsonl"   # ensure sqlite source
st_db_init   # the (c) guard above removed the DB file; recreate schema before upserting
st_upsert_session "pfMain" "/p/proj" "/p/proj"      "main" "PROJ-1" "$TODAY" "$TODAY" 10 10 0 "other" "$TODAY"
st_upsert_session "pfWt"   "/p/proj" "/tmp/wt-xyz"  "feat" "PROJ-2" "$TODAY" "$TODAY" 20 20 0 "other" "$TODAY"
# '/tmp/wt-xyz' lacks 'proj', so pfWt matches ONLY via project_root='/p/proj' → filter must catch BOTH
assert_eq "history --project catches worktree via project_root" "2" "$(bash "$SQ" history --range today --project proj | jq -r .count)"
assert_eq "worklog --project catches worktree via project_root" "2" "$(bash "$SQ" worklog --range today --project proj | jq -r '[.by_issue[].sessions]|add')"

finish
