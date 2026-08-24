#!/usr/bin/env bash
# reap-sessions: finalize sessions that died without a SessionEnd (crash, kill,
# or a harness that has no session-end event at all).
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$DIR/.."

command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 missing — skipping"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
unset SESSION_TRACKER_HOME SESSION_TRACKER_STALE_SECONDS
ENV_DIR="$TMP/.session-tracker"
DB="$ENV_DIR/history.db"
REAP="$ROOT/hooks/lib/reap-sessions.sh"
now=$(date +%s)

mk() {  # mk <sid> <start> <last_event_ts>
  local sd="$ENV_DIR/$1"; mkdir -p "$sd"
  echo "$2" > "$sd/session-tracker"
  printf 'P %s\nS %s\n' "$2" "$3" > "$sd/events.log"
  printf '%s' "$sd"
}

. "$ROOT/hooks/lib/db.sh"
st_db_init

# --- a stale session is finalized from its own last event, not from `now` ---
mk stale-1 1000 1060 >/dev/null
bash "$REAP" >/dev/null
assert_eq "stale session recorded" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE session_id='stale-1';")"
assert_eq "end_ts is the last event, not now" "1060" "$(sqlite3 "$DB" "SELECT end_ts FROM sessions WHERE session_id='stale-1';")"
assert_eq "duration spans start..last event" "60" "$(sqlite3 "$DB" "SELECT duration_seconds FROM sessions WHERE session_id='stale-1';")"
assert_eq "active time computed from events" "60" "$(sqlite3 "$DB" "SELECT active_seconds FROM sessions WHERE session_id='stale-1';")"
assert_eq "reason marks it swept" "stale" "$(sqlite3 "$DB" "SELECT reason FROM sessions WHERE session_id='stale-1';")"

# --- a session still inside the staleness window is left alone ---
mk live-1 "$((now - 300))" "$((now - 30))" >/dev/null
bash "$REAP" >/dev/null
assert_eq "recent session not reaped" "0" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE session_id='live-1';")"

# --- the caller's own session is never reaped, however stale it looks ---
mk mine-1 1000 1060 >/dev/null
bash "$REAP" --exclude mine-1 >/dev/null
assert_eq "excluded session not reaped" "0" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE session_id='mine-1';")"

# --- no events means no evidence of when it ended: skip rather than invent one ---
mkdir -p "$ENV_DIR/empty-1"; echo 1000 > "$ENV_DIR/empty-1/session-tracker"
bash "$REAP" >/dev/null
assert_eq "session without events not reaped" "0" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE session_id='empty-1';")"

# --- a session SessionEnd already closed keeps its own, later end_ts ---
mk closed-1 1000 1060 >/dev/null
st_upsert_session closed-1 /p/x /p/x "" "" 1000 9000 8000 4000 4000 exit "$now"
bash "$REAP" >/dev/null
assert_eq "properly-ended session keeps its end_ts" "9000" "$(sqlite3 "$DB" "SELECT end_ts FROM sessions WHERE session_id='closed-1';")"
assert_eq "properly-ended session keeps its reason" "exit" "$(sqlite3 "$DB" "SELECT reason FROM sessions WHERE session_id='closed-1';")"

# --- context persisted by SessionStart is carried into the row ---
sd=$(mk ctx-1 1000 1060)
printf 'LIN-456\n' > "$sd/issue-tag"
printf '%s\n' "$TMP/myproject" > "$sd/cwd"
mkdir -p "$TMP/myproject"
bash "$REAP" >/dev/null
assert_eq "issue tag carried over" "LIN-456" "$(sqlite3 "$DB" "SELECT issue_key FROM sessions WHERE session_id='ctx-1';")"
assert_eq "cwd carried over" "$TMP/myproject" "$(sqlite3 "$DB" "SELECT project_dir FROM sessions WHERE session_id='ctx-1';")"
assert_eq "project resolved from cwd" "myproject" \
  "$(sqlite3 "$DB" "SELECT p.name FROM sessions s JOIN projects p ON p.id=s.project_id WHERE s.session_id='ctx-1';")"

# --- reruns are idempotent: nothing changes on a second sweep, and the count
#     it reports (which is also what decides whether to kick the sync) says so ---
before="$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions;")"
assert_eq "second sweep reaps nothing" "0" "$(bash "$REAP")"
assert_eq "second sweep adds no rows" "$before" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions;")"

# --- threshold is configurable ---
mk tight-1 "$((now - 300))" "$((now - 200))" >/dev/null
SESSION_TRACKER_STALE_SECONDS=60 bash "$REAP" >/dev/null
assert_eq "lower threshold reaps a younger session" "1" \
  "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE session_id='tight-1';")"

# --- a pre-v4 session dir has no cwd file: record the time, not a junk project ---
mk nocwd-1 1000 1060 >/dev/null
bash "$REAP" >/dev/null
assert_eq "session without a cwd file is still recorded" "60" \
  "$(sqlite3 "$DB" "SELECT active_seconds FROM sessions WHERE session_id='nocwd-1';")"
assert_eq "its project is NULL, not an empty projects row" "1" \
  "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE session_id='nocwd-1' AND project_id IS NULL;")"
assert_eq "no blank project invented anywhere" "0" \
  "$(sqlite3 "$DB" "SELECT COUNT(*) FROM projects WHERE COALESCE(project_root,'')='' OR COALESCE(name,'')='';")"

# --- SessionStart persists the cwd the sweeper needs, and deploys the sweeper ---
H2="$TMP/h2"; mkdir -p "$H2"
echo '{"session_id":"s2","source":"startup","cwd":"'"$TMP"'"}' \
  | HOME="$H2" bash "$ROOT/hooks/session-start.sh" >/dev/null 2>&1
assert_eq "SessionStart persists cwd" "$TMP" "$(cat "$H2/.session-tracker/s2/cwd" 2>/dev/null)"
assert_eq "SessionStart deploys the sweeper" "yes" \
  "$([ -f "$H2/.session-tracker/reap-sessions.sh" ] && echo yes || echo no)"

finish
