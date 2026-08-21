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

# --- Solidtime API surface (verified/corrected in the API-notes task; keep
# every path and field name in this block and the _sl_api_* helpers only) ---
_SL_API_ENTRIES="api/v1/organizations/%s/time-entries"
_SL_API_PROJECTS="api/v1/organizations/%s/projects"
_SL_API_TAGS="api/v1/organizations/%s/tags"
_SL_API_ME="api/v1/users/me"

VERBOSE=0
ONLY_SID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session) ONLY_SID="${2:-}"; shift 2 ;;
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
# shellcheck source=/dev/null
. "$_SL_CONF"
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
# Sessions sync in later tasks; skeleton ends here.
_sl_log "sync run end"
exit 0
