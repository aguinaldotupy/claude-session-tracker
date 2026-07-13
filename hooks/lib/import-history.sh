#!/usr/bin/env bash
# Idempotent migration of the legacy history.jsonl into SQLite. Sourceable.
# Safe to run repeatedly: upsert by session_id means re-runs never duplicate.

_ST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_ST_LIB_DIR/db.sh"

# Migrate history.jsonl → SQLite in a SINGLE sqlite3 transaction. One jq process
# (raw-input + `fromjson?`) emits every upsert and skips malformed lines, so a
# multi-thousand-row history imports in well under a second — critical because
# this runs inside the SessionStart hook's 5s timeout. A per-row sqlite3 spawn
# (the previous approach) took ~85s for ~3000 rows and was killed mid-migration,
# leaving a partial DB that never got renamed. The file is renamed to `.imported`
# only on a clean import (sqlite3 exit 0, no stderr); any error preserves it for
# a retry on the next start.
st_import_history() {
  st_has_sqlite || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local hist; hist="$HOME/.claude/session-env/history.jsonl"
  [ -f "$hist" ] || return 0
  st_db_init || return 1
  local now db jqprog err rc
  now="$(date +%s)"
  db="$(st_db_path)"
  jqprog="$_ST_LIB_DIR/import-history.jq"
  [ -f "$jqprog" ] || return 1
  {
    flock 9 2>/dev/null || true
    err="$( { printf 'BEGIN;\n'; jq -R -r --argjson now "$now" -f "$jqprog" "$hist" 2>/dev/null; printf 'COMMIT;\n'; } | sqlite3 "$db" 2>&1 )"
    rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$err" ]; then
      sqlite3 "$db" "INSERT INTO meta(key,value) VALUES('history_imported_at','$now')
        ON CONFLICT(key) DO UPDATE SET value='$now';" 2>/dev/null
      mv -f "$hist" "$hist.imported" 2>/dev/null || true
    else
      return 1
    fi
  } 9>>"$hist.lock"
}
