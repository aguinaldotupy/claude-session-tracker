#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"

TMP=$(mktemp -d); TMP="$(cd "$TMP" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
SE="$HOME/.claude/session-env"
mkdir -p "$SE"
# deployed libs, as session-start.sh would leave them
cp "$DIR/../hooks/lib/active-time.awk" "$SE/active-time.awk"
cp "$DIR/../hooks/lib/db.sh" "$SE/db.sh"
SYNC="$DIR/../hooks/lib/solidtime-sync.sh"
LOG="$SE/solidtime-sync.log"

# no config -> silent success, no log created
out="$(bash "$SYNC" 2>&1)"; rc=$?
assert_eq "no config exits 0" "0" "$rc"
assert_eq "no config no output" "" "$out"
assert_eq "no config no log" "0" "$([ -f "$LOG" ] && echo 1 || echo 0)"

# config present: run starts and logs, token never logged
cat > "$SE/solidtime.conf" <<EOF
SOLIDTIME_URL=https://time.test
SOLIDTIME_TOKEN=secret-token-123
SOLIDTIME_ORG_ID=org-1
SOLIDTIME_MEMBER_ID=member-1
EOF
chmod 600 "$SE/solidtime.conf"
bash "$SYNC" >/dev/null 2>&1
assert_eq "run creates log" "1" "$([ -f "$LOG" ] && echo 1 || echo 0)"
assert_eq "token never in log" "0" "$(grep -c 'secret-token-123' "$LOG")"

# lock held by a live run -> second run exits 0 and logs skip
mkdir -p "$SE/solidtime-sync.lock"
bash "$SYNC" >/dev/null 2>&1; rc=$?
assert_eq "locked run exits 0" "0" "$rc"
assert_eq "locked run logged" "1" "$(grep -c 'lock held' "$LOG")"
rmdir "$SE/solidtime-sync.lock"

# stale lock (>10 min) is broken and the run proceeds
mkdir -p "$SE/solidtime-sync.lock"
touch -t 202601010101 "$SE/solidtime-sync.lock"
bash "$SYNC" >/dev/null 2>&1
assert_eq "stale lock broken" "0" "$([ -d "$SE/solidtime-sync.lock" ] && echo 1 || echo 0)"

# rotation: >500 lines truncates to last 250
: > "$LOG"; i=0; while [ $i -lt 600 ]; do echo "line $i" >> "$LOG"; i=$((i+1)); done
bash "$SYNC" >/dev/null 2>&1
lines=$(wc -l < "$LOG" | tr -d ' ')
assert_eq "log rotated under 300" "1" "$([ "$lines" -lt 300 ] && echo 1 || echo 0)"
assert_eq "rotation kept newest" "1" "$(grep -c 'line 599' "$LOG")"

# bare --session with no value terminates. `timeout` isn't on stock macOS;
# use it when available as a hang guard, otherwise just run it directly --
# the hang this guards against is fixed and covered by the arg-parsing loop.
if command -v timeout >/dev/null 2>&1; then
  out="$(timeout 5 bash "$SYNC" --session 2>&1)"; rc=$?
else
  out="$(bash "$SYNC" --session 2>&1)"; rc=$?
fi
assert_eq "bare --session terminates" "0" "$rc"
assert_eq "bare --session no output" "" "$out"

# unreadable config (chmod 000) exits 0 silently
chmod 000 "$SE/solidtime.conf"
out="$(bash "$SYNC" 2>&1)"; rc=$?
assert_eq "unreadable config exits 0" "0" "$rc"
assert_eq "unreadable config silent" "" "$out"
chmod 600 "$SE/solidtime.conf"

