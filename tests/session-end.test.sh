#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$DIR/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
SID="end-session-1"
SDIR="$TMP/.session-tracker/$SID"
mkdir -p "$SDIR"

# Session started 10 min ago; one 60s working interval, then parked until now.
now=$(date +%s)
start=$((now - 600))
echo "$start" > "$SDIR/session-tracker"
printf 'P %s\nS %s\n' "$start" "$((start + 60))" > "$SDIR/events.log"

echo '{"session_id":"'"$SID"'","reason":"exit","cwd":"'"$TMP"'"}' | bash "$ROOT/hooks/session-end.sh"

# With sqlite3 available (the norm on dev/CI machines), session-end now writes
# to the SQLite store first and returns before the legacy JSONL append — so
# these pre-existing assertions read the same computed values back from the DB.
DB0="$TMP/.session-tracker/history.db"
# active = 60s work + 120s grace (parked gap >> grace) = 180
assert_eq "additive active_seconds" "180" "$(sqlite3 "$DB0" "SELECT active_seconds FROM sessions WHERE session_id='$SID';")"
# idle = duration - active; consistency check
dur=$(sqlite3 "$DB0" "SELECT duration_seconds FROM sessions WHERE session_id='$SID';")
act=$(sqlite3 "$DB0" "SELECT active_seconds FROM sessions WHERE session_id='$SID';")
idl=$(sqlite3 "$DB0" "SELECT idle_seconds FROM sessions WHERE session_id='$SID';")
assert_eq "idle = duration - active" "$((dur - act))" "$idl"

# --- SQLite write path ---
SIDB="sql-end-1"; SD="$TMP/.session-tracker/$SIDB"; mkdir -p "$SD"
echo "1000" > "$SD/session-tracker"
printf 'P 1000\nT 1005 Read\nD 1040 Read\nS 1060\n' > "$SD/events.log"
echo '{"session_id":"'"$SIDB"'","reason":"other","cwd":"'"$TMP"'"}' | bash "$ROOT/hooks/session-end.sh" >/dev/null
DB="$TMP/.session-tracker/history.db"
assert_eq "session row written" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE session_id='$SIDB';")"
assert_eq "events not archived (v3.1.2: dropped slow import)" "0" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE session_id='$SIDB';")"

# repeated SessionEnd (resume): still one row
echo '{"session_id":"'"$SIDB"'","reason":"resume","cwd":"'"$TMP"'"}' | bash "$ROOT/hooks/session-end.sh" >/dev/null
assert_eq "resume keeps one row" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE session_id='$SIDB';")"
assert_eq "events still not archived on resume" "0" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE session_id='$SIDB';")"

# fallback: with sqlite3 masked off PATH, SessionEnd appends legacy JSONL
SIDF="fallback-1"; SDF="$TMP/.session-tracker/$SIDF"; mkdir -p "$SDF"
echo "3000" > "$SDF/session-tracker"
# Closed P->S bracket makes active_seconds deterministic (independent of wall-clock end_ts):
# 60s worked interval + up to 120s capped reading-tail grace after the trailing S = 180
# (last_stop stays open past S until session end; see hooks/lib/active-time.awk END block,
# same pattern as the "additive active_seconds" case above).
printf 'P 3000\nS 3060\n' > "$SDF/events.log"
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
for b in bash jq date git awk cat basename dirname mkdir sed printf head tr; do ln -sf "$(command -v $b)" "$FAKEBIN/$b" 2>/dev/null; done
PATH="$FAKEBIN" bash "$ROOT/hooks/session-end.sh" <<< '{"session_id":"'"$SIDF"'","reason":"other","cwd":"'"$TMP"'"}' >/dev/null
assert_eq "fallback wrote jsonl" "yes" "$([ -f "$TMP/.session-tracker/history.jsonl" ] && grep -q "$SIDF" "$TMP/.session-tracker/history.jsonl" && echo yes || echo no)"
assert_eq "fallback jsonl active_seconds correct" "180" "$(jq -r 'select(.session_id=="'"$SIDF"'") | .active_seconds' "$TMP/.session-tracker/history.jsonl")"
assert_eq "fallback jsonl idle = duration - active" "yes" "$(jq -r 'select(.session_id=="'"$SIDF"'") | (if .idle_seconds == .duration_seconds - .active_seconds then "yes" else "no" end)' "$TMP/.session-tracker/history.jsonl")"

