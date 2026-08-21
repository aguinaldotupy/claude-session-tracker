#!/usr/bin/env bash
set -euo pipefail

INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [ -z "$SESSION_ID" ]; then
  exit 0
fi

SESSION_DIR="$HOME/.claude/session-env/$SESSION_ID"
SESSION_FILE="$SESSION_DIR/session-tracker"

mkdir -p "$SESSION_DIR"

# Ensure the SQLite store exists and migrate any legacy history.jsonl.
# Soft dependency: all of this is skipped silently when sqlite3 is unavailable.
DB_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/import-history.sh"
if [ -f "$DB_LIB" ]; then
  # shellcheck source=/dev/null
  . "$DB_LIB"
  st_db_init 2>/dev/null || true
  st_import_history 2>/dev/null || true
  st_backfill_worktrees 2>/dev/null || true
fi

# Deploy read-side libs to a stable, plugin-independent path so the statusline
# and skills (which run outside the plugin dir) can source/invoke them.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# cp to a sibling temp then rename: `cp -f` rewrites the destination inode in
# place, and solidtime-sync.sh can be running detached from a previous session's
# SessionEnd (blocked in curl for up to 30s per entry). bash reads a script
# lazily by file offset, so overwriting it under a live interpreter makes it
# resume mid-file in rewritten bytes. A rename leaves the running process on its
# own inode.
for f in active-time.awk db.sh session-query.sh solidtime-sync.sh; do
  if [ -f "$LIB_DIR/$f" ]; then
    { cp -f "$LIB_DIR/$f" "$HOME/.claude/session-env/.$f.new" \
      && mv -f "$HOME/.claude/session-env/.$f.new" "$HOME/.claude/session-env/$f"; } 2>/dev/null \
      || rm -f "$HOME/.claude/session-env/.$f.new" 2>/dev/null || true
  fi
done

# Create timestamp on new/cleared sessions, or if file is missing (e.g. plugin installed after session started).
# events.log is truncated with it — same pair the reset-session skill writes. The
# two ARE one window: on `clear` the session_id is reused, so leaving the old
# events behind means every reader measures a window the timestamp says ended.
# SessionEnd hid that by clamping active_seconds to the (now short) duration, but
# the statusline over-reported and the Solidtime brackets — which nothing clamps —
# billed the whole pre-clear day.
if [ "$SOURCE" = "startup" ] || [ "$SOURCE" = "clear" ] || [ ! -f "$SESSION_FILE" ]; then
  echo "$(date +%s)" > "$SESSION_FILE"
  : > "$SESSION_DIR/events.log" 2>/dev/null || true
fi

# Retry any pending Solidtime syncs in the background; never blocks the hook.
# SOLIDTIME_URL env fallback covers ephemeral hosts without a conf file.
# Not on `compact`: it fires repeatedly inside one long session and no session
# can have finished since the last run, so every one of those runs is a
# guaranteed no-op that still pays for a store scan and a ledger walk.
if [ "$SOURCE" != "compact" ] && [ -f "$HOME/.claude/session-env/solidtime-sync.sh" ] \
   && { [ -f "$HOME/.claude/session-env/solidtime.conf" ] || [ -n "${SOLIDTIME_URL:-}" ]; }; then
  ( bash "$HOME/.claude/session-env/solidtime-sync.sh" >/dev/null 2>&1 & ) 2>/dev/null || true
fi

echo "CLAUDE_SESSION_FILE=$SESSION_FILE"
