#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"

TMP=$(mktemp -d); TMP="$(cd "$TMP" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
SE="$HOME/.claude/session-env"
mkdir -p "$SE"
# deployed libs, as session-start.sh would leave them
cp "$DIR/../hooks/lib/active-time.awk" "$SE/active-time.awk"
cp "$DIR/../hooks/lib/db.sh" "$SE/db.sh"
SYNC="$DIR/../hooks/lib/solidtime-sync.sh"
LOG="$SE/solidtime-sync.log"

# no config -> silent success, no log created
out="$(bash "$SYNC" 2>&1)"; rc=$?
assert_eq "no config exits 0" "0" "$rc"
assert_eq "no config no output" "" "$out"
assert_eq "no config no log" "0" "$([ -f "$LOG" ] && echo 1 || echo 0)"

# config present: run starts and logs, token never logged
cat > "$SE/solidtime.conf" <<EOF
SOLIDTIME_URL=https://time.test
SOLIDTIME_TOKEN=secret-token-123
SOLIDTIME_ORG_ID=org-1
EOF
chmod 600 "$SE/solidtime.conf"
bash "$SYNC" >/dev/null 2>&1
assert_eq "run creates log" "1" "$([ -f "$LOG" ] && echo 1 || echo 0)"
assert_eq "token never in log" "0" "$(grep -c 'secret-token-123' "$LOG")"

# lock held by a live run -> second run exits 0 and logs skip
mkdir -p "$SE/solidtime-sync.lock"
bash "$SYNC" >/dev/null 2>&1; rc=$?
assert_eq "locked run exits 0" "0" "$rc"
assert_eq "locked run logged" "1" "$(grep -c 'lock held' "$LOG")"
rmdir "$SE/solidtime-sync.lock"

# stale lock (>10 min) is broken and the run proceeds
mkdir -p "$SE/solidtime-sync.lock"
touch -t 202601010101 "$SE/solidtime-sync.lock"
bash "$SYNC" >/dev/null 2>&1
assert_eq "stale lock broken" "0" "$([ -d "$SE/solidtime-sync.lock" ] && echo 1 || echo 0)"

# rotation: >500 lines truncates to last 250
: > "$LOG"; i=0; while [ $i -lt 600 ]; do echo "line $i" >> "$LOG"; i=$((i+1)); done
bash "$SYNC" >/dev/null 2>&1
lines=$(wc -l < "$LOG" | tr -d ' ')
assert_eq "log rotated under 300" "1" "$([ "$lines" -lt 300 ] && echo 1 || echo 0)"
assert_eq "rotation kept newest" "1" "$(grep -c 'line 599' "$LOG")"

finish