# ---- posting with curl shim ----
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/curl" <<'SHIM'
#!/usr/bin/env bash
# Records each invocation; behavior driven by $CURL_CTRL: line N = HTTP code
# for call N (default 200). Body varies by request kind: -X POST (create) ->
# {"data":{"id":"new-1"}}; GET .../memberships -> a membership list matching
# org "org-1"; any other GET (list) -> {"data":[{"id":"p1","name":"repo"}]}.
echo "$@" >> "$CURL_CAPTURE"
n=$(wc -l < "$CURL_CAPTURE" | tr -d ' ')
code=$(sed -n "${n}p" "$CURL_CTRL" 2>/dev/null); code=${code:-200}
# emulate: curl -s -o BODYFILE -w '%{http_code}'
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
if printf '%s' "$*" | grep -q -- '-X POST'; then
  [ -n "$out" ] && printf '{"data":{"id":"new-1"}}' > "$out"
elif printf '%s' "$*" | grep -q -- '/memberships'; then
  [ -n "$out" ] && printf '{"data":[{"id":"member-auto","organization":{"id":"org-1"}}]}' > "$out"
else
  [ -n "$out" ] && printf '{"data":[{"id":"p1","name":"repo"}]}' > "$out"
fi
printf '%s' "$code"
SHIM
chmod +x "$BIN/curl"
export CURL_CAPTURE="$TMP/curl.log" CURL_CTRL="$TMP/curl.ctrl"
: > "$CURL_CAPTURE"; : > "$CURL_CTRL"
export PATH="$BIN:$PATH"

# Task 6: real _sl_resolve_project/_sl_resolve_tag are now live for every
# --session run below, not just the project/tag-cache tests further down.
# Pre-seed the cache so the pre-existing posting-flow tests (written before
# real resolvers existed) see cache hits and keep their exact curl-call
# counts instead of picking up extra list/create calls.
PROJNAME="$(basename "$PWD")"
printf '{"projects":{"%s":"proj-1"},"tags":{"A-7":"tag-1"}}\n' "$PROJNAME" > "$SE/solidtime-cache.json"

# a finished session with two brackets: [1000,1100] and [1300,1420]
SID="sess-post"
mkdir -p "$SE/$SID"
printf 'P 1000\nS 1100\nP 1300\nS 1360\n' > "$SE/$SID/events.log"
printf 'A-7\n' > "$SE/$SID/issue-tag"
export SESSION_IDLE_THRESHOLD_SECONDS=60

bash "$SYNC" --session "$SID" >/dev/null 2>&1
assert_eq "two entries posted" "2" "$(wc -l < "$CURL_CAPTURE" | tr -d ' ')"
assert_eq "ledger complete" "0
1
done" "$(cat "$SE/$SID/solidtime-synced")"
assert_eq "payload has iso start" "1" "$(grep -c '1970-01-01T00:16:40Z' "$CURL_CAPTURE")"
assert_eq "auth header sent" "2" "$(grep -c 'Bearer secret-token-123' "$CURL_CAPTURE")"
assert_eq "member_id on wire" "2" "$(grep -c '\"member_id\":\"member-1\"' "$CURL_CAPTURE")"
assert_eq "billable false on wire" "2" "$(grep -c '\"billable\":false' "$CURL_CAPTURE")"
assert_eq "no tag_ids on wire" "0" "$(grep -c 'tag_ids' "$CURL_CAPTURE")"

# done session: re-run posts nothing
bash "$SYNC" --session "$SID" >/dev/null 2>&1
assert_eq "done session skipped" "2" "$(wc -l < "$CURL_CAPTURE" | tr -d ' ')"

# resume gap (Task 7 finding): a session already synced to 'done' gets two
# more prompt/stop brackets appended (as happens when it's resumed). An
# explicit --session run must bypass the 'done' short-circuit and post only
# the new brackets, since session_id is stable across resume.
printf 'P 1500\nS 1560\nP 1700\nS 1760\n' >> "$SE/$SID/events.log"
: > "$CURL_CAPTURE"
bash "$SYNC" --session "$SID" >/dev/null 2>&1
assert_eq "resume: only new brackets posted" "2" "$(wc -l < "$CURL_CAPTURE" | tr -d ' ')"
# duplicate 'done' lines are harmless (ruling); the prior "done session
# skipped" run already appended one extra 'done' before this resume.
assert_eq "resume: ledger has 0-3 plus done" "0
1
done
done
2
3
done" "$(cat "$SE/$SID/solidtime-synced")"

