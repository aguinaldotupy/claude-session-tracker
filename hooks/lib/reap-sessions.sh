#!/usr/bin/env bash
# reap-sessions — finalize sessions that ended without a SessionEnd event.
#
# SessionEnd is an optimization, not a guarantee: Claude Code can be killed, the
# machine can lose power, and other harnesses (opencode) have no session-end
# event at all. Everything the accounting needs is already durable in
# `events.log`, so a session can be closed from its own last event long after
# the process is gone. Without this, such a session never reaches the store and
# is never billed.
#
# The last event — not `now` — is the end timestamp: we know when the session
# was last observed working, and nothing after that. A session with no events
# has no such evidence and is skipped rather than given an invented end.
#
# Safe to run repeatedly and concurrently: st_upsert_session only overwrites a
# row whose stored end_ts is older, so a session SessionEnd already closed (or
# one that turns out to still be alive and later ends properly) keeps the
# better answer. Never blocks — always exits 0.
set -uo pipefail

_RP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_RP_DIR/db.sh" 2>/dev/null || exit 0

EXCLUDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    # `shift 2` with nothing after --exclude shifts nothing and returns 1, which
    # spins this loop forever; take one argument when that is all there is.
    --exclude) EXCLUDE="${2:-}"; if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
    *) shift ;;
  esac
done

{
  st_has_sqlite || exit 0
  ST_HOME="$(st_home)"
  [ -d "$ST_HOME" ] || exit 0

  # A session idle this long with no SessionEnd is treated as dead. Generous by
  # default: being wrong is self-correcting (a session that is actually alive
  # overwrites this row when it ends for real), but a tight threshold churns.
  STALE="${SESSION_TRACKER_STALE_SECONDS:-14400}"
  # Cheap prefilter so the sweep stays O(recent) as session dirs accumulate.
  WINDOW_DAYS="${SESSION_TRACKER_REAP_WINDOW_DAYS:-7}"
  GRACE="${SESSION_IDLE_THRESHOLD_SECONDS:-120}"

  AWK_LIB="$_RP_DIR/active-time.awk"
  [ -f "$AWK_LIB" ] || AWK_LIB="$ST_HOME/active-time.awk"
  [ -f "$AWK_LIB" ] || exit 0

  st_db_init 2>/dev/null || true
  NOW="$(date +%s)"
  reaped=0
  reaped_sids=""

  while IFS= read -r events; do
    [ -n "$events" ] || continue
    [ -s "$events" ] || continue
    sdir="$(dirname "$events")"
    sid="$(basename "$sdir")"
    [ "$sid" = "$EXCLUDE" ] && continue

    start="$(head -n1 "$sdir/session-tracker" 2>/dev/null | tr -d '[:space:]')"
    case "$start" in ''|*[!0-9]*) continue ;; esac

    # Last usable event timestamp; lines with a missing/non-numeric ts are the
    # same truncated appends active-time.awk drops, so drop them here too.
    end="$(awk 'NF>=2 && $2+0>0 {t=$2+0} END{printf "%d", t+0}' "$events" 2>/dev/null)"
    case "$end" in ''|*[!0-9]*|0) continue ;; esac
    [ "$(( NOW - end ))" -lt "$STALE" ] && continue

    # Already recorded at least this far — a real SessionEnd, or an earlier
    # sweep. st_upsert_session would reject the write anyway; skipping here
    # saves the transaction and keeps the reported count honest (it decides
    # whether the sync is worth kicking).
    known="$(sqlite3 "$(st_db_path)" \
      "SELECT COALESCE(MAX(end_ts),0) FROM sessions WHERE session_id='$(st_sql_escape "$sid")';" 2>/dev/null)"
    case "$known" in ''|*[!0-9]*) known=0 ;; esac
    [ "$known" -ge "$end" ] && continue

    dur=$(( end - start )); [ "$dur" -lt 0 ] && dur=0
    active="$(awk -v grace="$GRACE" -v t_end="$end" -f "$AWK_LIB" "$events" 2>/dev/null)"
    case "$active" in ''|*[!0-9]*) active="$dur" ;; esac
    [ "$active" -gt "$dur" ] && active="$dur"
    idle=$(( dur - active ))

    # Context SessionStart persisted for exactly this case.
    cwd="$(head -n1 "$sdir/cwd" 2>/dev/null)"
    issue="$(head -n1 "$sdir/issue-tag" 2>/dev/null | tr -d '[:space:]')"
    branch=""
    root="$cwd"
    if [ -n "$cwd" ] && [ -d "$cwd" ]; then
      root="$(st_project_root "$cwd")"
      branch="$(git -C "$cwd" branch --show-current 2>/dev/null || true)"
      if [ -z "$issue" ] && [ -n "$branch" ]; then
        issue="$(printf '%s\n' "$branch" | grep -oE '[A-Z][A-Z0-9_]+-[0-9]+' | head -n1 || true)"
      fi
    fi

    st_upsert_session "$sid" "$root" "$cwd" "$branch" "$issue" \
      "$start" "$end" "$dur" "$active" "$idle" "stale" "$NOW" 2>/dev/null \
      && { reaped=$(( reaped + 1 )); reaped_sids="$reaped_sids $sid"; }
  done <<LIST
$(find "$ST_HOME" -mindepth 2 -maxdepth 2 -name events.log -mtime "-$WINDOW_DAYS" 2>/dev/null)
LIST

  # Newly-closed sessions are new work for the sync. One `--session` run each,
  # not a plain discovery run: discovery short-circuits on any ledger that says
  # `done`, and a session reaped once, resumed, then lost again has exactly that
  # ledger -- its post-resume brackets would never be posted. `--session` forces
  # the recompute, and the per-bracket ledger keys make it a no-op when nothing
  # grew. Sequential inside one detached subshell so they queue on the sync lock
  # instead of fighting over it. Session ids never contain whitespace.
  if [ -n "$reaped_sids" ] && [ -f "$ST_HOME/solidtime-sync.sh" ] \
     && { [ -f "$ST_HOME/config.yml" ] || [ -n "${SOLIDTIME_URL:-}" ]; }; then
    ( for _sid in $reaped_sids; do
        bash "$ST_HOME/solidtime-sync.sh" --session "$_sid" >/dev/null 2>&1
      done & ) 2>/dev/null || true
  fi

  printf '%s\n' "$reaped"
} || exit 0

exit 0
