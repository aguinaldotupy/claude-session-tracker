#!/usr/bin/env bash
# session-query — read-only CLI for session-tracker. Emits JSON on stdout, always
# exits 0, never leaks stderr to the caller. Sources db.sh for shared helpers.
set -uo pipefail

_SQ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_SQ_DIR/db.sh"

_sq_hist() { printf '%s/.claude/session-env/history.jsonl' "$HOME"; }

# Which store is authoritative right now. While history.jsonl exists (migration
# pending or sqlite3 absent) the deduped JSONL is the complete source; otherwise
# SQLite; otherwise nothing.
_sq_source() {
  if [ -f "$(_sq_hist)" ] && command -v jq >/dev/null 2>&1; then echo jsonl
  elif st_has_sqlite && [ -f "$(st_db_path)" ]; then echo sqlite
  else echo none; fi
}

_sq_int() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

sq_status() {
  local sid="" now sdir start_ts live_elapsed live_active issue src
  while [ $# -gt 0 ]; do case "$1" in --session) sid="$2"; shift 2 ;; *) shift ;; esac; done
  [ -z "$sid" ] && sid="${CLAUDE_SESSION_ID:-}"
  now="$(date +%s)"
  src="$(_sq_source)"
  sdir="$HOME/.claude/session-env/$sid"
  start_ts=0; live_elapsed=0; live_active=0; issue=""
  if [ -n "$sid" ] && [ -f "$sdir/session-tracker" ]; then
    start_ts="$(_sq_int "$(cat "$sdir/session-tracker" 2>/dev/null)")"
    [ "$start_ts" -gt 0 ] && live_elapsed=$((now - start_ts))
    local awk_lib="$HOME/.claude/session-env/active-time.awk"
    if [ -f "$sdir/events.log" ] && [ -f "$awk_lib" ]; then
      live_active="$(_sq_int "$(awk -v grace="${SESSION_IDLE_THRESHOLD_SECONDS:-120}" -v t_end="$now" -f "$awk_lib" "$sdir/events.log" 2>/dev/null)")"
    fi
    [ -f "$sdir/issue-tag" ] && issue="$(head -n1 "$sdir/issue-tag" 2>/dev/null | tr -d '[:space:]')"
  fi
  local tsecs=0 tcount=0
  if [ "$src" = sqlite ]; then
    IFS='|' read -r tsecs tcount <<EOF
$(sqlite3 -separator '|' "$(st_db_path)" "SELECT COALESCE(SUM(active_seconds),0), COUNT(*) FROM sessions WHERE date(start_ts,'unixepoch','localtime')=date('now','localtime');" 2>/dev/null)
EOF
  elif [ "$src" = jsonl ]; then
    tsecs="$(jq -s 'map(select((.start_ts|strflocaltime("%Y-%m-%d"))==(now|strflocaltime("%Y-%m-%d")))) | group_by(.session_id) | map(max_by(.end_ts).active_seconds) | add // 0' "$(_sq_hist)" 2>/dev/null)"
    tcount="$(jq -s 'map(select((.start_ts|strflocaltime("%Y-%m-%d"))==(now|strflocaltime("%Y-%m-%d")))) | group_by(.session_id) | length' "$(_sq_hist)" 2>/dev/null)"
  fi
  tsecs="$(_sq_int "$tsecs")"; tcount="$(_sq_int "$tcount")"
  jq -n --arg source "$src" --argjson elapsed "$live_elapsed" --argjson active "$live_active" \
        --argjson started "$start_ts" --arg issue "$issue" --argjson tsecs "$tsecs" --argjson tcount "$tcount" \
    '{source:$source, live:{elapsed_seconds:$elapsed, active_seconds:$active, started_at:$started, issue_key:$issue}, today:{active_seconds:$tsecs, sessions:$tcount}}'
}

_sq_main() {
  local cmd="${1:-}"; shift 2>/dev/null || true
  case "$cmd" in
    status)   sq_status "$@" ;;
    *)        jq -n --arg source none '{source:$source,error:"unknown subcommand"}' ;;
  esac
}

_sq_main "$@" 2>/dev/null || jq -n --arg source none '{source:$source}'
