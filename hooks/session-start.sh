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
for f in active-time.awk db.sh session-query.sh; do
  [ -f "$LIB_DIR/$f" ] && cp -f "$LIB_DIR/$f" "$HOME/.claude/session-env/$f" 2>/dev/null || true
done

# Create timestamp on new/cleared sessions, or if file is missing (e.g. plugin installed after session started)
if [ "$SOURCE" = "startup" ] || [ "$SOURCE" = "clear" ] || [ ! -f "$SESSION_FILE" ]; then
  echo "$(date +%s)" > "$SESSION_FILE"
fi

echo "CLAUDE_SESSION_FILE=$SESSION_FILE"
