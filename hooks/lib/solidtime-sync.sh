#!/usr/bin/env bash
# solidtime-sync — post finished sessions' active brackets to a Solidtime
# instance as time entries. Local-first: safe to kill at any point; an
# incremental per-session ledger makes re-runs idempotent. Never prints to
# stdout/stderr unless --verbose; errors always go to the sync log.
set -uo pipefail

_SL_ENV="$HOME/.claude/session-env"
_SL_CONF="$_SL_ENV/solidtime.conf"
_SL_LOG="$_SL_ENV/solidtime-sync.log"
_SL_LOCK="$_SL_ENV/solidtime-sync.lock"
_SL_CACHE="$_SL_ENV/solidtime-cache.json"

# --- Solidtime API surface (verified against https://api-docs.solidtime.io/
# api-docs.json on 2026-08-21; see docs/superpowers/specs/
# 2026-08-21-solidtime-api-notes.md. Keep every path and field name in this
# block and the _sl_api_* helpers only) ---
_SL_API_ENTRIES="api/v1/organizations/%s/time-entries"
_SL_API_PROJECTS="api/v1/organizations/%s/projects"
_SL_API_TAGS="api/v1/organizations/%s/tags"
_SL_API_ME="api/v1/users/me"
# member_id is required on time-entry create; this is how to discover it
# for a given org (see notes file "member_id" section).
_SL_API_MEMBERSHIPS="api/v1/users/me/memberships"

VERBOSE=0
ONLY_SID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session) ONLY_SID="${2:-}"; if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
    --verbose) VERBOSE=1; shift ;;
    *) shift ;;
  esac
done

_sl_log() {
  printf '%s %s\n' "$(date +'%Y-%m-%dT%H:%M:%S')" "$*" >> "$_SL_LOG"
  [ "$VERBOSE" = 1 ] && printf '%s\n' "$*"
  return 0
}

# Epoch → UTC ISO8601. BSD date first (macOS), GNU fallback.
_sl_iso8601() {
  date -u -r "$1" +%FT%TZ 2>/dev/null || date -u -d "@$1" +%FT%TZ
}

# Rotate log: over 500 lines → keep last 250.
_sl_rotate() {
  [ -f "$_SL_LOG" ] || return 0
  local n; n=$(wc -l < "$_SL_LOG" | tr -d ' ')
  if [ "${n:-0}" -gt 500 ]; then
    tail -n 250 "$_SL_LOG" > "$_SL_LOG.tmp" && mv "$_SL_LOG.tmp" "$_SL_LOG"
  fi
}

# No config → silently inactive. This is the supported "feature off" state.
[ -f "$_SL_CONF" ] || exit 0
[ -r "$_SL_CONF" ] || exit 0
# shellcheck source=/dev/null
. "$_SL_CONF" 2>/dev/null || exit 0
if [ -z "${SOLIDTIME_URL:-}" ] || [ -z "${SOLIDTIME_TOKEN:-}" ] || [ -z "${SOLIDTIME_ORG_ID:-}" ]; then
  _sl_rotate; _sl_log "ERROR config incomplete: need SOLIDTIME_URL, SOLIDTIME_TOKEN, SOLIDTIME_ORG_ID"
  exit 0
fi

_sl_rotate

# mkdir lock (no flock on macOS); stale >10min is broken.
if ! mkdir "$_SL_LOCK" 2>/dev/null; then
  if [ -n "$(find "$_SL_LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rmdir "$_SL_LOCK" 2>/dev/null || rm -rf "$_SL_LOCK" 2>/dev/null
    mkdir "$_SL_LOCK" 2>/dev/null || { _sl_log "lock held after stale-break, skipping run"; exit 0; }
    _sl_log "broke stale lock"
  else
    _sl_log "lock held, skipping run"
    exit 0
  fi
fi
trap 'rmdir "$_SL_LOCK" 2>/dev/null' EXIT

. "$_SL_ENV/db.sh" 2>/dev/null || true

_sl_log "sync run start (session=${ONLY_SID:-auto})"

# Placeholder resolvers until the cache task lands: no project/tag ids.
_sl_resolve_project() { printf ''; }
_sl_resolve_tag() { printf ''; }

# POST one time entry. Args: start_iso end_iso description project_id tag_id
# Prints HTTP code; body (for error logging) lands in $_SL_BODY.
_SL_BODY=""
_sl_post_entry() {
  local start="$1" end="$2" desc="$3" proj="$4" tag="$5"
  local url payload bodyf code
  # shellcheck disable=SC2059
  url="${SOLIDTIME_URL%/}/$(printf "$_SL_API_ENTRIES" "$SOLIDTIME_ORG_ID")"
  # member_id is required on every time-entry create call (verified API
  # contract); _sl_sync_session guarantees SOLIDTIME_MEMBER_ID is non-empty
  # before ever calling this. tags (not tag_ids) is the array field name.
  payload="$(jq -nc --arg s "$start" --arg e "$end" --arg d "$desc" \
                  --arg p "$proj" --arg t "$tag" --arg m "${SOLIDTIME_MEMBER_ID:-}" '
    {start:$s, end:$e, description:$d, billable:false, member_id:$m}
    + (if $p != "" then {project_id:$p} else {} end)
    + (if $t != "" then {tags:[$t]} else {} end)')"
  bodyf="$(mktemp "${TMPDIR:-/tmp}/slbody.XXXXXX")"
  code="$(curl -sS -o "$bodyf" -w '%{http_code}' \
    -X POST "$url" \
    -H "Authorization: Bearer $SOLIDTIME_TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    --connect-timeout 5 --max-time 30 --retry 2 --retry-delay 2 \
    -d "$payload" 2>/dev/null)"
  _SL_BODY="$(head -c 300 "$bodyf" 2>/dev/null | tr -d '\n')"
  rm -f "$bodyf"
  printf '%s' "${code:-000}"
}

