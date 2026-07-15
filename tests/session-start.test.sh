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

DEPLOYED="$TMP/.claude/session-env/active-time.awk"
assert_eq "awk deployed to stable path" "yes" "$([ -f "$DEPLOYED" ] && echo yes || echo no)"
if diff -q "$ROOT/hooks/lib/active-time.awk" "$DEPLOYED" >/dev/null 2>&1; then d=same; else d=diff; fi
assert_eq "deployed copy matches source" "same" "$d"
# Existing behavior preserved: start timestamp written
assert_eq "start timestamp written" "yes" \
  "$([ -f "$TMP/.claude/session-env/$SID/session-tracker" ] && echo yes || echo no)"

# --- SQLite store bootstrap ---
SE2="$TMP/.claude/session-env"; mkdir -p "$SE2"
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
DEST="$TMP/.claude/session-env"
assert_eq "db.sh deployed" "yes" "$([ -f "$DEST/db.sh" ] && echo yes || echo no)"
assert_eq "session-query.sh deployed" "yes" "$([ -f "$DEST/session-query.sh" ] && echo yes || echo no)"
assert_eq "deployed session-query runs" "0" "$(bash "$DEST/session-query.sh" status --session none | jq -e . >/dev/null 2>&1; echo $?)"

finish
