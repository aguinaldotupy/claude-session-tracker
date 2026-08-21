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
# member_id is required on time-entry create; this is how to discover it
# for a given org (see notes file "member_id" section).
_SL_API_MEMBERSHIPS="api/v1/users/me/memberships"
# ProjectStoreRequest requires color + is_billable; fixed default (not
# user-configurable, no product need for it to be).
_SL_PROJECT_COLOR="#2563eb"

VERBOSE=0
ONLY_SID=""
CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --session) ONLY_SID="${2:-}"; if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
    --verbose) VERBOSE=1; shift ;;
    --check) CHECK=1; shift ;;
    *) shift ;;
  esac
done

_sl_log() {
  printf '%s %s\n' "$(date +'%Y-%m-%dT%H:%M:%S')" "$*" >> "$_SL_LOG"
  # stderr, never stdout: resolvers (_sl_resolve_project/_sl_resolve_tag/
  # _sl_resolve_member) are invoked via command substitution and their
  # stdout IS the returned id -- an echo here would get captured as part
  # of that value on failure (e.g. project_id becoming the error string).
  [ "$VERBOSE" = 1 ] && printf '%s\n' "$*" >&2
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

# --check: one real API call (GET memberships) to prove URL/token/org reach a
# live instance -- unlike a no-op sync run (0 ended sessions => 0 HTTP calls),
# this always hits the network. Read-only, so it skips the sync lock. Also
# confirms the configured org id is actually among this token's memberships
# (same response shape _sl_resolve_member parses), since a valid token for
# the wrong org would otherwise look like success.
_sl_check() {
  local url bodyf code org_found=0
  url="${SOLIDTIME_URL%/}/$_SL_API_MEMBERSHIPS"
  bodyf="$(mktemp "${TMPDIR:-/tmp}/slbody.XXXXXX")"
  code="$(curl -sS -o "$bodyf" -w '%{http_code}' \
    -H "Authorization: Bearer $SOLIDTIME_TOKEN" -H "Accept: application/json" \
    --connect-timeout 5 --max-time 15 "$url" 2>/dev/null)"
  case "$code" in
    2*)
      if jq -e --arg org "$SOLIDTIME_ORG_ID" '.data[]? | select(.organization.id==$org)' "$bodyf" >/dev/null 2>&1; then
        org_found=1; _sl_log "check: HTTP $code"
      else
        _sl_log "ERROR check: HTTP $code org $SOLIDTIME_ORG_ID not found in memberships"
      fi
      ;;
    *)  _sl_log "ERROR check: HTTP $code $(head -c 200 "$bodyf" 2>/dev/null | tr -d '\n')" ;;
  esac
  rm -f "$bodyf"
  if [ "$VERBOSE" = 1 ]; then
    case "$code" in
      2*) if [ "$org_found" = 1 ]; then printf 'credentials OK\n'; else printf 'credentials FAILED: org not found\n'; fi ;;
      *)  printf 'credentials FAILED: HTTP %s\n' "$code" ;;
    esac
  fi
  return 0
}

# Config: solidtime.conf wins entirely when present and readable (source it,
# exactly as before). Otherwise fall back to SOLIDTIME_* already in the
# environment -- ephemeral hosts (Claude Code cloud, sandbox VMs) that
# provision secrets as env vars instead of writing a file. An unreadable
# file stays a silent no-op (not a fallback trigger -- it's a permissions
# problem, not "absent").
CONF_SOURCED=0
if [ -f "$_SL_CONF" ]; then
  [ -r "$_SL_CONF" ] || exit 0
  # shellcheck source=/dev/null
  . "$_SL_CONF" 2>/dev/null || exit 0
  CONF_SOURCED=1
