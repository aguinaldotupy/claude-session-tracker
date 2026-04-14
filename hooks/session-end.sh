#!/usr/bin/env bash
# SessionEnd hook: records the finished session into a JSONL history log.
# Must never block session shutdown — any failure is swallowed (exit 0).

set -uo pipefail

{
  INPUT=$(cat)
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
  REASON=$(echo "$INPUT" | jq -r '.reason // "unknown"')
  CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

  [ -z "$SESSION_ID" ] && exit 0

  SESSION_DIR="$HOME/.claude/session-env/$SESSION_ID"
  SESSION_FILE="$SESSION_DIR/session-tracker"
  HISTORY_FILE="$HOME/.claude/session-env/history.jsonl"

  # No recorded start → nothing to log, bail silently.
  [ -f "$SESSION_FILE" ] || exit 0

  START_TS=$(cat "$SESSION_FILE" 2>/dev/null || echo "")
  case "$START_TS" in
    ''|*[!0-9]*) exit 0 ;;
  esac

  END_TS=$(date +%s)
  DURATION=$((END_TS - START_TS))
  [ "$DURATION" -lt 0 ] && DURATION=0

  # Resolve issue key: explicit tag file wins, else branch heuristic, else empty.
  ISSUE_KEY=""
  TAG_FILE="$SESSION_DIR/issue-tag"
  if [ -f "$TAG_FILE" ]; then
    ISSUE_KEY=$(head -n 1 "$TAG_FILE" 2>/dev/null | tr -d '[:space:]')
  fi
  if [ -z "$ISSUE_KEY" ] && [ -n "$CWD" ] && command -v git >/dev/null 2>&1; then
    BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || true)
    if [ -n "$BRANCH" ]; then
      # Grep for first [A-Z][A-Z0-9_]+-[0-9]+ token on the branch name.
      MATCH=$(printf '%s\n' "$BRANCH" | grep -oE '[A-Z][A-Z0-9_]+-[0-9]+' | head -n 1 || true)
      [ -n "$MATCH" ] && ISSUE_KEY="$MATCH"
    fi
  fi

  mkdir -p "$(dirname "$HISTORY_FILE")"

  LINE=$(jq -c -n \
    --arg session_id "$SESSION_ID" \
    --argjson start_ts "$START_TS" \
    --argjson end_ts "$END_TS" \
    --argjson duration_seconds "$DURATION" \
    --arg project_dir "$CWD" \
    --arg reason "$REASON" \
    --arg issue_key "$ISSUE_KEY" \
    '{session_id:$session_id,start_ts:$start_ts,end_ts:$end_ts,duration_seconds:$duration_seconds,project_dir:$project_dir,reason:$reason,issue_key:$issue_key}')

  [ -z "$LINE" ] && exit 0

  if command -v flock >/dev/null 2>&1; then
    (
      flock 9
      printf '%s\n' "$LINE" >> "$HISTORY_FILE"
    ) 9>>"$HISTORY_FILE"
  else
    # macOS: no flock. JSONL appends via `>>` on local FS are atomic for small lines.
    printf '%s\n' "$LINE" >> "$HISTORY_FILE"
  fi
} || exit 0

exit 0