# mid-batch failure: second call 500 -> ledger stops, log has status, resume completes
SID2="sess-fail"
mkdir -p "$SE/$SID2"
printf 'P 2000\nS 2100\nP 2300\nS 2360\n' > "$SE/$SID2/events.log"
: > "$CURL_CAPTURE"; printf '200\n500\n' > "$CURL_CTRL"
bash "$SYNC" --session "$SID2" >/dev/null 2>&1
assert_eq "fail: only first in ledger" "0" "$(cat "$SE/$SID2/solidtime-synced")"
assert_eq "fail: 500 logged" "1" "$(grep -c 'ERROR .*500' "$LOG")"
: > "$CURL_CAPTURE"; : > "$CURL_CTRL"
bash "$SYNC" --session "$SID2" >/dev/null 2>&1
assert_eq "resume: posts only remainder" "1" "$(wc -l < "$CURL_CAPTURE" | tr -d ' ')"
assert_eq "resume: ledger complete" "1
done" "$(sed -n '2,3p' "$SE/$SID2/solidtime-synced")"
unset SESSION_IDLE_THRESHOLD_SECONDS

# member_id missing from conf (API delta: required on every time-entry
# create). Task 6 controller ruling: _sl_resolve_member auto-resolves via
# GET memberships before giving up -- here that lookup itself fails (HTTP
# 500), so no id is found and sync still fails for the session before
# posting anything, with no ledger written.
SID3="sess-nomember"
mkdir -p "$SE/$SID3"
printf 'P 3000\nS 3060\n' > "$SE/$SID3/events.log"
sed 's/^SOLIDTIME_MEMBER_ID=.*/SOLIDTIME_MEMBER_ID=/' "$SE/solidtime.conf" > "$SE/solidtime.conf.tmp"
mv "$SE/solidtime.conf.tmp" "$SE/solidtime.conf"
: > "$CURL_CAPTURE"; printf '500\n' > "$CURL_CTRL"
bash "$SYNC" --session "$SID3" >/dev/null 2>&1
assert_eq "member_id missing: auto-resolve attempted, no entry posts" "1" "$(wc -l < "$CURL_CAPTURE" | tr -d ' ')"
assert_eq "member_id missing: error logged" "1" "$(grep -c 'ERROR member_id missing' "$LOG")"
assert_eq "member_id missing: no ledger" "0" "$([ -f "$SE/$SID3/solidtime-synced" ] && echo 1 || echo 0)"
: > "$CURL_CTRL"
sed 's/^SOLIDTIME_MEMBER_ID=.*/SOLIDTIME_MEMBER_ID=member-1/' "$SE/solidtime.conf" > "$SE/solidtime.conf.tmp"
mv "$SE/solidtime.conf.tmp" "$SE/solidtime.conf"

# ---- project/tag cache ----
rm -f "$SE/solidtime-cache.json"
: > "$CURL_CAPTURE"; : > "$CURL_CTRL"
SID6="sess-proj"; mkdir -p "$SE/$SID6"
printf 'P 3000\nS 3100\n' > "$SE/$SID6/events.log"
printf 'A-9\n' > "$SE/$SID6/issue-tag"
( cd "$TMP" && mkdir -p repo && cd repo && bash "$SYNC" --session "$SID6" ) >/dev/null 2>&1
assert_eq "cache file created" "1" "$([ -f "$SE/solidtime-cache.json" ] && echo 1 || echo 0)"
assert_eq "project id cached" "p1" "$(jq -r '.projects.repo' "$SE/solidtime-cache.json")"
assert_eq "tag id cached" "new-1" "$(jq -r '.tags["A-9"]' "$SE/solidtime-cache.json")"
assert_eq "tags field on wire" "1" "$(grep -c '\"tags\":\[\"new-1\"\]' "$CURL_CAPTURE")"