fi
if [ -z "${SOLIDTIME_URL:-}" ] || [ -z "${SOLIDTIME_TOKEN:-}" ] || [ -z "${SOLIDTIME_ORG_ID:-}" ]; then
  # Nothing configured at all (no file, no SOLIDTIME_URL) stays silent --
  # unrelated environments may define stray vars. A readable-but-incomplete
  # file, or an env-only setup that got as far as SOLIDTIME_URL, is a real
  # half-done configuration worth surfacing.
  if [ "$CONF_SOURCED" = 1 ] || [ -n "${SOLIDTIME_URL:-}" ]; then
    _sl_rotate; _sl_log "ERROR config incomplete: need SOLIDTIME_URL, SOLIDTIME_TOKEN, SOLIDTIME_ORG_ID"
  fi
  exit 0
fi

_sl_rotate

# Sync watermark: the epoch at which sync first became configured on this host.
# Discovery never posts sessions that ended before it -- "no backfill of
# pre-existing history" (design non-goal). Seeded on the first configured run
# of any kind (--check included, so /sync-setup sets it), never rewritten.
_SL_SINCE_FILE="$_SL_ENV/solidtime-since"
_sl_since() {
  local v=""
  [ -f "$_SL_SINCE_FILE" ] && v="$(head -n1 "$_SL_SINCE_FILE" 2>/dev/null | tr -d '[:space:]')"
  case "$v" in
    ''|*[!0-9]*) v="$(date +%s)"; printf '%s\n' "$v" > "$_SL_SINCE_FILE" 2>/dev/null ;;
  esac
  printf '%s' "$v"
}
_SL_SINCE="$(_sl_since)"

if [ "$CHECK" = 1 ]; then
  _sl_check
  exit 0
fi

# mkdir lock (no flock on macOS); stale >10min is broken. An explicit
# --session run (SessionEnd) waits for a concurrent discovery run instead of
# skipping: it is the only trigger that force-syncs a resumed session, so a
# lost run would silently drop that session's new brackets forever.
_sl_lock_tries=1
[ -n "$ONLY_SID" ] && _sl_lock_tries=15
while ! mkdir "$_SL_LOCK" 2>/dev/null; do
  _sl_lock_tries=$((_sl_lock_tries - 1))
  if [ -n "$(find "$_SL_LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rmdir "$_SL_LOCK" 2>/dev/null || rm -rf "$_SL_LOCK" 2>/dev/null
    _sl_log "broke stale lock"
    [ "$_sl_lock_tries" -le -5 ] && { _sl_log "lock held, skipping run"; exit 0; }
    continue
  fi
  if [ "$_sl_lock_tries" -le 0 ]; then _sl_log "lock held, skipping run"; exit 0; fi
  sleep 2
done
trap 'rmdir "$_SL_LOCK" 2>/dev/null' EXIT

. "$_SL_ENV/db.sh" 2>/dev/null || true

_sl_log "sync run start (session=${ONLY_SID:-auto})"

_sl_cache_get() { jq -r --arg k "$2" ".$1[\$k] // empty" "$_SL_CACHE" 2>/dev/null; }
_sl_cache_put() {
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/slcache.XXXXXX")"
  jq --arg k "$2" --arg v "$3" ".$1[\$k] = \$v" "$_SL_CACHE" 2>/dev/null > "$tmp" \
    || jq -n --arg k "$2" --arg v "$3" "{projects:{},tags:{}} | .$1[\$k] = \$v" > "$tmp"
  mv "$tmp" "$_SL_CACHE"
}
_sl_cache_get_member() { jq -r '.member_id // empty' "$_SL_CACHE" 2>/dev/null; }
_sl_cache_put_member() {
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/slcache.XXXXXX")"
  jq --arg v "$1" '.member_id = $v' "$_SL_CACHE" 2>/dev/null > "$tmp" \
    || jq -n --arg v "$1" '{projects:{},tags:{},member_id:$v}' > "$tmp"
  mv "$tmp" "$_SL_CACHE"
}

# GET list, find by name; POST create on miss. Args: kind(projects|tags) api_fmt name
_sl_resolve() {
  local kind="$1" fmt="$2" name="$3" id url bodyf code payload
  [ -z "$name" ] && return 0
  id="$(_sl_cache_get "$kind" "$name")"
  if [ -n "$id" ]; then printf '%s' "$id"; return 0; fi
  # shellcheck disable=SC2059
  url="${SOLIDTIME_URL%/}/$(printf "$fmt" "$SOLIDTIME_ORG_ID")"
  bodyf="$(mktemp "${TMPDIR:-/tmp}/slbody.XXXXXX")"
  code="$(curl -sS -o "$bodyf" -w '%{http_code}' \
    -H "Authorization: Bearer $SOLIDTIME_TOKEN" -H "Accept: application/json" \
    --connect-timeout 5 --max-time 15 "$url" 2>/dev/null)"
  case "$code" in 2*) id="$(jq -r --arg n "$name" '.data[]? | select(.name==$n) | .id' "$bodyf" 2>/dev/null | head -n1)" ;; esac
  if [ -z "$id" ]; then
    # ProjectStoreRequest requires color + is_billable (verified API delta);
    # TagStoreRequest needs name only.
    if [ "$kind" = "projects" ]; then
      # client_id must be PRESENT (null is accepted) -- confirmed via live
      # E2E against app.solidtime.io 2026-08-21; omitting it 422s.
      payload="$(jq -nc --arg n "$name" --arg c "$_SL_PROJECT_COLOR" '{name:$n, color:$c, is_billable:false, client_id:null}')"
    else
      payload="$(jq -nc --arg n "$name" '{name:$n}')"
    fi
    code="$(curl -sS -o "$bodyf" -w '%{http_code}' -X POST "$url" \
      -H "Authorization: Bearer $SOLIDTIME_TOKEN" -H "Content-Type: application/json" -H "Accept: application/json" \
      --connect-timeout 5 --max-time 15 \
      -d "$payload" 2>/dev/null)"
    case "$code" in 2*) id="$(jq -r '.data.id // empty' "$bodyf" 2>/dev/null)" ;;
      *) _sl_log "ERROR resolve $kind '$name': HTTP $code $(head -c 200 "$bodyf" | tr -d '\n')" ;;
    esac
  fi
  rm -f "$bodyf"
  [ -n "$id" ] && _sl_cache_put "$kind" "$name" "$id" && printf '%s' "$id"
  return 0
}

