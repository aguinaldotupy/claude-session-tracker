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

# bare --session with no value terminates
out="$(timeout 5 bash "$SYNC" --session 2>&1)"; rc=$?
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
# for call N (default 200). Body output is {"data":{"id":"e1"}}.
echo "$@" >> "$CURL_CAPTURE"
n=$(wc -l < "$CURL_CAPTURE" | tr -d ' ')
code=$(sed -n "${n}p" "$CURL_CTRL" 2>/dev/null); code=${code:-200}
# emulate: curl -s -o BODYFILE -w '%{http_code}'
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && printf '{"data":{"id":"e1"}}' > "$out"
printf '%s' "$code"
SHIM
chmod +x "$BIN/curl"
export CURL_CAPTURE="$TMP/curl.log" CURL_CTRL="$TMP/curl.ctrl"
: > "$CURL_CAPTURE"; : > "$CURL_CTRL"
export PATH="$BIN:$PATH"

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

# done session: re-run posts nothing
bash "$SYNC" --session "$SID" >/dev/null 2>&1
assert_eq "done session skipped" "2" "$(wc -l < "$CURL_CAPTURE" | tr -d ' ')"

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

# member_id missing (API delta: required on every time-entry create) -> sync
# fails for that session before posting anything, with no ledger written.
SID3="sess-nomember"
mkdir -p "$SE/$SID3"
printf 'P 3000\nS 3060\n' > "$SE/$SID3/events.log"
sed 's/^SOLIDTIME_MEMBER_ID=.*/SOLIDTIME_MEMBER_ID=/' "$SE/solidtime.conf" > "$SE/solidtime.conf.tmp"
mv "$SE/solidtime.conf.tmp" "$SE/solidtime.conf"
: > "$CURL_CAPTURE"
bash "$SYNC" --session "$SID3" >/dev/null 2>&1
assert_eq "member_id missing: no posts" "0" "$(wc -l < "$CURL_CAPTURE" | tr -d ' ')"
assert_eq "member_id missing: error logged" "1" "$(grep -c 'ERROR member_id missing' "$LOG")"
assert_eq "member_id missing: no ledger" "0" "$([ -f "$SE/$SID3/solidtime-synced" ] && echo 1 || echo 0)"
sed 's/^SOLIDTIME_MEMBER_ID=.*/SOLIDTIME_MEMBER_ID=member-1/' "$SE/solidtime.conf" > "$SE/solidtime.conf.tmp"
mv "$SE/solidtime.conf.tmp" "$SE/solidtime.conf"

finish
