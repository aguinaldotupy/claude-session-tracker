#!/usr/bin/env bash
# Test suite for Antigravity (AGY) plugin adapter.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$DIR/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
unset SESSION_TRACKER_HOME
PROJ="$TMP/my-project"; mkdir -p "$PROJ"
SE="$TMP/.session-tracker"
CID="agy-conversation-123"
ADAPTER="$ROOT/agy/hook-adapter.sh"

# 1. PreInvocation: initializes new session and records prompt (P)
out_pi=$(printf '{"conversationId":"%s","workspacePaths":["%s"],"invocationNum":1}' "$CID" "$PROJ" \
  | bash "$ADAPTER" pre-invocation)

assert_eq "pre-invocation stdout is valid json" "{}" "$out_pi"
assert_eq "session-tracker timestamp written" "yes" \
  "$([ -s "$SE/$CID/session-tracker" ] && echo yes || echo no)"
assert_eq "cwd saved" "$PROJ" "$(cat "$SE/$CID/cwd" 2>/dev/null)"
assert_eq "current-session recorded during active turn" "$CID" "$(cat "$SE/current-session" 2>/dev/null)"
assert_eq "events has prompt P" "P" "$(awk '{print $1}' "$SE/$CID/events.log" 2>/dev/null)"

# 2. While session is active: session-query.sh status resolves via current-session fallback
status_active=$(SESSION_TRACKER_SESSION_ID="" CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="" \
  bash "$ROOT/hooks/lib/session-query.sh" status)

assert_eq "status resolves active session via current-session fallback" "true" \
  "$(printf '%s' "$status_active" | jq -r '.live.started_at > 0')"

# 3. PreToolUse: records T <tool> and outputs decision allow
out_pt=$(printf '{"conversationId":"%s","toolCall":{"name":"run_command","args":{"CommandLine":"echo hello"}}}' "$CID" \
  | bash "$ADAPTER" pre-tool-use)

assert_eq "pre-tool-use stdout is decision allow" '{"decision":"allow"}' "$out_pt"
assert_eq "events has T run_command" "T run_command" \
  "$(awk 'NR==2{print $1, $3}' "$SE/$CID/events.log" 2>/dev/null)"

# 4. PostToolUse: records D <tool> and outputs empty json
out_post_ok=$(printf '{"conversationId":"%s","toolCall":{"name":"run_command"}}' "$CID" \
  | bash "$ADAPTER" post-tool-use)

assert_eq "post-tool-use stdout is empty json" "{}" "$out_post_ok"
assert_eq "events has D run_command" "D run_command" \
  "$(awk 'NR==3{print $1, $3}' "$SE/$CID/events.log" 2>/dev/null)"

# PostToolUse with error: records DF <tool>
out_post_err=$(printf '{"conversationId":"%s","toolCall":{"name":"run_command"},"error":"exit 1"}' "$CID" \
  | bash "$ADAPTER" post-tool-use)

assert_eq "post-tool-use error stdout is empty json" "{}" "$out_post_err"
assert_eq "events has DF run_command" "DF run_command" \
  "$(awk 'NR==4{print $1, $3}' "$SE/$CID/events.log" 2>/dev/null)"

# 5. Stop: records S, checkpoints to SQLite, and clears active session pointer
out_stop=$(printf '{"conversationId":"%s","workspacePaths":["%s"],"terminationReason":"model_stop"}' "$CID" "$PROJ" \
  | bash "$ADAPTER" stop)

assert_eq "stop stdout is decision allow" '{"decision":"allow"}' "$out_stop"
assert_eq "events has S" "S" "$(awk 'NR==5{print $1}' "$SE/$CID/events.log" 2>/dev/null)"
assert_eq "current-session cleared after stop" "no" \
  "$([ -f "$SE/current-session" ] && echo yes || echo no)"

# Verify SQLite store row was written
if command -v sqlite3 >/dev/null 2>&1; then
  assert_eq "session recorded in sqlite" "1" \
    "$(sqlite3 "$SE/history.db" "SELECT COUNT(*) FROM sessions WHERE session_id='$CID';" 2>/dev/null)"
  assert_eq "project resolved correctly" "my-project" \
    "$(sqlite3 "$SE/history.db" "SELECT p.name FROM sessions s JOIN projects p ON p.id=s.project_id WHERE s.session_id='$CID';" 2>/dev/null)"
fi

# 6. After stop: status returns empty live object and counts session under today
status_stopped=$(SESSION_TRACKER_SESSION_ID="" CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="" \
  bash "$ROOT/hooks/lib/session-query.sh" status)

assert_eq "live object empty after session ends" "0" \
  "$(printf '%s' "$status_stopped" | jq -r '.live.started_at')"
if command -v sqlite3 >/dev/null 2>&1; then
  assert_eq "today count reflects completed session" "1" \
    "$(printf '%s' "$status_stopped" | jq -r '.today.sessions')"
fi

# 7. Subsequent turn in same conversation preserves start timestamp and upserts row
orig_ts="$(cat "$SE/$CID/session-tracker")"
out_pi2=$(printf '{"conversationId":"%s","workspacePaths":["%s"],"invocationNum":2}' "$CID" "$PROJ" \
  | bash "$ADAPTER" pre-invocation)

assert_eq "turn 2 preserves original start timestamp" "$orig_ts" "$(cat "$SE/$CID/session-tracker")"

out_stop2=$(printf '{"conversationId":"%s","workspacePaths":["%s"],"terminationReason":"model_stop"}' "$CID" "$PROJ" \
  | bash "$ADAPTER" stop)

assert_eq "turn 2 stop stdout is decision allow" '{"decision":"allow"}' "$out_stop2"
assert_eq "current-session cleared after turn 2 stop" "no" \
  "$([ -f "$SE/current-session" ] && echo yes || echo no)"

if command -v sqlite3 >/dev/null 2>&1; then
  assert_eq "turn 2 upserts into single row" "1" \
    "$(sqlite3 "$SE/history.db" "SELECT COUNT(*) FROM sessions WHERE session_id='$CID';" 2>/dev/null)"
fi

# 8. Paths with quotes and spaces are safely JSON-encoded
WEIRD_DIR="$TMP/weird \"dir\" with spaces"
mkdir -p "$WEIRD_DIR"
WEIRD_CID="weird-conv-456"
out_weird=$(jq -cn --arg cid "$WEIRD_CID" --arg p "$WEIRD_DIR" '{conversationId:$cid, workspacePaths:[$p]}' \
  | bash "$ADAPTER" pre-invocation)
assert_eq "weird path pre-invocation is valid json" "{}" "$out_weird"
assert_eq "weird path cwd saved correctly" "$WEIRD_DIR" "$(cat "$SE/$WEIRD_CID/cwd" 2>/dev/null)"

finish
