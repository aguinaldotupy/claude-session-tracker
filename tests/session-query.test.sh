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

finish