# second session, same project + tag: no extra list/create calls (cache hit)
SID7="sess-proj2"; mkdir -p "$SE/$SID7"
printf 'P 4000\nS 4100\n' > "$SE/$SID7/events.log"
printf 'A-9\n' > "$SE/$SID7/issue-tag"
: > "$CURL_CAPTURE"
( cd "$TMP/repo" && bash "$SYNC" --session "$SID7" ) >/dev/null 2>&1
assert_eq "cache hit: only the entry POST" "1" "$(wc -l < "$CURL_CAPTURE" | tr -d ' ')"
assert_eq "project_id on wire (cache hit)" "1" "$(grep -c '\"project_id\":\"p1\"' "$CURL_CAPTURE")"

# ---- resolve failure fallback: GET list, POST create, and the tag
# equivalent all fail (non-2xx) -> _sl_resolve prints empty for both, entry
# still posts without project_id/tags rather than failing the sync (ruling
# under review finding). Fresh project name so cache can't short-circuit;
# SOLIDTIME_MEMBER_ID stays set in conf throughout.
SID10="sess-resolve-fail"; mkdir -p "$SE/$SID10"
printf 'P 7000\nS 7100\n' > "$SE/$SID10/events.log"
printf 'A-99\n' > "$SE/$SID10/issue-tag"
: > "$CURL_CAPTURE"; printf '500\n500\n500\n500\n200\n' > "$CURL_CTRL"
( cd "$TMP" && mkdir -p repo3 && cd repo3 && bash "$SYNC" --session "$SID10" ) >/dev/null 2>&1
assert_eq "resolve-fail: entry still posts (ledger done)" "0
done" "$(cat "$SE/$SID10/solidtime-synced")"
assert_eq "resolve-fail: no project_id on wire" "0" "$(grep -c 'project_id' "$CURL_CAPTURE")"
assert_eq "resolve-fail: no tags array on wire" "0" "$(grep -c '\"tags\":\[' "$CURL_CAPTURE")"
assert_eq "resolve-fail: ERROR resolve logged" "2" "$(grep -c 'ERROR resolve' "$LOG")"
: > "$CURL_CTRL"

# ---- same resolve-failure scenario, but --verbose (regression: _sl_log's
# verbose echo used to go to stdout, so when a resolver failed inside its
# $(...) capture, the ERROR log line itself became the "id" -- e.g.
# project_id ended up holding the literal error string, which the live
# server rejected with a 422). Fresh project name so cache can't
# short-circuit; entry must still post cleanly with no leaked ERROR text
# anywhere in the payload. ----
SID11="sess-resolve-fail-verbose"; mkdir -p "$SE/$SID11"
printf 'P 7200\nS 7300\n' > "$SE/$SID11/events.log"
printf 'A-100\n' > "$SE/$SID11/issue-tag"
: > "$CURL_CAPTURE"; printf '500\n500\n500\n500\n200\n' > "$CURL_CTRL"
( cd "$TMP" && mkdir -p repo4 && cd repo4 && bash "$SYNC" --session "$SID11" --verbose ) >/dev/null 2>&1
assert_eq "resolve-fail verbose: entry still posts (ledger done)" "0
done" "$(cat "$SE/$SID11/solidtime-synced")"
assert_eq "resolve-fail verbose: no ERROR leaked into project_id" "0" "$(grep -c 'project_id":"ERROR' "$CURL_CAPTURE")"
assert_eq "resolve-fail verbose: no ERROR leaked into tags" "0" "$(grep -c '\"tags\":\[\"ERROR' "$CURL_CAPTURE")"
assert_eq "resolve-fail verbose: entry POST still succeeded" "1" "$(grep -c -- '-X POST.*time-entries' "$CURL_CAPTURE")"
: > "$CURL_CTRL"