# Project NAME for a session, from the history store (the hook's cwd is NOT
# the session's project on retry runs). Falls back to the current dir's name.
_sl_session_project() {
  local sid="$1" name=""
  if command -v st_has_sqlite >/dev/null 2>&1 && st_has_sqlite && [ -f "$(st_db_path)" ]; then
    name="$(sqlite3 "$(st_db_path)" "SELECT COALESCE(p.name, '') FROM sessions s LEFT JOIN projects p ON p.id=s.project_id WHERE s.session_id='$(st_sql_escape "$sid")';" 2>/dev/null)"
  elif [ -f "$_SL_ENV/history.jsonl" ]; then
    name="$(jq -r --arg s "$sid" 'select(.session_id==$s) | .project_dir' "$_SL_ENV/history.jsonl" 2>/dev/null | tail -n1 | awk -F/ '{print $NF}')"
  fi
  [ -n "$name" ] && printf '%s' "$name" || basename "${PWD:-unknown}"
}

# Sync one finished session: post every bracket not yet in the ledger.
_sl_sync_session() {
  local sid="$1"
  local sdir="$_SL_ENV/$sid" ledger events issue host proj tag
  events="$sdir/events.log"; ledger="$sdir/solidtime-synced"
  [ -f "$events" ] || { _sl_log "session $sid: no events.log, skipping"; return 0; }
  grep -q '^done$' "$ledger" 2>/dev/null && return 0
  # member_id is required on every time-entry create call (API delta over the
  # design draft). No runtime auto-resolution here (later task); fail loudly
  # and do not post anything for this session.
  if [ -z "${SOLIDTIME_MEMBER_ID:-}" ]; then
    _sl_log "ERROR member_id missing (set SOLIDTIME_MEMBER_ID or run sync-setup)"
    return 1
  fi
  issue=""; [ -f "$sdir/issue-tag" ] && issue="$(head -n1 "$sdir/issue-tag" | tr -d '[:space:]')"
  host="$(hostname 2>/dev/null || echo unknown)"
  proj="$(_sl_resolve_project "$(_sl_session_project "$sid")")"
  tag=""; [ -n "$issue" ] && tag="$(_sl_resolve_tag "$issue")"
  local now idx=0 start end code
  now="$(date +%s)"
  while read -r start end; do
    [ -z "$start" ] && continue
    if ! grep -qx "$idx" "$ledger" 2>/dev/null; then
      code="$(_sl_post_entry "$(_sl_iso8601 "$start")" "$(_sl_iso8601 "$end")" \
                "$host · ${sid%%-*}:${idx}" "$proj" "$tag")"
      case "$code" in
        2*) printf '%s\n' "$idx" >> "$ledger" ;;
        *)  _sl_log "ERROR session $sid bracket $idx: HTTP $code ${_SL_BODY}"; return 1 ;;
      esac
    fi
    idx=$((idx + 1))
  done <<EOF
$(awk -v grace="${SESSION_IDLE_THRESHOLD_SECONDS:-120}" -v t_end="$now" -v mode=brackets \
     -f "$_SL_ENV/active-time.awk" "$events" 2>/dev/null)
EOF
  printf 'done\n' >> "$ledger"
  _sl_log "session $sid: synced $idx brackets"
  return 0
}

if [ -n "$ONLY_SID" ]; then
  _sl_sync_session "$ONLY_SID" || true
fi

_sl_log "sync run end"
exit 0
