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
assert_eq "pointer recorded during active turn (content = workspace)" "$PROJ" "$(cat "$SE/current-sessions/$CID" 2>/dev/null)"
assert_eq "events has prompt P" "P" "$(awk '{print $1}' "$SE/$CID/events.log" 2>/dev/null)"

# 2. While session is active: session-query.sh status resolves via the pointer fallback
status_active=$(SESSION_TRACKER_SESSION_ID="" CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="" \
  bash "$ROOT/hooks/lib/session-query.sh" status)

assert_eq "status resolves active session via pointer fallback" "true" \
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
assert_eq "pointer cleared after stop" "no" \
  "$([ -f "$SE/current-sessions/$CID" ] && echo yes || echo no)"

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
assert_eq "status still resolves live session on turn 2 (checkpoint row exists)" "$orig_ts" \
  "$(bash "$ROOT/hooks/lib/session-query.sh" status | jq -r '.live.started_at')"

out_stop2=$(printf '{"conversationId":"%s","workspacePaths":["%s"],"terminationReason":"model_stop"}' "$CID" "$PROJ" \
  | bash "$ADAPTER" stop)

assert_eq "turn 2 stop stdout is decision allow" '{"decision":"allow"}' "$out_stop2"
assert_eq "pointer cleared after turn 2 stop" "no" \
  "$([ -f "$SE/current-sessions/$CID" ] && echo yes || echo no)"

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

# 9. Two live conversations (weird-conv from step 8 is still mid-turn): the
# pointer is picked by workspace, never guessed.
RESET_CID="reset-conv-789"
printf '{"conversationId":"%s","workspacePaths":["%s"],"invocationNum":1}' "$RESET_CID" "$PROJ" \
  | bash "$ADAPTER" pre-invocation >/dev/null 2>&1
resolve() { (cd "$1" && bash "$SE/session-query.sh" session | jq -r '.session_id'); }
assert_eq "two live conversations: resolved by workspace" "$RESET_CID" "$(resolve "$PROJ/")"
assert_eq "two live conversations: other workspace" "$WEIRD_CID" "$(resolve "$WEIRD_DIR")"
assert_eq "two live conversations, no matching workspace: nothing" "" "$(resolve "$TMP")"
assert_eq "env id beats pointers" "$CID" \
  "$(cd "$PROJ" && ANTIGRAVITY_CONVERSATION_ID="$CID" bash "$SE/session-query.sh" session | jq -r '.session_id')"

# A pointer left by a turn that died is ignored once the reaper closed it...
if command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$SE/history.db" "UPDATE sessions SET reason='stale', end_ts=9999999999 WHERE session_id='$CID';"
  mkdir -p "$SE/current-sessions"; printf '%s\n' "$PROJ" > "$SE/current-sessions/$CID"
  assert_eq "reaped pointer ignored" "$RESET_CID" "$(resolve "$PROJ")"
  rm -f "$SE/current-sessions/$CID"
fi

# Run the snippets exactly as shipped, so the test breaks when they drift.
reset_snippet() { awk '/^```bash$/{f=1;next} /^```$/{f=0} f' "$1"; }
assert_eq "reset command and skill ship the same snippet" \
  "$(reset_snippet "$ROOT/skills/reset-session/SKILL.md" | grep -v '^ *#')" \
  "$(reset_snippet "$ROOT/commands/reset-session.md")"

echo 1000 > "$SE/$RESET_CID/session-tracker"
wc_weird_before="$(wc -c < "$SE/$WEIRD_CID/events.log" | tr -d ' ')"
reset_out=$(cd "$PROJ" && bash -c "$(reset_snippet "$ROOT/skills/reset-session/SKILL.md")")

assert_eq "reset-session reports success" "1" "$(printf '%s' "$reset_out" | grep -c "Session timer reset at")"
assert_eq "reset-session rewrites start timestamp" "yes" \
  "$([ "$(cat "$SE/$RESET_CID/session-tracker")" -gt 1000 ] && echo yes || echo no)"
assert_eq "reset-session truncates events.log" "0" "$(wc -c < "$SE/$RESET_CID/events.log" | tr -d ' ')"
assert_eq "reset-session leaves the other conversation alone" "$wc_weird_before" \
  "$(wc -c < "$SE/$WEIRD_CID/events.log" | tr -d ' ')"

reset_amb=$(cd "$TMP" && bash -c "$(reset_snippet "$ROOT/skills/reset-session/SKILL.md")")
assert_eq "ambiguous reset refuses" "1" "$(printf '%s' "$reset_amb" | grep -c "Session not found")"

# 10. /tag resolves the session the same way (it used to need CLAUDE_SESSION_FILE)
tag_out=$(cd "$PROJ" && ARGUMENTS="LIN-42" bash -c "$(reset_snippet "$ROOT/commands/tag.md")")
assert_eq "tag writes issue-tag in AGY" "LIN-42" "$(cat "$SE/$RESET_CID/issue-tag" 2>/dev/null)"
assert_eq "tag reports success" "1" "$(printf '%s' "$tag_out" | grep -c "Tagged current session as LIN-42")"

# 11. `agy plugin install` stages a copy with symlinks dereferenced, away from
# the repo. The copy must still find the hooks (via agy/hooks), from any cwd.
cp -RL "$ROOT/agy" "$TMP/agy-installed"
INST_CID="installed-conv-1"
(cd "$TMP" && printf '{"conversationId":"%s","workspacePaths":["%s"]}' "$INST_CID" "$PROJ" \
  | bash "$TMP/agy-installed/hook-adapter.sh" pre-invocation >/dev/null)
assert_eq "installed copy (no repo alongside) still tracks" "P" \
  "$(awk '{print $1}' "$SE/$INST_CID/events.log" 2>/dev/null)"
assert_eq "installed copy ships the skills as files" "yes" \
  "$([ -f "$TMP/agy-installed/skills/reset-session/SKILL.md" ] && echo yes || echo no)"

finish