# --- Solidtime background launch: hook returns fast, sync runs async ---
SIDL="solidtime-launch-1"; SDL="$TMP/.session-tracker/$SIDL"; mkdir -p "$SDL"
echo "5000" > "$SDL/session-tracker"
printf 'P 5000\nS 5060\n' > "$SDL/events.log"
cat > "$TMP/.session-tracker/config.yml" <<'EOF'
solidtime:
  url: https://time.test
EOF
cat > "$TMP/.session-tracker/solidtime-sync.sh" <<'STUB'
#!/usr/bin/env bash
sleep 0.3
touch "$HOME/launched"
STUB
chmod +x "$TMP/.session-tracker/solidtime-sync.sh"

SECONDS=0
echo '{"session_id":"'"$SIDL"'","reason":"exit","cwd":"'"$TMP"'"}' | bash "$ROOT/hooks/session-end.sh" >/dev/null
ELAPSED=$SECONDS
assert_eq "hook returns fast" "yes" "$([ "$ELAPSED" -lt 2 ] && echo yes || echo no)"

i=0
while [ $i -lt 20 ] && [ ! -f "$TMP/launched" ]; do sleep 0.1; i=$((i + 1)); done
assert_eq "solidtime-sync launched in background" "yes" "$([ -f "$TMP/launched" ] && echo yes || echo no)"

# --- two sessions in different projects never cross-attribute ---
# The opencode shim had to be taught this (one process, many sessions, one
# `directory`); Claude Code hands every hook invocation its own `cwd`, so the
# guarantee comes from the payload. Pinned here so it stays that way.
if command -v sqlite3 >/dev/null 2>&1; then
  A="$TMP/alpha"; B="$TMP/beta"; mkdir -p "$A" "$B"
  for pair in "cc-a $A" "cc-b $B"; do
    set -- $pair
    sd="$TMP/.session-tracker/$1"; mkdir -p "$sd"
    echo 1000 > "$sd/session-tracker"
    printf 'P 1000\nS 1060\n' > "$sd/events.log"
    echo '{"session_id":"'"$1"'","reason":"exit","cwd":"'"$2"'"}' | bash "$ROOT/hooks/session-end.sh" >/dev/null
  done
  DBX="$TMP/.session-tracker/history.db"
  assert_eq "session A filed under its own project" "alpha" \
    "$(sqlite3 "$DBX" "SELECT p.name FROM sessions s JOIN projects p ON p.id=s.project_id WHERE s.session_id='cc-a';")"
  assert_eq "session B filed under its own project" "beta" \
    "$(sqlite3 "$DBX" "SELECT p.name FROM sessions s JOIN projects p ON p.id=s.project_id WHERE s.session_id='cc-b';")"
fi

# --- SessionStart persists each session's own cwd, for the sweeper ---
for pair in "cc-c $TMP/alpha" "cc-d $TMP/beta"; do
  set -- $pair
  echo '{"session_id":"'"$1"'","source":"startup","cwd":"'"$2"'"}' | bash "$ROOT/hooks/session-start.sh" >/dev/null 2>&1
done
assert_eq "SessionStart cwd is per session (A)" "$TMP/alpha" "$(cat "$TMP/.session-tracker/cc-c/cwd" 2>/dev/null)"
assert_eq "SessionStart cwd is per session (B)" "$TMP/beta" "$(cat "$TMP/.session-tracker/cc-d/cwd" 2>/dev/null)"

finish
