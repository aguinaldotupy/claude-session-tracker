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

# SQL WHERE fragment (on start_ts) for a --range value. Portable: SQLite date().
_sq_sql_where() {
  case "$1" in
    today)     echo "date(start_ts,'unixepoch','localtime')=date('now','localtime')" ;;
    yesterday) echo "date(start_ts,'unixepoch','localtime')=date('now','-1 day','localtime')" ;;
    7d)        echo "date(start_ts,'unixepoch','localtime')>=date('now','-6 days','localtime')" ;;
    30d)       echo "date(start_ts,'unixepoch','localtime')>=date('now','-29 days','localtime')" ;;
    *..*)      local f="${1%%..*}" t="${1##*..}"
               f="$(st_sql_escape "$f")"; t="$(st_sql_escape "$t")"
               echo "date(start_ts,'unixepoch','localtime') BETWEEN date('$f') AND date('$t')" ;;
    *)         echo "date(start_ts,'unixepoch','localtime')=date('now','localtime')" ;;
  esac
}

# jq boolean on . for the JSONL fallback. Uses local date strings (portable).
_sq_jq_range() {
  case "$1" in
    today)     echo '(.start_ts|strflocaltime("%Y-%m-%d")) == (now|strflocaltime("%Y-%m-%d"))' ;;
    yesterday) echo '(.start_ts|strflocaltime("%Y-%m-%d")) == ((now-86400)|strflocaltime("%Y-%m-%d"))' ;;
    7d)        echo '(.start_ts|strflocaltime("%Y-%m-%d")) >= ((now-6*86400)|strflocaltime("%Y-%m-%d"))' ;;
    30d)       echo '(.start_ts|strflocaltime("%Y-%m-%d")) >= ((now-29*86400)|strflocaltime("%Y-%m-%d"))' ;;
    *..*)      echo '(.start_ts|strflocaltime("%Y-%m-%d")) >= $from and (.start_ts|strflocaltime("%Y-%m-%d")) <= $to' ;;
    *)         echo '(.start_ts|strflocaltime("%Y-%m-%d")) == (now|strflocaltime("%Y-%m-%d"))' ;;
  esac
}

sq_history() {
  local range="today" project="" src rows total count
  while [ $# -gt 0 ]; do case "$1" in --range) range="$2"; shift 2 ;; --project) project="$2"; shift 2 ;; *) shift ;; esac; done
  src="$(_sq_source)"
  if [ "$src" = sqlite ]; then
    local where; where="$(_sq_sql_where "$range")"
    local pfilter="1"
    if [ -n "$project" ]; then local ep; ep="$(st_sql_escape "$project")"; pfilter="(p.project_root LIKE '%$ep%' OR s.project_dir LIKE '%$ep%')"; fi
    rows="$(sqlite3 -json "$(st_db_path)" "
      SELECT s.start_ts AS start,
             strftime('%H:%M', s.start_ts,'unixepoch','localtime') AS start_local,
             s.end_ts AS end,
             strftime('%H:%M', s.end_ts,'unixepoch','localtime') AS end_local,
             s.active_seconds AS active_seconds,
             p.name AS project,
             COALESCE(NULLIF(s.issue_key,''),NULLIF(s.branch,''),'—') AS branch_issue
      FROM sessions s LEFT JOIN projects p ON p.id=s.project_id
      WHERE $where AND $pfilter ORDER BY s.start_ts;" 2>/dev/null)"
    [ -z "$rows" ] && rows='[]'
  elif [ "$src" = jsonl ]; then
    local rexpr f="" t="" projlc=""
    rexpr="$(_sq_jq_range "$range")"
    case "$range" in *..*) f="${range%%..*}"; t="${range##*..}" ;; esac
    [ -n "$project" ] && projlc="$(printf '%s' "$project" | tr '[:upper:]' '[:lower:]')"
    rows="$(jq -s --arg from "$f" --arg to "$t" --arg proj "$projlc" "
      def pmatch: (\$proj==\"\" or ((.project_dir//\"\")|ascii_downcase|contains(\$proj)));
      map(select(($rexpr) and pmatch)) | group_by(.session_id) | map(max_by(.end_ts))
      | map({start:.start_ts, start_local:(.start_ts|strflocaltime(\"%H:%M\")), end:.end_ts, end_local:(.end_ts|strflocaltime(\"%H:%M\")),
             active_seconds:(.active_seconds // .duration_seconds // 0), project:((.project_dir//\"\")|split(\"/\")|last),
             branch_issue:(if (.issue_key//\"\")!=\"\" then .issue_key elif (.branch//\"\")!=\"\" then .branch else \"—\" end)})" "$(_sq_hist)" 2>/dev/null)"
    [ -z "$rows" ] && rows='[]'
  else
    rows='[]'
  fi
  printf '%s' "$rows" | jq -e . >/dev/null 2>&1 || rows='[]'
  total="$(printf '%s' "$rows" | jq '[.[].active_seconds]|add // 0')"
  count="$(printf '%s' "$rows" | jq 'length')"
  jq -n --arg source "$src" --argjson rows "$rows" --argjson total "$total" --argjson count "$count" \
    '{source:$source, total_active_seconds:$total, count:$count, rows:$rows}'
}

_sq_main() {
  local cmd="${1:-}"; shift 2>/dev/null || true
  case "$cmd" in
    status)   sq_status "$@" ;;
    history)  sq_history "$@" ;;
    *)        jq -n --arg source none '{source:$source,error:"unknown subcommand"}' ;;
  esac
}

_sq_main "$@" 2>/dev/null || jq -n --arg source none '{source:$source}'