# ---- project create payload: client_id must be PRESENT (null accepted).
# Cloud API 422s with "The client id field must be present." when the key
# is omitted entirely (verified live E2E against app.solidtime.io,
# 2026-08-21). A fresh project name that doesn't match the shim's generic
# "repo" GET response forces a GET-miss -> POST-create, so the create
# payload lands on the wire to inspect. ----
SID12="sess-proj-create"; mkdir -p "$SE/$SID12"
printf 'P 8000\nS 8060\n' > "$SE/$SID12/events.log"
: > "$CURL_CAPTURE"; : > "$CURL_CTRL"
( cd "$TMP" && mkdir -p newproj && cd newproj && bash "$SYNC" --session "$SID12" ) >/dev/null 2>&1
assert_eq "project create: client_id present and null" "1" "$(grep -c '\"client_id\":null' "$CURL_CAPTURE")"
assert_eq "project create: is_billable still on wire" "1" "$(grep -c '\"is_billable\":false' "$CURL_CAPTURE")"

# ---- member_id auto-resolve (SOLIDTIME_MEMBER_ID absent from conf) ----
sed 's/^SOLIDTIME_MEMBER_ID=.*/SOLIDTIME_MEMBER_ID=/' "$SE/solidtime.conf" > "$SE/solidtime.conf.tmp"
mv "$SE/solidtime.conf.tmp" "$SE/solidtime.conf"
SID8="sess-member-auto"; mkdir -p "$SE/$SID8"
printf 'P 6000\nS 6100\n' > "$SE/$SID8/events.log"
: > "$CURL_CAPTURE"; : > "$CURL_CTRL"
( cd "$TMP/repo" && bash "$SYNC" --session "$SID8" ) >/dev/null 2>&1
assert_eq "member_id auto-resolve + entry: 2 calls" "2" "$(wc -l < "$CURL_CAPTURE" | tr -d ' ')"
assert_eq "auto-resolved member on wire" "1" "$(grep -c '\"member_id\":\"member-auto\"' "$CURL_CAPTURE")"
assert_eq "member_id cached" "member-auto" "$(jq -r '.member_id' "$SE/solidtime-cache.json")"

# second session: member_id now cached -> no membership call, only entry POST
SID9="sess-member-auto2"; mkdir -p "$SE/$SID9"
printf 'P 6200\nS 6260\n' > "$SE/$SID9/events.log"
: > "$CURL_CAPTURE"
( cd "$TMP/repo" && bash "$SYNC" --session "$SID9" ) >/dev/null 2>&1
assert_eq "member_id cache hit: only the entry POST" "1" "$(wc -l < "$CURL_CAPTURE" | tr -d ' ')"
sed 's/^SOLIDTIME_MEMBER_ID=.*/SOLIDTIME_MEMBER_ID=member-1/' "$SE/solidtime.conf" > "$SE/solidtime.conf.tmp"
mv "$SE/solidtime.conf.tmp" "$SE/solidtime.conf"

# ---- discovery: ended sessions without 'done' get synced ----
. "$DIR/../hooks/lib/db.sh"
st_db_init
st_upsert_session "disc-1" "/p/x" "/p/x" "" "" 100 200 100 80 20 "exit" 201
st_upsert_session "disc-2" "/p/x" "/p/x" "" "" 100 300 200 90 110 "exit" 301
mkdir -p "$SE/disc-1" "$SE/disc-2"
printf 'P 100\nS 160\n' > "$SE/disc-1/events.log"
printf 'P 100\nS 260\n' > "$SE/disc-2/events.log"
printf '0\ndone\n' > "$SE/disc-2/solidtime-synced"   # already complete
: > "$CURL_CAPTURE"; : > "$CURL_CTRL"
bash "$SYNC" >/dev/null 2>&1
assert_eq "discovery syncs only pending" "1" "$(grep -c 'disc' "$CURL_CAPTURE" | tr -d ' ')"
assert_eq "disc-1 now done" "1" "$(grep -cx done "$SE/disc-1/solidtime-synced")"

