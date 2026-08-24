#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$DIR/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
SID="start-session-1"

echo '{"session_id":"'"$SID"'","source":"startup"}' | bash "$ROOT/hooks/session-start.sh" >/dev/null

DEPLOYED="$TMP/.session-tracker/active-time.awk"
assert_eq "awk deployed to stable path" "yes" "$([ -f "$DEPLOYED" ] && echo yes || echo no)"
if diff -q "$ROOT/hooks/lib/active-time.awk" "$DEPLOYED" >/dev/null 2>&1; then d=same; else d=diff; fi
assert_eq "deployed copy matches source" "same" "$d"
# Existing behavior preserved: start timestamp written
assert_eq "start timestamp written" "yes" \
  "$([ -f "$TMP/.session-tracker/$SID/session-tracker" ] && echo yes || echo no)"

# --- SQLite store bootstrap ---
SE2="$TMP/.session-tracker"; mkdir -p "$SE2"
cat > "$SE2/history.jsonl" <<'JSON'
{"session_id":"m1","project_dir":"/p/x","active_seconds":42,"duration_seconds":42,"idle_seconds":0,"start_ts":10,"end_ts":52,"reason":"other"}
JSON
echo '{"session_id":"boot-1","source":"startup"}' | bash "$ROOT/hooks/session-start.sh" >/dev/null
db="$SE2/history.db"
assert_eq "db created on start" "yes" "$([ -f "$db" ] && echo yes || echo no)"
assert_eq "history migrated on start" "42" "$(sqlite3 "$db" "SELECT active_seconds FROM sessions WHERE session_id='m1';")"
assert_eq "history file renamed" "no" "$([ -f "$SE2/history.jsonl" ] && echo yes || echo no)"

# --- deploy of db.sh + session-query.sh for skills ---
echo '{"session_id":"dep-1","source":"startup"}' | bash "$ROOT/hooks/session-start.sh" >/dev/null
DEST="$TMP/.session-tracker"
assert_eq "db.sh deployed" "yes" "$([ -f "$DEST/db.sh" ] && echo yes || echo no)"
assert_eq "session-query.sh deployed" "yes" "$([ -f "$DEST/session-query.sh" ] && echo yes || echo no)"
assert_eq "solidtime-sync.sh deployed" "yes" "$([ -f "$DEST/solidtime-sync.sh" ] && echo yes || echo no)"
assert_eq "deployed session-query runs" "0" "$(bash "$DEST/session-query.sh" status --session none | jq -e . >/dev/null 2>&1; echo $?)"

# --- /clear resets the whole window, timestamp AND events ---
# The session_id is reused across a clear, so leaving events.log behind left every
# reader measuring a window the timestamp said had ended: SessionEnd hid it by
# clamping active_seconds to the new short duration, but the statusline
# over-reported and the Solidtime brackets (which nothing clamps) billed the
# entire pre-clear day. Verified before the fix: stored active=100s, posted=390s.
CS="clear-session-1"; CSD="$TMP/.session-tracker/$CS"; mkdir -p "$CSD"
printf 'P 1000\nS 1060\nP 5000\nS 5100\n' > "$CSD/events.log"
echo '{"session_id":"'"$CS"'","source":"clear"}' | bash "$ROOT/hooks/session-start.sh" >/dev/null
assert_eq "clear truncates events.log" "0" "$(wc -c < "$CSD/events.log" | tr -d ' ')"
assert_eq "clear rewrites the timestamp" "yes" "$([ -s "$CSD/session-tracker" ] && echo yes || echo no)"
assert_eq "clear leaves no stale brackets to bill" "" \
  "$(awk -v grace=120 -v t_end=9999999999 -v mode=brackets -f "$DEST/active-time.awk" "$CSD/events.log")"

# resume/compact must NOT truncate — the window is still open
RS="resume-session-1"; RSD="$TMP/.session-tracker/$RS"; mkdir -p "$RSD"
printf 'P 1000\nS 1060\n' > "$RSD/events.log"; echo 900 > "$RSD/session-tracker"
echo '{"session_id":"'"$RS"'","source":"resume"}' | bash "$ROOT/hooks/session-start.sh" >/dev/null
assert_eq "resume keeps events.log" "P 1000" "$(head -n1 "$RSD/events.log")"
assert_eq "resume keeps the original timestamp" "900" "$(cat "$RSD/session-tracker")"

finish
