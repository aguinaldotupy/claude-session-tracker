#!/usr/bin/env bash
# hook-adapter.sh — Antigravity (AGY) hook adapter for session-tracker.
# Translates AGY's JSON hook lifecycle events into session-tracker shell hooks,
# ensures output contract is strictly JSON, and updates the shared SQLite store.
set -uo pipefail

EVENT="${1:-}"

resolve_root() {
  if [ -n "${SESSION_TRACKER_PLUGIN_ROOT:-}" ] && [ -f "${SESSION_TRACKER_PLUGIN_ROOT}/hooks/session-start.sh" ]; then
    printf '%s' "$SESSION_TRACKER_PLUGIN_ROOT"
    return 0
  fi
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  if [ -f "$script_dir/../hooks/session-start.sh" ]; then
    (cd "$script_dir/.." && pwd)
    return 0
  fi
  local phys_dir
  phys_dir="$(cd "$script_dir" 2>/dev/null && pwd -P)"
  if [ -f "$phys_dir/../hooks/session-start.sh" ]; then
    (cd "$phys_dir/.." && pwd -P)
    return 0
  fi
  if [ -f "./hooks/session-start.sh" ]; then
    pwd
    return 0
  fi
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
    mkdir -p "$HOME_DIR" 2>/dev/null || true
    # Record current session for skills that don't receive environment variables
    printf '%s' "$CONV_ID" > "$HOME_DIR/current-session" 2>/dev/null || true

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

    # Clear active session pointer when the session terminates/stops
    rm -f "$HOME_DIR/current-session" 2>/dev/null || true
    echo '{"decision":"allow"}'
    ;;

  *)
    echo '{}'
    ;;
esac
