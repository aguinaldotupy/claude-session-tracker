#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$DIR/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
SID="test-session-123"
EV="$TMP/.claude/session-env/$SID/events.log"

# PreToolUse appends a T line carrying the tool type
echo '{"session_id":"'"$SID"'","tool_name":"Edit"}' | bash "$ROOT/hooks/pre-tool-use.sh"
line=$(tail -n1 "$EV")
assert_eq "pre-tool-use kind is T" "T" "$(echo "$line" | awk '{print $1}')"
assert_eq "pre-tool-use logs tool type" "Edit" "$(echo "$line" | awk '{print $3}')"

# PostToolUse appends a D line
echo '{"session_id":"'"$SID"'","tool_name":"Bash"}' | bash "$ROOT/hooks/post-tool-use.sh"
line=$(tail -n1 "$EV")
assert_eq "post-tool-use kind is D" "D" "$(echo "$line" | awk '{print $1}')"
assert_eq "post-tool-use logs tool type" "Bash" "$(echo "$line" | awk '{print $3}')"

# Missing session_id: no crash, no file
EMPTY_HOME="$TMP/empty"; mkdir -p "$EMPTY_HOME"
echo '{}' | HOME="$EMPTY_HOME" bash "$ROOT/hooks/pre-tool-use.sh"; rc=$?
assert_eq "missing session_id exits clean" "0" "$rc"
assert_eq "missing session_id writes nothing" "no" "$([ -d "$EMPTY_HOME/.claude/session-env" ] && echo yes || echo no)"

finish