_sl_resolve_project() { _sl_resolve projects "$_SL_API_PROJECTS" "$1"; }
_sl_resolve_tag()     { _sl_resolve tags     "$_SL_API_TAGS"     "$1"; }

# member_id: config wins; else cache; else GET memberships and match this
# session's org id (controller ruling, Task 6). Empty on any failure --
# _sl_sync_session treats that as fatal (member_id is required on every
# time-entry create call). Never writes $_SL_CONF -- only the local cache.
_sl_resolve_member() {
  local id url bodyf code
  if [ -n "${SOLIDTIME_MEMBER_ID:-}" ]; then printf '%s' "$SOLIDTIME_MEMBER_ID"; return 0; fi
  id="$(_sl_cache_get_member)"
  if [ -n "$id" ]; then printf '%s' "$id"; return 0; fi
  url="${SOLIDTIME_URL%/}/$_SL_API_MEMBERSHIPS"
  bodyf="$(mktemp "${TMPDIR:-/tmp}/slbody.XXXXXX")"
  code="$(curl -sS -o "$bodyf" -w '%{http_code}' \
    -H "Authorization: Bearer $SOLIDTIME_TOKEN" -H "Accept: application/json" \
    --connect-timeout 5 --max-time 15 "$url" 2>/dev/null)"
  case "$code" in 2*) id="$(jq -r --arg org "$SOLIDTIME_ORG_ID" '.data[]? | select(.organization.id==$org) | .id' "$bodyf" 2>/dev/null | head -n1)" ;; esac
  rm -f "$bodyf"
  [ -n "$id" ] && _sl_cache_put_member "$id"
  printf '%s' "$id"
  return 0
}

