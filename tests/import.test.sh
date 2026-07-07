#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
. "$DIR/../hooks/lib/import-history.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
SE="$TMP/.claude/session-env"; mkdir -p "$SE"
one() { sqlite3 "$(st_db_path)" "$1"; }

# history with a DUPLICATED session_id (3 cumulative snapshots) + one distinct session
cat > "$SE/history.jsonl" <<'JSON'
{"session_id":"dup","project_dir":"/p/bel","active_seconds":100,"duration_seconds":100,"idle_seconds":0,"start_ts":1000,"end_ts":1100,"issue_key":"","reason":"other"}
{"session_id":"dup","project_dir":"/p/bel","active_seconds":300,"duration_seconds":300,"idle_seconds":0,"start_ts":1000,"end_ts":1300,"issue_key":"","reason":"other"}
{"session_id":"dup","project_dir":"/p/bel","active_seconds":600,"duration_seconds":600,"idle_seconds":0,"start_ts":1000,"end_ts":1600,"issue_key":"BEL-1","reason":"other"}
{"session_id":"solo","project_dir":"/p/onspot","active_seconds":50,"duration_seconds":50,"idle_seconds":0,"start_ts":2000,"end_ts":2050,"issue_key":"","reason":"other"}
JSON

st_import_history

# dedup: dup collapses to 1 row keeping the last (largest) snapshot
assert_eq "dup collapsed to one row" "1" "$(one "SELECT COUNT(*) FROM sessions WHERE session_id='dup';")"
assert_eq "dup keeps last active" "600" "$(one "SELECT active_seconds FROM sessions WHERE session_id='dup';")"
assert_eq "two sessions total" "2" "$(one "SELECT COUNT(*) FROM sessions;")"
# correct deduped total = 600 + 50
assert_eq "deduped total active" "650" "$(one "SELECT SUM(active_seconds) FROM sessions;")"

# legacy defaults: project_root == project_dir, branch NULL
assert_eq "legacy root is dir" "/p/bel" "$(one "SELECT p.project_root FROM sessions s JOIN projects p ON p.id=s.project_id WHERE s.session_id='dup';")"
assert_eq "legacy branch null" "" "$(one "SELECT COALESCE(branch,'') FROM sessions WHERE session_id='dup';")"

# file renamed, so re-run is a no-op
assert_eq "history renamed" "no" "$([ -f "$SE/history.jsonl" ] && echo yes || echo no)"
st_import_history; rc=$?
assert_eq "second run clean" "0" "$rc"
assert_eq "still two sessions" "2" "$(one "SELECT COUNT(*) FROM sessions;")"

finish
