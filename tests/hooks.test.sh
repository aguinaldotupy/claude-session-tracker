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

# PostToolUseFailure appends a DF line carrying the tool type
echo '{"session_id":"'"$SID"'","tool_name":"Bash"}' | bash "$ROOT/hooks/post-tool-use-failure.sh"
line=$(tail -n1 "$EV")
assert_eq "post-tool-use-failure kind is DF" "DF" "$(echo "$line" | awk '{print $1}')"
assert_eq "post-tool-use-failure logs tool type" "Bash" "$(echo "$line" | awk '{print $3}')"

# StopFailure appends an SF line (no tool field)
echo '{"session_id":"'"$SID"'"}' | bash "$ROOT/hooks/stop-failure.sh"
line=$(tail -n1 "$EV")
assert_eq "stop-failure kind is SF" "SF" "$(echo "$line" | awk '{print $1}')"

# Missing session_id: no crash, no file
EMPTY_HOME="$TMP/empty"; mkdir -p "$EMPTY_HOME"
echo '{}' | HOME="$EMPTY_HOME" bash "$ROOT/hooks/pre-tool-use.sh"; rc=$?
assert_eq "missing session_id exits clean" "0" "$rc"
assert_eq "missing session_id writes nothing" "no" "$([ -d "$EMPTY_HOME/.claude/session-env" ] && echo yes || echo no)"

# hooks.json: every command must quote ${CLAUDE_PLUGIN_ROOT}. Claude Code passes
# the command line to `sh -c`; Claude Desktop installs plugins under
# "~/Library/Application Support/…", and an unquoted root word-splits there,
# silently breaking every hook in desktop sessions.
unquoted=$(jq -r '.hooks[][].hooks[].command
  | select((startswith("\"${CLAUDE_PLUGIN_ROOT}") and endswith("\"")) | not)' \
  "$ROOT/hooks/hooks.json")
assert_eq "hooks.json commands quote CLAUDE_PLUGIN_ROOT" "" "$unquoted"

# End-to-end: run the hooks.json command line via `sh -c` (as Claude Code does)
# with a plugin root containing a space.
SPACED="$TMP/plugin root with space"; mkdir -p "$SPACED"
cp -R "$ROOT/hooks" "$SPACED/hooks"
CMD=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT/hooks/hooks.json")
echo '{"session_id":"spaced-1","source":"startup"}' \
  | CLAUDE_PLUGIN_ROOT="$SPACED" sh -c "$CMD" >/dev/null 2>&1
assert_eq "spaced plugin root: session-start still writes timestamp" "yes" \
  "$([ -f "$HOME/.claude/session-env/spaced-1/session-tracker" ] && echo yes || echo no)"

finish
