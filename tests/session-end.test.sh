#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$DIR/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
SID="end-session-1"
SDIR="$TMP/.claude/session-env/$SID"
mkdir -p "$SDIR"

# Session started 10 min ago; one 60s working interval, then parked until now.
now=$(date +%s)
start=$((now - 600))
echo "$start" > "$SDIR/session-tracker"
printf 'P %s\nS %s\n' "$start" "$((start + 60))" > "$SDIR/events.log"

echo '{"session_id":"'"$SID"'","reason":"exit","cwd":"'"$TMP"'"}' | bash "$ROOT/hooks/session-end.sh"

# With sqlite3 available (the norm on dev/CI machines), session-end now writes
# to the SQLite store first and returns before the legacy JSONL append — so
# these pre-existing assertions read the same computed values back from the DB.
DB0="$TMP/.claude/session-env/history.db"
# active = 60s work + 120s grace (parked gap >> grace) = 180
assert_eq "additive active_seconds" "180" "$(sqlite3 "$DB0" "SELECT active_seconds FROM sessions WHERE session_id='$SID';")"
# idle = duration - active; consistency check
dur=$(sqlite3 "$DB0" "SELECT duration_seconds FROM sessions WHERE session_id='$SID';")
act=$(sqlite3 "$DB0" "SELECT active_seconds FROM sessions WHERE session_id='$SID';")
idl=$(sqlite3 "$DB0" "SELECT idle_seconds FROM sessions WHERE session_id='$SID';")
assert_eq "idle = duration - active" "$((dur - act))" "$idl"

# --- SQLite write path ---
SIDB="sql-end-1"; SD="$TMP/.claude/session-env/$SIDB"; mkdir -p "$SD"
echo "1000" > "$SD/session-tracker"
printf 'P 1000\nT 1005 Read\nD 1040 Read\nS 1060\n' > "$SD/events.log"
echo '{"session_id":"'"$SIDB"'","reason":"other","cwd":"'"$TMP"'"}' | bash "$ROOT/hooks/session-end.sh" >/dev/null
DB="$TMP/.claude/session-env/history.db"
assert_eq "session row written" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE session_id='$SIDB';")"
assert_eq "events archived" "4" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE session_id='$SIDB';")"

# repeated SessionEnd (resume): still one row
echo '{"session_id":"'"$SIDB"'","reason":"resume","cwd":"'"$TMP"'"}' | bash "$ROOT/hooks/session-end.sh" >/dev/null
assert_eq "resume keeps one row" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE session_id='$SIDB';")"
assert_eq "events not duplicated on resume" "4" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE session_id='$SIDB';")"

# fallback: with sqlite3 masked off PATH, SessionEnd appends legacy JSONL
SIDF="fallback-1"; SDF="$TMP/.claude/session-env/$SIDF"; mkdir -p "$SDF"
echo "3000" > "$SDF/session-tracker"
# Closed P->S bracket makes active_seconds deterministic (independent of wall-clock end_ts):
# 60s worked interval + up to 120s capped reading-tail grace after the trailing S = 180
# (last_stop stays open past S until session end; see hooks/lib/active-time.awk END block,
# same pattern as the "additive active_seconds" case above).
printf 'P 3000\nS 3060\n' > "$SDF/events.log"
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
for b in bash jq date git awk cat basename dirname mkdir sed printf head tr; do ln -sf "$(command -v $b)" "$FAKEBIN/$b" 2>/dev/null; done
PATH="$FAKEBIN" bash "$ROOT/hooks/session-end.sh" <<< '{"session_id":"'"$SIDF"'","reason":"other","cwd":"'"$TMP"'"}' >/dev/null
assert_eq "fallback wrote jsonl" "yes" "$([ -f "$TMP/.claude/session-env/history.jsonl" ] && grep -q "$SIDF" "$TMP/.claude/session-env/history.jsonl" && echo yes || echo no)"
assert_eq "fallback jsonl active_seconds correct" "180" "$(jq -r 'select(.session_id=="'"$SIDF"'") | .active_seconds' "$TMP/.claude/session-env/history.jsonl")"
assert_eq "fallback jsonl idle = duration - active" "yes" "$(jq -r 'select(.session_id=="'"$SIDF"'") | (if .idle_seconds == .duration_seconds - .active_seconds then "yes" else "no" end)' "$TMP/.claude/session-env/history.jsonl")"

finish
