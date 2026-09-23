#!/usr/bin/env bash
# hook-adapter.sh — Antigravity (AGY) hook adapter for session-tracker.
# Translates AGY's JSON hook lifecycle events into session-tracker shell hooks,
# ensures output contract is strictly JSON, and updates the shared SQLite store.
set -uo pipefail

EVENT="${1:-}"

# agy/hooks is a symlink to ../hooks, so the plugin dir is the root both when
# it is symlinked from the repo and when `agy plugin install` copies it (the
# copy dereferences symlinks, so the hooks travel with it).
resolve_root() {
  local d
  for d in "${SESSION_TRACKER_PLUGIN_ROOT:-}" "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"; do
    [ -n "$d" ] && [ -f "$d/hooks/session-start.sh" ] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

ROOT="$(resolve_root || true)"
if [ -z "$ROOT" ]; then
  case "$EVENT" in
    pre-tool-use|stop) echo '{"decision":"allow"}' ;;
    *) echo '{}' ;;
  esac
  exit 0
fi

# Read AGY payload from stdin
INPUT="$(cat 2>/dev/null || true)"
CONV_ID="$(printf '%s' "$INPUT" | jq -r '.conversationId // .session_id // empty' 2>/dev/null || true)"

if [ -z "$CONV_ID" ]; then
  case "$EVENT" in
    pre-tool-use|stop) echo '{"decision":"allow"}' ;;
    *) echo '{}' ;;
  esac
  exit 0
fi

HOME_DIR="${SESSION_TRACKER_HOME:-$HOME/.session-tracker}"
CWD_PATH="$(printf '%s' "$INPUT" | jq -r '(.workspacePaths[0]) // .cwd // empty' 2>/dev/null || true)"
[ -z "$CWD_PATH" ] && CWD_PATH="$PWD"

case "$EVENT" in
  pre-invocation)
    # Per-conversation pointer for skills, which get no conversation id in their
    # env. One file per conversation (content = workspace) so concurrent
    # conversations don't overwrite each other; session-query.sh resolves them.
    mkdir -p "$HOME_DIR/current-sessions" 2>/dev/null || true
    printf '%s\n' "$CWD_PATH" > "$HOME_DIR/current-sessions/$CONV_ID" 2>/dev/null || true

    # Lazy SessionStart if this conversation is seen for the first time
    if [ ! -f "$HOME_DIR/$CONV_ID/session-tracker" ]; then
      jq -cn --arg session_id "$CONV_ID" --arg cwd "$CWD_PATH" --arg source "resume" \
        '{session_id:$session_id, cwd:$cwd, source:$source}' \
        | bash "$ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
    fi

    # Record UserPromptSubmit (P)
    jq -cn --arg session_id "$CONV_ID" '{session_id:$session_id}' \
      | bash "$ROOT/hooks/user-prompt-submit.sh" >/dev/null 2>&1 || true
    echo '{}'
    ;;

  pre-tool-use)
    TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.toolCall.name // .tool_name // empty' 2>/dev/null || true)"
    jq -cn --arg session_id "$CONV_ID" --arg tool_name "$TOOL_NAME" \
      '{session_id:$session_id, tool_name:$tool_name}' \
      | bash "$ROOT/hooks/pre-tool-use.sh" >/dev/null 2>&1 || true
    echo '{"decision":"allow"}'
    ;;

  post-tool-use)
    TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.toolCall.name // .tool_name // empty' 2>/dev/null || true)"
    ERROR_MSG="$(printf '%s' "$INPUT" | jq -r '.error // empty' 2>/dev/null || true)"
    if [ -n "$ERROR_MSG" ]; then
      jq -cn --arg session_id "$CONV_ID" --arg tool_name "$TOOL_NAME" \
        '{session_id:$session_id, tool_name:$tool_name}' \
        | bash "$ROOT/hooks/post-tool-use-failure.sh" >/dev/null 2>&1 || true
    else
      jq -cn --arg session_id "$CONV_ID" --arg tool_name "$TOOL_NAME" \
        '{session_id:$session_id, tool_name:$tool_name}' \
        | bash "$ROOT/hooks/post-tool-use.sh" >/dev/null 2>&1 || true
    fi
    echo '{}'
    ;;

  stop)
    ERROR_MSG="$(printf '%s' "$INPUT" | jq -r '.error // empty' 2>/dev/null || true)"
    if [ -n "$ERROR_MSG" ]; then
      jq -cn --arg session_id "$CONV_ID" '{session_id:$session_id}' \
        | bash "$ROOT/hooks/stop-failure.sh" >/dev/null 2>&1 || true
    else
      jq -cn --arg session_id "$CONV_ID" '{session_id:$session_id}' \
        | bash "$ROOT/hooks/stop.sh" >/dev/null 2>&1 || true
    fi

    # Consolidate turn checkpoint into SQLite
    jq -cn --arg session_id "$CONV_ID" --arg cwd "$CWD_PATH" --arg reason "stop" \
      '{session_id:$session_id, cwd:$cwd, reason:$reason}' \
      | bash "$ROOT/hooks/session-end.sh" >/dev/null 2>&1 || true

    # The turn is over: this conversation is no longer the one skills act on.
    rm -f "$HOME_DIR/current-sessions/$CONV_ID" 2>/dev/null || true
    echo '{"decision":"allow"}'
    ;;

  *)
    echo '{}'
    ;;
esac