# POST one time entry. Args: start_iso end_iso description project_id tag_id
# Prints HTTP code; body (for error logging) lands in $_SL_BODY.
# Deliberately no curl --retry: creates are not idempotent server-side, and
# curl retries 5xx/timeouts -- a request the server accepted but whose reply
# was lost would be re-sent as a second time entry. Transient failures are
# retried at the next trigger instead (nothing is written to the ledger).
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
    --connect-timeout 5 --max-time 30 \
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
  fi
  # Not `elif`: both stores can coexist (a SessionEnd whose sqlite upsert failed
  # appends to history.jsonl even though history.db exists), so a miss in one
  # must still consult the other.
  if [ -z "$name" ] && [ -f "$_SL_ENV/history.jsonl" ]; then
    name="$(jq -r --arg s "$sid" 'select(.session_id==$s) | .project_dir' "$_SL_ENV/history.jsonl" 2>/dev/null | tail -n1 | awk -F/ '{print $NF}')"
  fi
  [ -n "$name" ] && printf '%s' "$name" || basename "${PWD:-unknown}"
}

# Terminal epoch for bracket computation: the session's recorded end_ts, NOT
# `now`. A retry days later (instance down, sqlite fallback, lost lock) would
# otherwise close a session that ended mid-tool-call — its last engagement
# still open — at the current time and post a multi-day time entry. Falls back
# to now only when the store has no end_ts (session not yet recorded).
_sl_session_end_ts() {
  local sid="$1" ts=""
  if command -v st_has_sqlite >/dev/null 2>&1 && st_has_sqlite && [ -f "$(st_db_path)" ]; then
    ts="$(sqlite3 "$(st_db_path)" "SELECT COALESCE(end_ts,'') FROM sessions WHERE session_id='$(st_sql_escape "$sid")';" 2>/dev/null)"
  fi
  # Not `elif`: a session whose sqlite upsert failed lives only in the JSONL
  # even on a host that has history.db. Missing it here would silently fall
  # back to `now` and post a multi-day entry on a delayed retry.
  if [ -z "$ts" ] && [ -f "$_SL_ENV/history.jsonl" ]; then
    ts="$(jq -r --arg s "$sid" 'select(.session_id==$s) | .end_ts' "$_SL_ENV/history.jsonl" 2>/dev/null | tail -n1)"
  fi
  case "$ts" in ''|*[!0-9]*) date +%s ;; *) printf '%s' "$ts" ;; esac
}

