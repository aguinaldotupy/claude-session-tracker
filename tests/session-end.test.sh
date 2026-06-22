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

HIST="$TMP/.claude/session-env/history.jsonl"
line=$(tail -n1 "$HIST")
# active = 60s work + 120s grace (parked gap >> grace) = 180
assert_eq "additive active_seconds" "180" "$(echo "$line" | jq -r '.active_seconds')"
# idle = duration - active; consistency check
dur=$(echo "$line" | jq -r '.duration_seconds')
act=$(echo "$line" | jq -r '.active_seconds')
idl=$(echo "$line" | jq -r '.idle_seconds')
assert_eq "idle = duration - active" "$((dur - act))" "$idl"

finish
