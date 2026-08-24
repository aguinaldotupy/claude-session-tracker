#!/usr/bin/env bash
# Home resolution + the one-time migration off the legacy ~/.claude/session-env path.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$DIR/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
unset SESSION_TRACKER_HOME

. "$ROOT/hooks/lib/db.sh"

# --- resolution ---
assert_eq "st_home defaults to ~/.session-tracker" "$TMP/.session-tracker" "$(st_home)"
assert_eq "SESSION_TRACKER_HOME overrides the default" "/custom/place" \
  "$(SESSION_TRACKER_HOME=/custom/place bash -c '. "$1/hooks/lib/db.sh"; st_home' _ "$ROOT")"
assert_eq "st_db_path lives under st_home" "$TMP/.session-tracker/history.db" "$(st_db_path)"

# --- migration: legacy dir moves, old path stays reachable as a symlink ---
LEGACY="$TMP/.claude/session-env"
mkdir -p "$LEGACY/sess-1"
echo 1700000000 > "$LEGACY/sess-1/session-tracker"
echo "token" > "$LEGACY/solidtime.conf"

st_migrate_home

assert_eq "session dir moved to the new home" "1700000000" \
  "$(cat "$TMP/.session-tracker/sess-1/session-tracker" 2>/dev/null)"
assert_eq "config moved to the new home" "token" \
  "$(cat "$TMP/.session-tracker/solidtime.conf" 2>/dev/null)"
assert_eq "legacy path left as a symlink" "yes" "$([ -L "$LEGACY" ] && echo yes || echo no)"
assert_eq "legacy path still resolves to the data" "1700000000" \
  "$(cat "$LEGACY/sess-1/session-tracker" 2>/dev/null)"

# --- idempotent: a second run changes nothing ---
st_migrate_home
assert_eq "second migration keeps the symlink" "yes" "$([ -L "$LEGACY" ] && echo yes || echo no)"

# --- never clobbers a new home that already holds data ---
H2="$TMP/h2"; mkdir -p "$H2/.claude/session-env" "$H2/.session-tracker"
echo legacy > "$H2/.claude/session-env/marker"
echo current > "$H2/.session-tracker/marker"
HOME="$H2" st_migrate_home
assert_eq "populated new home is not overwritten" "current" "$(cat "$H2/.session-tracker/marker")"
assert_eq "legacy dir left alone when both hold data" "no" \
  "$([ -L "$H2/.claude/session-env" ] && echo yes || echo no)"

# --- an empty new home (a hook that fired before SessionStart) still migrates ---
H4="$TMP/h4"; mkdir -p "$H4/.claude/session-env" "$H4/.session-tracker"
echo legacy > "$H4/.claude/session-env/marker"
HOME="$H4" st_migrate_home
assert_eq "empty new home does not block the migration" "legacy" \
  "$(cat "$H4/.session-tracker/marker" 2>/dev/null)"

# --- fresh install: no legacy dir, no symlink invented ---
H3="$TMP/h3"; mkdir -p "$H3"
HOME="$H3" st_migrate_home
assert_eq "fresh install creates no legacy symlink" "no" \
  "$([ -e "$H3/.claude/session-env" ] && echo yes || echo no)"

# --- end to end through the SessionStart hook ---
H5="$TMP/h5"; mkdir -p "$H5/.claude/session-env/old-sess"
echo 1700000000 > "$H5/.claude/session-env/old-sess/session-tracker"
echo '{"session_id":"new-sess","source":"startup"}' \
  | HOME="$H5" bash "$ROOT/hooks/session-start.sh" >/dev/null 2>&1
assert_eq "SessionStart migrates before it writes" "1700000000" \
  "$(cat "$H5/.session-tracker/old-sess/session-tracker" 2>/dev/null)"
assert_eq "SessionStart writes the new session into the new home" "yes" \
  "$([ -f "$H5/.session-tracker/new-sess/session-tracker" ] && echo yes || echo no)"
assert_eq "SessionStart leaves the legacy path linked" "yes" \
  "$([ -L "$H5/.claude/session-env" ] && echo yes || echo no)"

finish
