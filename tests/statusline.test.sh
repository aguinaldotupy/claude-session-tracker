#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$DIR/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
SID="sl-session-1"
ENVDIR="$TMP/.claude/session-env"
SDIR="$ENVDIR/$SID"
mkdir -p "$SDIR"
# Simulate the deploy that session-start.sh performs
cp "$ROOT/hooks/lib/active-time.awk" "$ENVDIR/active-time.awk"

now=$(date +%s)
start=$((now - 600))             # wall-clock would be 10m
echo "$start" > "$SDIR/session-tracker"
printf 'P %s\nS %s\n' "$start" "$((start + 60))" > "$SDIR/events.log"

input='{"session_id":"'"$SID"'"}'
session_time=""
. "$ROOT/statusline-snippet.sh"
# active = 60s work + 120s grace = 180s = 3m  (NOT the 10m wall-clock)
assert_eq "statusline shows active time" "3m" "$session_time"

# Legacy fallback: no events.log → wall-clock
rm -f "$SDIR/events.log"
session_time=""
. "$ROOT/statusline-snippet.sh"
assert_eq "statusline falls back to wall-clock" "10m" "$session_time"

finish
