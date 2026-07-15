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

# Forensic timeline. Events come from the SQLite `events` table when present,
# else the live events.log. The awk pairs T/D per tool, flags DF (failed) and SF
# (api_error), and emits one JSON object per line; the shell wraps into intervals.
sq_timeline() {
  local sid="${1:-}" src rows
  src="$(_sq_source)"
  local ev_src=""
  if st_has_sqlite && [ -f "$(st_db_path)" ] \
     && [ "$(sqlite3 "$(st_db_path)" "SELECT COUNT(*) FROM events WHERE session_id='$(st_sql_escape "$sid")';" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
    ev_src="$(sqlite3 -separator ' ' "$(st_db_path)" "SELECT kind, ts, COALESCE(tool,'') FROM events WHERE session_id='$(st_sql_escape "$sid")' ORDER BY ts;" 2>/dev/null)"
  elif [ -f "$HOME/.claude/session-env/$sid/events.log" ]; then
    ev_src="$(cat "$HOME/.claude/session-env/$sid/events.log" 2>/dev/null)"
  fi
  rows="$(printf '%s\n' "$ev_src" | awk '
    function flush(){
      if(p>0){
        printf "{\"prompt\":%d,\"stop\":%d,\"work\":%d,\"api_error\":%s,\"tools\":[", p, (laststop>0?laststop:p), ((laststop>0?laststop:p)-p), (err?"true":"false")
        first=1
        for(t in dur){ printf "%s{\"tool\":\"%s\",\"seconds\":%d,\"failed\":%s}", (first?"":","), t, dur[t], ((t in failed)?"true":"false"); first=0 }
        printf "]}\n"
        for(t in dur) delete dur[t]; for(t in opents) delete opents[t]; for(t in failed) delete failed[t]
      }
    }
    { k=$1; ts=$2+0; tool=$3 }
    k=="P"  { flush(); p=ts; laststop=0; err=0 }
    k=="T"  { if(p>0) opents[tool]=ts }
    k=="D"  { if(p>0 && (tool in opents)){ d=ts-opents[tool]; if(d<0)d=0; dur[tool]+=d; delete opents[tool] } }
    k=="DF" { if(p>0){ if(tool in opents){ d=ts-opents[tool]; if(d<0)d=0; dur[tool]+=d; delete opents[tool] } failed[tool]=1 } }
    k=="S"  { laststop=ts }
    k=="SF" { laststop=ts; err=1 }
    END { flush() }
  ' 2>/dev/null)"
  # rows is newline-delimited JSON objects (may be empty). Assemble + add *_local.
  local arr; arr="$(printf '%s\n' "$rows" | jq -s '
    map({prompt:.prompt, prompt_local:(.prompt|strflocaltime("%H:%M")), stop:.stop, stop_local:(.stop|strflocaltime("%H:%M")),
         work_seconds:.work, api_error:.api_error, tools:.tools})' 2>/dev/null)"
  [ -z "$arr" ] && arr='[]'
  printf '%s' "$arr" | jq -e . >/dev/null 2>&1 || arr='[]'
  jq -n --arg source "$src" --argjson intervals "$arr" '{source:$source, intervals:$intervals}'
}

# Group finished sessions by issue_key; sessions with no issue_key aggregate into
# `untagged`. Same range/project filters as history.
sq_worklog() {
  local range="today" project="" src by untag
  while [ $# -gt 0 ]; do case "$1" in --range) range="$2"; shift 2 ;; --project) project="$2"; shift 2 ;; *) shift ;; esac; done
  src="$(_sq_source)"
  if [ "$src" = sqlite ]; then
    local where; where="$(_sq_sql_where "$range")"
    local pfilter="1"
    if [ -n "$project" ]; then local ep; ep="$(st_sql_escape "$project")"; pfilter="(p.project_root LIKE '%$ep%' OR s.project_dir LIKE '%$ep%')"; fi
    by="$(sqlite3 -json "$(st_db_path)" "
      SELECT s.issue_key AS issue_key, MIN(p.name) AS project, SUM(s.active_seconds) AS active_seconds, COUNT(*) AS sessions
      FROM sessions s LEFT JOIN projects p ON p.id=s.project_id
      WHERE $where AND $pfilter AND COALESCE(s.issue_key,'')<>'' GROUP BY s.issue_key ORDER BY active_seconds DESC;" 2>/dev/null)"
    untag="$(sqlite3 -json "$(st_db_path)" "
      SELECT COALESCE(SUM(s.active_seconds),0) AS active_seconds, COUNT(*) AS sessions
      FROM sessions s LEFT JOIN projects p ON p.id=s.project_id
      WHERE $where AND $pfilter AND COALESCE(s.issue_key,'')='';" 2>/dev/null)"
  elif [ "$src" = jsonl ]; then
    local rexpr f="" t="" projlc=""
    rexpr="$(_sq_jq_range "$range")"
    case "$range" in *..*) f="${range%%..*}"; t="${range##*..}" ;; esac
    [ -n "$project" ] && projlc="$(printf '%s' "$project" | tr '[:upper:]' '[:lower:]')"
    local base; base="$(jq -s --arg from "$f" --arg to "$t" --arg proj "$projlc" "
      def pmatch: (\$proj==\"\" or ((.project_dir//\"\")|ascii_downcase|contains(\$proj)));
      map(select(($rexpr) and pmatch)) | group_by(.session_id) | map(max_by(.end_ts))" "$(_sq_hist)" 2>/dev/null)"
    by="$(printf '%s' "$base" | jq 'map(select((.issue_key//"")!="")) | group_by(.issue_key)
      | map({issue_key:.[0].issue_key, project:(.[0].project_dir|split("/")|last), active_seconds:(map(.active_seconds//.duration_seconds//0)|add), sessions:length})' 2>/dev/null)"
    untag="$(printf '%s' "$base" | jq '[ .[] | select((.issue_key//"")=="") ] | {active_seconds:(map(.active_seconds//.duration_seconds//0)|add // 0), sessions:length}' 2>/dev/null)"
  fi
  [ -z "$by" ] && by='[]'; printf '%s' "$by" | jq -e . >/dev/null 2>&1 || by='[]'
  [ -z "$untag" ] && untag='{"active_seconds":0,"sessions":0}'
  # sqlite3 -json wraps untag in an array; unwrap if needed
  untag="$(printf '%s' "$untag" | jq 'if type=="array" then .[0] // {active_seconds:0,sessions:0} else . end' 2>/dev/null)"
  [ -z "$untag" ] && untag='{"active_seconds":0,"sessions":0}'
  jq -n --arg source "$src" --argjson by "$by" --argjson untagged "$untag" \
    '{source:$source, by_issue:$by, untagged:$untagged}'
}

_sq_main() {
  local cmd="${1:-}"; shift 2>/dev/null || true
  case "$cmd" in
    status)   sq_status "$@" ;;
    history)  sq_history "$@" ;;
    timeline) sq_timeline "$@" ;;
    worklog)  sq_worklog "$@" ;;
    *)        jq -n --arg source none '{source:$source,error:"unknown subcommand"}' ;;
  esac
}

_sq_main "$@" 2>/dev/null || jq -n --arg source none '{source:$source}'