# Sync one finished session: post every bracket not yet in the ledger.
# Args: sid [force] -- force (used only by the explicit --session path) skips
# the 'done' short-circuit so a session resumed after a prior sync still
# posts its new post-resume brackets (session_id is stable across resume).
# Discovery (no --session) keeps the cheap prefilter.
#
# Ledger lines are "<bracket_start> <bracket_end>" epochs, NOT ordinals: a
# bracket's END is not stable across a resume. A session that ended with an
# engagement still open (quit mid-response: last event T/D with no S) has its
# final bracket recorded as [start, end_ts]; when the session is resumed the
# same bracket absorbs every resumed event and grows. Keyed by ordinal, that
# bracket looked "already posted" and all resumed work was dropped. Keyed by
# start, a grown bracket posts a continuation entry [posted_end, new_end], so
# the total still equals the session's active seconds.
_sl_sync_session() {
  local sid="$1" force="${2:-}"
  local sdir="$_SL_ENV/$sid" ledger events issue host proj tag
  events="$sdir/events.log"; ledger="$sdir/solidtime-synced"
  if [ ! -f "$events" ]; then
    mkdir -p "$sdir"
    printf 'done\n' >> "$ledger"
    _sl_log "session $sid: no events.log, marking done"
    return 0
  fi
  [ "$force" = "force" ] || { grep -q '^done$' "$ledger" 2>/dev/null && return 0; }
  # member_id is required on every time-entry create call (API delta over the
  # design draft). SOLIDTIME_MEMBER_ID from config wins if set; otherwise
  # auto-resolve via GET memberships and cache the result (controller
  # ruling, Task 6). Still fail loudly and post nothing if that also comes
  # up empty.
  SOLIDTIME_MEMBER_ID="$(_sl_resolve_member)"
  if [ -z "${SOLIDTIME_MEMBER_ID:-}" ]; then
    _sl_log "ERROR member_id missing (set SOLIDTIME_MEMBER_ID or run sync-setup)"
    return 1
  fi
  issue=""; [ -f "$sdir/issue-tag" ] && issue="$(head -n1 "$sdir/issue-tag" | tr -d '[:space:]')"
  host="$(hostname 2>/dev/null || echo unknown)"
  proj="$(_sl_resolve_project "$(_sl_session_project "$sid")")"
  tag=""; [ -n "$issue" ] && tag="$(_sl_resolve_tag "$issue")"
  local now idx=0 posted=0 start end from prev code
  now="$(_sl_session_end_ts "$sid")"
  while read -r start end; do
    [ -z "$start" ] && continue
    # Last end already posted for this bracket start, if any.
    prev="$(grep "^$start " "$ledger" 2>/dev/null | tail -n1 | cut -d' ' -f2)"
    from="$start"
    if [ -n "$prev" ]; then
      [ "$prev" -ge "$end" ] && { idx=$((idx + 1)); continue; }
      from="$prev"   # bracket grew after a resume: post only the new tail
    fi
    code="$(_sl_post_entry "$(_sl_iso8601 "$from")" "$(_sl_iso8601 "$end")" \
              "$host · ${sid%%-*}:${idx}" "$proj" "$tag")"
    case "$code" in
      2*) printf '%s %s\n' "$start" "$end" >> "$ledger"; posted=$((posted + 1)) ;;
      *)  _sl_log "ERROR session $sid bracket $idx: HTTP $code ${_SL_BODY}"; return 1 ;;
    esac
    idx=$((idx + 1))
  done <<EOF
$(awk -v grace="${SESSION_IDLE_THRESHOLD_SECONDS:-120}" -v t_end="$now" -v mode=brackets \
     -f "$_SL_ENV/active-time.awk" "$events" 2>/dev/null)
EOF
  printf 'done\n' >> "$ledger"
  _sl_log "session $sid: synced $posted brackets"
  return 0
}

# Sessions eligible for discovery: only those that ended at or after the sync
# watermark. Without the filter, enabling sync on a host with months of local
# history would post every one of those sessions to Solidtime on the first run.
_sl_pending_sids() {
  # Union, not either/or: both stores can hold sessions at once (a SessionEnd
  # whose sqlite upsert failed appends to history.jsonl even on a host that has
  # history.db) and a JSONL-only session must still be discoverable.
  {
    if command -v st_has_sqlite >/dev/null 2>&1 && st_has_sqlite && [ -f "$(st_db_path)" ]; then
      sqlite3 "$(st_db_path)" "SELECT session_id FROM sessions WHERE end_ts >= $_SL_SINCE ORDER BY end_ts;" 2>/dev/null
    fi
    if [ -f "$_SL_ENV/history.jsonl" ]; then
      jq -r --argjson since "$_SL_SINCE" 'select(.end_ts >= $since) | .session_id' "$_SL_ENV/history.jsonl" 2>/dev/null
    fi
  } | awk 'NF && !seen[$0]++'
}

if [ -n "$ONLY_SID" ]; then
  _sl_sync_session "$ONLY_SID" force || true
else
  while IFS= read -r sid; do
    [ -z "$sid" ] && continue
    grep -q '^done$' "$_SL_ENV/$sid/solidtime-synced" 2>/dev/null && continue
    _sl_sync_session "$sid" || true
  done <<EOF
$(_sl_pending_sids)
EOF
fi

_sl_log "sync run end"
exit 0
