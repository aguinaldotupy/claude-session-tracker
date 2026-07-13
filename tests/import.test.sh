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

# fix #1: legacy branch is real SQL NULL, not empty string
assert_eq "legacy branch is NULL" "1" "$(one "SELECT branch IS NULL FROM sessions WHERE session_id='dup';")"

# fix #2 (superseded by resilient import below): a malformed history.jsonl no
# longer aborts the whole migration — the valid row is now salvaged and the
# file renamed, instead of being preserved untouched with a non-zero return.
SE2="$HOME/.claude/session-env"
printf '{"session_id":"ok","project_dir":"/p","start_ts":1,"end_ts":2,"active_seconds":5}\nNOT JSON\n' > "$SE2/history.jsonl"
st_import_history; rc=$?
assert_eq "malformed history salvage returns zero" "0" "$rc"
assert_eq "malformed history renamed after salvage" "no" "$([ -f "$SE2/history.jsonl" ] && echo yes || echo no)"
assert_eq "malformed history: valid row still imported" "1" "$(one "SELECT COUNT(*) FROM sessions WHERE session_id='ok';")"

# a single malformed line no longer aborts the whole migration — valid rows import, bad line skipped
SE3="$HOME/.claude/session-env"
printf '%s\n' \
  '{"session_id":"g1","project_dir":"/p/a","active_seconds":30,"duration_seconds":30,"idle_seconds":0,"start_ts":10,"end_ts":40,"issue_key":"","reason":"other"}' \
  'THIS IS NOT JSON' \
  '{"session_id":"g2","project_dir":"/p/a","active_seconds":70,"duration_seconds":70,"idle_seconds":0,"start_ts":50,"end_ts":120,"issue_key":"","reason":"other"}' \
  > "$SE3/history.jsonl"
st_import_history; rc=$?
assert_eq "resilient import returns 0" "0" "$rc"
assert_eq "valid rows salvaged (2)" "2" "$(one "SELECT COUNT(*) FROM sessions WHERE session_id IN ('g1','g2');")"
assert_eq "salvaged total correct" "100" "$(one "SELECT COALESCE(SUM(active_seconds),0) FROM sessions WHERE session_id IN ('g1','g2');")"
assert_eq "malformed file renamed after salvage" "no" "$([ -f "$SE3/history.jsonl" ] && echo yes || echo no)"

# regression (v3.0.1): a large history must import in ONE pass — every session,
# not a partial subset (the per-row sqlite3 spawn migration was killed by the
# SessionStart 5s timeout after ~150 of ~3000 rows, leaving a partial DB).
: > "$SE3/history.jsonl"
i=0
while [ "$i" -lt 500 ]; do
  printf '{"session_id":"bulk-%s","project_dir":"/p/bulk","active_seconds":1,"duration_seconds":1,"idle_seconds":0,"start_ts":%s,"end_ts":%s,"issue_key":"","reason":"other"}\n' "$i" "$i" "$((i+1))" >> "$SE3/history.jsonl"
  i=$((i+1))
done
st_import_history; rc=$?
assert_eq "bulk import returns 0" "0" "$rc"
assert_eq "all 500 rows imported (no partial cutoff)" "500" "$(one "SELECT COUNT(*) FROM sessions WHERE session_id LIKE 'bulk-%';")"
assert_eq "bulk file renamed after full import" "no" "$([ -f "$SE3/history.jsonl" ] && echo yes || echo no)"

finish