# ---- no-events session (Task 7 finding): DB row with no events.log (e.g.
# wall-clock fallback, zero prompts) must be marked done, not left pending
# forever ----
st_upsert_session "disc-noevents" "/p/x" "/p/x" "" "" 100 400 300 0 0 "exit" 401
: > "$CURL_CAPTURE"
bash "$SYNC" >/dev/null 2>&1
assert_eq "no-events session marked done" "1" "$(grep -cx done "$SE/disc-noevents/solidtime-synced")"
assert_eq "no-events session: no HTTP call" "0" "$(grep -c 'disc-noevents' "$CURL_CAPTURE")"
assert_eq "no-events session: logged" "1" "$(grep -c 'session disc-noevents: no events.log, marking done' "$LOG")"

# ---- --check: real credential verification (GET memberships), no session sync ----
# curl shim already returns a memberships body containing org "org-1" for
# any GET to /memberships (see shim above); solidtime.conf's SOLIDTIME_ORG_ID
# is "org-1", so the default shim response is the org-found case.
: > "$CURL_CAPTURE"; printf '200\n' > "$CURL_CTRL"
: > "$LOG"
out="$(bash "$SYNC" --check --verbose 2>&1)"
assert_eq "check 200: hits memberships" "1" "$(grep -c 'api/v1/users/me/memberships' "$CURL_CAPTURE")"
assert_eq "check 200: no entry POSTs" "0" "$(grep -c -- '-X POST' "$CURL_CAPTURE")"
assert_eq "check 200: log line" "1" "$(grep -c 'check: HTTP 200' "$LOG")"
assert_eq "check 200: verbose credentials OK" "1" "$(printf '%s\n' "$out" | grep -c '^credentials OK$')"

: > "$CURL_CAPTURE"; printf '401\n' > "$CURL_CTRL"
: > "$LOG"
out="$(bash "$SYNC" --check --verbose 2>&1)"; rc=$?
assert_eq "check 401: exits 0" "0" "$rc"
assert_eq "check 401: ERROR log line" "1" "$(grep -c 'ERROR check: HTTP 401' "$LOG")"
assert_eq "check 401: verbose credentials FAILED" "1" "$(printf '%s\n' "$out" | grep -c '^credentials FAILED: HTTP 401$')"
: > "$CURL_CTRL"

# ---- --check: 2xx but configured org id isn't among the memberships ----
sed 's/^SOLIDTIME_ORG_ID=.*/SOLIDTIME_ORG_ID=org-missing/' "$SE/solidtime.conf" > "$SE/solidtime.conf.tmp"
mv "$SE/solidtime.conf.tmp" "$SE/solidtime.conf"
: > "$CURL_CAPTURE"; printf '200\n' > "$CURL_CTRL"
: > "$LOG"
out="$(bash "$SYNC" --check --verbose 2>&1)"; rc=$?
assert_eq "check org-missing: exits 0" "0" "$rc"
assert_eq "check org-missing: ERROR log line" "1" "$(grep -c 'ERROR check: HTTP 200 org org-missing not found' "$LOG")"
assert_eq "check org-missing: verbose credentials FAILED" "1" "$(printf '%s\n' "$out" | grep -c '^credentials FAILED: org not found$')"
sed 's/^SOLIDTIME_ORG_ID=.*/SOLIDTIME_ORG_ID=org-1/' "$SE/solidtime.conf" > "$SE/solidtime.conf.tmp"
mv "$SE/solidtime.conf.tmp" "$SE/solidtime.conf"
: > "$CURL_CTRL"

finish
