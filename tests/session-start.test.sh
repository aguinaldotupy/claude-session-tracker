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

finish
