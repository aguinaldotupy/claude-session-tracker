#!/usr/bin/env bash
set -euo pipefail

INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

if [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Relocate a pre-v4 store off the legacy Claude-Code-specific path before
# anything creates the new home — st_migrate_home only moves into a home that
# does not exist yet (or is empty), so it has to come before the first mkdir.
DB_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/import-history.sh"
if [ -f "$DB_LIB" ]; then
  # shellcheck source=/dev/null
  . "$DB_LIB"
  st_migrate_home 2>/dev/null || true
  st_migrate_config 2>/dev/null || true
fi

ST_HOME="${SESSION_TRACKER_HOME:-$HOME/.session-tracker}"
SESSION_DIR="$ST_HOME/$SESSION_ID"
SESSION_FILE="$SESSION_DIR/session-tracker"

mkdir -p "$SESSION_DIR"

# Ensure the SQLite store exists and migrate any legacy history.jsonl.
# Soft dependency: all of this is skipped silently when sqlite3 is unavailable.
if [ -f "$DB_LIB" ]; then
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
for f in active-time.awk db.sh session-query.sh solidtime-sync.sh reap-sessions.sh; do
  if [ -f "$LIB_DIR/$f" ]; then
    { cp -f "$LIB_DIR/$f" "$ST_HOME/.$f.new" \
      && mv -f "$ST_HOME/.$f.new" "$ST_HOME/$f"; } 2>/dev/null \
      || rm -f "$ST_HOME/.$f.new" 2>/dev/null || true
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

# Persist the cwd for reap-sessions.sh: a session that dies without a SessionEnd
# is finalized from its own files alone, and this is the only record of which
# project it belonged to.
if [ -n "$CWD" ]; then
  printf '%s\n' "$CWD" > "$SESSION_DIR/cwd" 2>/dev/null || true
fi

# Close out sessions that died without a SessionEnd (crash, kill, power loss).
# Detached: the sweep walks every recent session dir and must not spend the
# hook's 5s budget. Never on `compact` — same reasoning as the sync below.
if [ "$SOURCE" != "compact" ] && [ -f "$ST_HOME/reap-sessions.sh" ]; then
  ( bash "$ST_HOME/reap-sessions.sh" --exclude "$SESSION_ID" >/dev/null 2>&1 & ) 2>/dev/null || true
fi

# Retry any pending Solidtime syncs in the background; never blocks the hook.
# SOLIDTIME_URL env fallback covers ephemeral hosts without a conf file.
# Not on `compact`: it fires repeatedly inside one long session and no session
# can have finished since the last run, so every one of those runs is a
# guaranteed no-op that still pays for a store scan and a ledger walk.
if [ "$SOURCE" != "compact" ] && [ -f "$ST_HOME/solidtime-sync.sh" ] \
   && { [ -f "$ST_HOME/config.yml" ] || [ -n "${SOLIDTIME_URL:-}" ]; }; then
  ( bash "$ST_HOME/solidtime-sync.sh" >/dev/null 2>&1 & ) 2>/dev/null || true
fi

echo "CLAUDE_SESSION_FILE=$SESSION_FILE"
