#!/usr/bin/env bash
# Idempotent migration of the legacy history.jsonl into SQLite. Sourceable.
# Safe to run repeatedly: upsert by session_id means re-runs never duplicate.

_ST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_ST_LIB_DIR/db.sh"

st_import_history() {
  st_has_sqlite || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local hist; hist="$HOME/.claude/session-env/history.jsonl"
  [ -f "$hist" ] || return 0
  jq empty "$hist" 2>/dev/null || return 1
  st_db_init || return 1
  local now; now="$(date +%s)"

  # Emit one TSV row per line: sid, project_dir, active, dur, idle, start, end, issue, reason.
  # Legacy rows: project_root := project_dir, branch := NULL, active := active // duration // 0.
  # Flock so parallel SessionStart runs don't both import (upsert makes it harmless anyway).
  # All-or-nothing: only rename the file to .imported if every upsert succeeded.
  {
    flock 9 2>/dev/null || true
    local fail=0
    while IFS=$'\t' read -r sid dir active dur idle start end issue reason; do
      [ -z "$sid" ] && continue
      # branch NULL for legacy → pass empty string; root := dir
      st_upsert_session "$sid" "$dir" "$dir" "" "$issue" "$start" "$end" "$dur" "$active" "$idle" "$reason" "$now" || fail=1
    done < <(jq -rc '[.session_id, (.project_dir // ""), (.active_seconds // .duration_seconds // 0),
             (.duration_seconds // 0), (.idle_seconds // 0), (.start_ts // 0), (.end_ts // 0),
             (.issue_key // ""), (.reason // "")] | @tsv' "$hist" 2>/dev/null)
    if [ "$fail" -eq 0 ]; then
      sqlite3 "$(st_db_path)" "INSERT INTO meta(key,value) VALUES('history_imported_at','$now')
        ON CONFLICT(key) DO UPDATE SET value='$now';" 2>/dev/null
      mv -f "$hist" "$hist.imported" 2>/dev/null || true
    else
      return 1
    fi
  } 9>>"$hist.lock"
}
