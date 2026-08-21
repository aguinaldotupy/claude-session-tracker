# Solidtime Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Opt-in sync of finished sessions (as per-bracket time entries) from the plugin's local store to any Solidtime instance, plus removal of the `st_import_events` hot path that times out the SessionEnd hook.

**Architecture:** Local-first stays untouched: hooks write locally and never wait on the network. A new shell sync client (`hooks/lib/solidtime-sync.sh`, deployed to `~/.claude/session-env/` like the other read-side libs) posts each active bracket from a session's persisted `events.log` as a Solidtime time entry, tracked by an incremental per-session ledger for idempotency. Errors always go to a dedicated log.

**Tech Stack:** POSIX shell + bash, awk, jq, curl. `sqlite3` stays a soft dependency. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-21-solidtime-sync-design.md`

## Global Constraints

- Hooks must never block Claude Code: bodies wrapped in `{ ... } || exit 0`, 5s timeout budget; sync launches detached in the background and the hook exits immediately.
- `SOLIDTIME_TOKEN` must never appear in any log or test fixture output.
- BSD/GNU portability: no `date +%N`, no `flock`, no GNU-only flags. Epoch→ISO8601 must use `date -u -r "$ts"` with `date -u -d "@$ts"` fallback. Locking uses `mkdir`.
- `jq` and `bash` are required; `sqlite3` optional — every sqlite call needs the JSONL/no-store fallback path.
- Tests run under the existing harness: `tests/lib.sh` (`assert_eq`, `finish`), fake `HOME` in `mktemp -d`, run all with `bash tests/run.sh`.
- All Solidtime API paths/field names live ONLY in the constants block and payload/API helper functions of `solidtime-sync.sh` — nowhere else. Task 4 verifies them against official docs and corrects them in that one place.
- Missing/unreadable `solidtime.conf` → sync exits 0 silently doing nothing. Never an error.

---

### Task 1: Remove `st_import_events` (SessionEnd timeout fix) + regression guard

The bash `while read` loop in `st_import_events` costs ~1.35 ms/line (subshell + `sed` per line), blowing the 5s hook budget at ~4k `events.log` lines. Its only consumer (`sq_timeline`) already falls back to reading the persisted `events.log`. Delete the import; keep the `events` table in the schema for old rows.

**Files:**
- Modify: `hooks/lib/db.sh` (delete the `st_import_events` function, lines 73–96)
- Modify: `hooks/session-end.sh` (delete the `st_import_events` call, line 80)
- Modify: `tests/db.test.sh` (drop the `--- st_import_events ---` block, lines 65–96; add perf regression)
- Test: `tests/db.test.sh`, `tests/session-end.test.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: `events.log` under `~/.claude/session-env/<sid>/` is now the canonical bracket/timeline source for finished sessions (later tasks rely on it persisting).

- [ ] **Step 1: Add the failing perf regression test**

In `tests/db.test.sh`, replace the whole `# --- st_import_events ---` block (from the `st_db_init` on line 66 through the `sNull` assertions on line 96) with:

```bash
# --- SessionEnd stays fast on huge event logs (v3.1.2 timeout fix) ---
# 20k lines through the whole hook must finish well inside the 5s hook budget.
big_sid="perf-big"
mkdir -p "$HOME/.claude/session-env/$big_sid"
echo 1700000000 > "$HOME/.claude/session-env/$big_sid/session-tracker"
awk 'BEGIN{ts=1700000000; for(i=0;i<5000;i++){printf "P %d\nT %d Bash\nD %d Bash\nS %d\n", ts, ts+1, ts+2, ts+3; ts+=10}}' \
  > "$HOME/.claude/session-env/$big_sid/events.log"
t0=$(date +%s)
printf '{"session_id":"%s","reason":"exit","cwd":"%s"}' "$big_sid" "$repo" \
  | bash "$DIR/../hooks/session-end.sh"
t1=$(date +%s)
elapsed=$((t1 - t0))
assert_eq "session-end under 5s on 20k events" "1" "$([ "$elapsed" -lt 5 ] && echo 1 || echo 0)"
one2() { sqlite3 "$(st_db_path)" "$1"; }
assert_eq "big session row recorded" "1" "$(one2 "SELECT COUNT(*) FROM sessions WHERE session_id='$big_sid';")"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/db.test.sh`
Expected: `FAIL session-end under 5s on 20k events` (the import loop takes ~27s on 20k lines).

- [ ] **Step 3: Delete the import**

In `hooks/lib/db.sh`, delete the entire `st_import_events` function (the comment block starting `# st_import_events sid events_log` through its closing `}`).

In `hooks/session-end.sh`, delete the line:

```bash
      st_import_events "$SESSION_ID" "$EVENTS_FILE" 2>/dev/null || true
```

(the `if st_upsert_session ...; then` / `exit 0` around it stays).

- [ ] **Step 4: Run tests to verify pass**

Run: `bash tests/db.test.sh && bash tests/session-end.test.sh && bash tests/session-query.test.sh`
Expected: all PASS (timeline tests still pass — they read `events.log` via the fallback).

- [ ] **Step 5: Commit**

```bash
git add hooks/lib/db.sh hooks/session-end.sh tests/db.test.sh
git commit -m "fix(hooks): drop per-line events import that timed out SessionEnd on long sessions"
```

---

### Task 2: `mode=brackets` output in `active-time.awk`

Same accounting as today; new output mode emits one `start end` pair per engagement bracket (grace tail included). Scalar mode byte-identical to current behavior.

**Files:**
- Modify: `hooks/lib/active-time.awk`
- Test: `tests/active-time.test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `awk -v grace=G -v t_end=T -v mode=brackets -f active-time.awk events.log` → zero or more lines `"%d %d\n"` (epoch start, epoch end). Sum of `(end-start)` always equals scalar-mode output. Task 5 consumes this.

- [ ] **Step 1: Write failing tests**

Append to `tests/active-time.test.sh` before `finish`:

```bash
brackets() { awk -v grace="$1" -v t_end="$2" -v mode=brackets -f "$AWK" | tr '\n' ';'; }

# One interval, parked: single bracket includes the grace tail
assert_eq "brackets: parked" "1000 1180;" "$(printf 'P 1000\nS 1060\n' | brackets 120 5000)"

# Short gap: first bracket ends where the next begins
assert_eq "brackets: short gap" "1000 1100;1100 1160;" "$(printf 'P 1000\nS 1060\nP 1100\nS 1160\n' | brackets 120 1160)"

# Long gap capped: first bracket ends at stop+grace
assert_eq "brackets: capped gap" "1000 1180;1300 1360;" "$(printf 'P 1000\nS 1060\nP 1300\nS 1360\n' | brackets 120 1360)"

# Open bracket runs to t_end
assert_eq "brackets: live open" "1000 1100;" "$(printf 'P 1000\n' | brackets 120 1100)"

# Empty log: no output
assert_eq "brackets: empty" "" "$(printf '' | brackets 120 1000)"

# Sum of brackets equals scalar output on a mixed scenario
mixed='P 1000\nT 1005 Edit\nD 1040 Edit\nS 1060\nP 1300\nSF 1360\n'
scalar_out="$(printf "$mixed" | active 120 5000)"
sum_out="$(printf "$mixed" | awk -v grace=120 -v t_end=5000 -v mode=brackets -f "$AWK" | awk '{s+=$2-$1} END{printf "%d", s+0}')"
assert_eq "brackets sum equals scalar" "$scalar_out" "$sum_out"
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/active-time.test.sh`
Expected: new assertions FAIL (mode ignored today → scalar number printed, not pairs).

- [ ] **Step 3: Implement**

Replace the body of `hooks/lib/active-time.awk` action/END blocks with (comment header stays, add a line documenting `mode`):

```awk
BEGIN { open = -1; last_stop = -1; bstart = -1; active = 0; if (grace == "" || grace + 0 <= 0) grace = 120 }
{ kind = $1; ts = $2 + 0 }
kind == "P" || kind == "T" || kind == "D" || kind == "DF" {
  if (last_stop >= 0) {
    gap = ts - last_stop
    if (gap < 0) gap = 0
    credit = (gap < grace ? gap : grace)
    active += credit
    if (mode == "brackets" && bstart >= 0) printf "%d %d\n", bstart, last_stop + credit
    bstart = -1
    last_stop = -1
  }
  if (open < 0) open = ts
  if (bstart < 0) bstart = ts
  next
}
kind == "S" || kind == "SF" {
  if (open >= 0) {
    d = ts - open
    if (d > 0) active += d
    open = -1
  }
  last_stop = ts
  next
}
END {
  if (open >= 0) {
    d = t_end - open
    if (d > 0) active += d
    if (mode == "brackets" && bstart >= 0 && t_end > bstart) printf "%d %d\n", bstart, t_end
  } else if (last_stop >= 0) {
    gap = t_end - last_stop
    if (gap < 0) gap = 0
    credit = (gap < grace ? gap : grace)
    active += credit
    if (mode == "brackets" && bstart >= 0) printf "%d %d\n", bstart, last_stop + credit
  }
  if (active < 0) active = 0
  if (mode != "brackets") printf "%d", active
}
```

- [ ] **Step 4: Run to verify pass (including all pre-existing scalar assertions)**

Run: `bash tests/active-time.test.sh`
Expected: PASS, zero failures.

- [ ] **Step 5: Commit**

```bash
git add hooks/lib/active-time.awk tests/active-time.test.sh
git commit -m "feat(active-time): brackets output mode emitting start/end per engagement"
```

---

### Task 3: `solidtime-sync.sh` skeleton — config, log, rotation, lock

**Files:**
- Create: `hooks/lib/solidtime-sync.sh`
- Create: `tests/solidtime-sync.test.sh`

**Interfaces:**
- Consumes: `hooks/lib/db.sh` (`st_has_sqlite`, `st_db_path`), deployed `active-time.awk`.
- Produces (used by every later task): executable `solidtime-sync.sh [--session SID] [--verbose]`; config at `$HOME/.claude/session-env/solidtime.conf` (`SOLIDTIME_URL`, `SOLIDTIME_TOKEN`, `SOLIDTIME_ORG_ID`, optional `SOLIDTIME_MEMBER_ID`); log at `$HOME/.claude/session-env/solidtime-sync.log`; lock dir `$HOME/.claude/session-env/solidtime-sync.lock`; internal helpers `_sl_log MSG`, `_sl_iso8601 EPOCH`.

- [ ] **Step 1: Write failing tests**

Create `tests/solidtime-sync.test.sh`:

```bash
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

finish
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/solidtime-sync.test.sh`
Expected: FAIL (script does not exist).

- [ ] **Step 3: Implement the skeleton**

Create `hooks/lib/solidtime-sync.sh`:

```bash
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
```

Also add the runner glue: nothing needed — `tests/run.sh` picks up any `*.test.sh` automatically.

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/solidtime-sync.test.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add hooks/lib/solidtime-sync.sh tests/solidtime-sync.test.sh
git commit -m "feat(sync): solidtime-sync skeleton — config, logging, rotation, portable lock"
```

---

### Task 4: Verify the Solidtime API contract; write API notes; correct constants

The spec's endpoint paths and field names come from research, not from a probe. Fix that before writing the posting code.

**Files:**
- Create: `docs/superpowers/specs/2026-08-21-solidtime-api-notes.md`
- Modify (only if the docs disagree with the constants): `hooks/lib/solidtime-sync.sh` constants block

**Interfaces:**
- Produces: confirmed values for — time-entry create endpoint + required fields (incl. whether `member_id` is required and how to obtain it), project list/create endpoint + fields, tag list/create endpoint + fields, auth header form, any rate limits. Tasks 5–6 must use the confirmed names in payloads AND test fixtures.

- [ ] **Step 1: Fetch the official API reference**

Fetch `https://docs.solidtime.io/` and follow its API reference section (WebFetch or `curl -s` + reading). If the hosted docs are unreachable, read the OpenAPI spec in the repo: `https://github.com/solidtime-io/solidtime` (`openapi.json.ts` or generated spec under the api docs workflow).

- [ ] **Step 2: Write the notes file**

`docs/superpowers/specs/2026-08-21-solidtime-api-notes.md` — for each of: create time entry, list/create project, list/create tag, current user/membership: exact method+path, required/optional body fields with types, one example request/response body, auth header. Note explicitly whether retroactive `start`/`end` are accepted and whether `member_id` is required on entry creation.

- [ ] **Step 3: Correct the constants and record deltas**

Update `_SL_API_*` constants and (in later tasks' fixtures) field names to the confirmed values. Add a "Deltas vs design spec" section at the bottom of the notes file — even if empty ("none").

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-08-21-solidtime-api-notes.md hooks/lib/solidtime-sync.sh
git commit -m "docs(sync): verified Solidtime API contract; align sync constants"
```

---

### Task 5: Post brackets as time entries with incremental ledger

Core sync of ONE session. Uses a `curl` PATH shim in tests; payload field names must match Task 4's notes (adjust the fixture assertions if Task 4 changed them).

**Files:**
- Modify: `hooks/lib/solidtime-sync.sh`
- Test: `tests/solidtime-sync.test.sh`

**Interfaces:**
- Consumes: `mode=brackets` awk output (Task 2); helpers from Task 3.
- Produces: `_sl_sync_session SID` — posts every unposted bracket of a finished session, appending the bracket index to `$HOME/.claude/session-env/SID/solidtime-synced` after each 2xx, then a final `done` line. `_sl_resolve_project NAME` / `_sl_resolve_tag NAME` are stubbed here returning empty (real in Task 6).

- [ ] **Step 1: Write failing tests**

Append to `tests/solidtime-sync.test.sh` (before `finish`), replacing nothing:

```bash
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
```

(`1970-01-01T00:16:40Z` is epoch 1000 — bracket starts are tiny epochs in fixtures.)

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/solidtime-sync.test.sh`
Expected: new assertions FAIL (no posting logic yet).

- [ ] **Step 3: Implement**

In `solidtime-sync.sh`, replace the skeleton tail (between `_sl_log "sync run start ..."` and `_sl_log "sync run end"`) with:

```bash
# Placeholder resolvers until the cache task lands: no project/tag ids.
_sl_resolve_project() { printf ''; }
_sl_resolve_tag() { printf ''; }

# POST one time entry. Args: start_iso end_iso description project_id tag_id
# Prints HTTP code; body (for error logging) lands in $_SL_BODY.
_SL_BODY=""
_sl_post_entry() {
  local start="$1" end="$2" desc="$3" proj="$4" tag="$5"
  local url payload bodyf code
  # shellcheck disable=SC2059
  url="${SOLIDTIME_URL%/}/$(printf "$_SL_API_ENTRIES" "$SOLIDTIME_ORG_ID")"
  payload="$(jq -n --arg s "$start" --arg e "$end" --arg d "$desc" \
                  --arg p "$proj" --arg t "$tag" --arg m "${SOLIDTIME_MEMBER_ID:-}" '
    {start:$s, end:$e, description:$d, billable:false}
    + (if $p != "" then {project_id:$p} else {} end)
    + (if $t != "" then {tag_ids:[$t]} else {} end)
    + (if $m != "" then {member_id:$m} else {} end)')"
  bodyf="$(mktemp "${TMPDIR:-/tmp}/slbody.XXXXXX")"
  code="$(curl -sS -o "$bodyf" -w '%{http_code}' \
    -X POST "$url" \
    -H "Authorization: Bearer $SOLIDTIME_TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    --connect-timeout 5 --max-time 30 --retry 2 --retry-delay 2 \
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
  elif [ -f "$_SL_ENV/history.jsonl" ]; then
    name="$(jq -r --arg s "$sid" 'select(.session_id==$s) | .project_dir' "$_SL_ENV/history.jsonl" 2>/dev/null | tail -n1 | awk -F/ '{print $NF}')"
  fi
  [ -n "$name" ] && printf '%s' "$name" || basename "${PWD:-unknown}"
}

# Sync one finished session: post every bracket not yet in the ledger.
_sl_sync_session() {
  local sid="$1"
  local sdir="$_SL_ENV/$sid" ledger events issue host proj tag
  events="$sdir/events.log"; ledger="$sdir/solidtime-synced"
  [ -f "$events" ] || { _sl_log "session $sid: no events.log, skipping"; return 0; }
  grep -q '^done$' "$ledger" 2>/dev/null && return 0
  issue=""; [ -f "$sdir/issue-tag" ] && issue="$(head -n1 "$sdir/issue-tag" | tr -d '[:space:]')"
  host="$(hostname 2>/dev/null || echo unknown)"
  proj="$(_sl_resolve_project "$(_sl_session_project "$sid")")"
  tag=""; [ -n "$issue" ] && tag="$(_sl_resolve_tag "$issue")"
  local now idx=0 start end code
  now="$(date +%s)"
  while read -r start end; do
    [ -z "$start" ] && continue
    if ! grep -qx "$idx" "$ledger" 2>/dev/null; then
      code="$(_sl_post_entry "$(_sl_iso8601 "$start")" "$(_sl_iso8601 "$end")" \
                "$host · ${sid%%-*}:${idx}" "$proj" "$tag")"
      case "$code" in
        2*) printf '%s\n' "$idx" >> "$ledger" ;;
        *)  _sl_log "ERROR session $sid bracket $idx: HTTP $code ${_SL_BODY}"; return 1 ;;
      esac
    fi
    idx=$((idx + 1))
  done <<EOF
$(awk -v grace="${SESSION_IDLE_THRESHOLD_SECONDS:-120}" -v t_end="$now" -v mode=brackets \
     -f "$_SL_ENV/active-time.awk" "$events" 2>/dev/null)
EOF
  printf 'done\n' >> "$ledger"
  _sl_log "session $sid: synced $idx brackets"
  return 0
}

if [ -n "$ONLY_SID" ]; then
  _sl_sync_session "$ONLY_SID" || true
fi
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/solidtime-sync.test.sh`
Expected: PASS. Also run `bash tests/run.sh` — everything green.

- [ ] **Step 5: Commit**

```bash
git add hooks/lib/solidtime-sync.sh tests/solidtime-sync.test.sh
git commit -m "feat(sync): post active brackets as time entries with incremental ledger"
```

---

### Task 6: Project and tag resolution with local cache

**Files:**
- Modify: `hooks/lib/solidtime-sync.sh` (replace the placeholder `_sl_resolve_project` / `_sl_resolve_tag`)
- Test: `tests/solidtime-sync.test.sh`

**Interfaces:**
- Consumes: `_SL_API_PROJECTS` / `_SL_API_TAGS` constants (Task 4-confirmed), curl shim.
- Produces: `_sl_resolve_project NAME` and `_sl_resolve_tag NAME` → print the Solidtime id (create-on-miss), caching in `$HOME/.claude/session-env/solidtime-cache.json` as `{"projects":{name:id},"tags":{name:id}}`. On any API failure: print empty string (entry posts without project/tag rather than failing the sync).

- [ ] **Step 1: Write failing tests**

Append before `finish` (extend the shim: when the URL contains `/projects` or `/tags` and method is GET, body is `{"data":[{"id":"p1","name":"repo"}]}`; adjust the shim to write that body when `-X POST` is absent — concretely, replace the shim's body-write line with:

```bash
if printf '%s' "$*" | grep -q -- '-X POST'; then
  [ -n "$out" ] && printf '{"data":{"id":"new-1"}}' > "$out"
else
  [ -n "$out" ] && printf '{"data":[{"id":"p1","name":"repo"}]}' > "$out"
fi
```

then the assertions):

```bash
# ---- project/tag cache ----
rm -f "$SE/solidtime-cache.json"
: > "$CURL_CAPTURE"; : > "$CURL_CTRL"
SID3="sess-proj"; mkdir -p "$SE/$SID3"
printf 'P 3000\nS 3100\n' > "$SE/$SID3/events.log"
( cd "$TMP" && mkdir -p repo && cd repo && bash "$SYNC" --session "$SID3" ) >/dev/null 2>&1
assert_eq "cache file created" "1" "$([ -f "$SE/solidtime-cache.json" ] && echo 1 || echo 0)"
assert_eq "project id cached" "p1" "$(jq -r '.projects.repo' "$SE/solidtime-cache.json")"
calls_first=$(wc -l < "$CURL_CAPTURE" | tr -d ' ')

# second session, same project: no extra list call (cache hit)
SID4="sess-proj2"; mkdir -p "$SE/$SID4"
printf 'P 4000\nS 4100\n' > "$SE/$SID4/events.log"
: > "$CURL_CAPTURE"
( cd "$TMP/repo" && bash "$SYNC" --session "$SID4" ) >/dev/null 2>&1
assert_eq "cache hit: only the entry POST" "1" "$(wc -l < "$CURL_CAPTURE" | tr -d ' ')"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/solidtime-sync.test.sh` — new assertions FAIL (resolvers return empty, no cache written).

- [ ] **Step 3: Implement**

Replace the two placeholder resolvers with:

```bash
_sl_cache_get() { jq -r --arg k "$2" ".$1[\$k] // empty" "$_SL_CACHE" 2>/dev/null; }
_sl_cache_put() {
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/slcache.XXXXXX")"
  jq --arg k "$2" --arg v "$3" ".$1[\$k] = \$v" "$_SL_CACHE" 2>/dev/null > "$tmp" \
    || jq -n --arg k "$2" --arg v "$3" "{projects:{},tags:{}} | .$1[\$k] = \$v" > "$tmp"
  mv "$tmp" "$_SL_CACHE"
}

# GET list, find by name; POST create on miss. Args: kind(projects|tags) api_fmt name
_sl_resolve() {
  local kind="$1" fmt="$2" name="$3" id url bodyf code
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
    code="$(curl -sS -o "$bodyf" -w '%{http_code}' -X POST "$url" \
      -H "Authorization: Bearer $SOLIDTIME_TOKEN" -H "Content-Type: application/json" -H "Accept: application/json" \
      --connect-timeout 5 --max-time 15 \
      -d "$(jq -n --arg n "$name" '{name:$n}')" 2>/dev/null)"
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
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/solidtime-sync.test.sh` — PASS.

- [ ] **Step 5: Commit**

```bash
git add hooks/lib/solidtime-sync.sh tests/solidtime-sync.test.sh
git commit -m "feat(sync): resolve+create Solidtime projects/tags with local id cache"
```

---

### Task 7: Pending-session discovery + hook wiring

**Files:**
- Modify: `hooks/lib/solidtime-sync.sh` (discovery when no `--session`)
- Modify: `hooks/session-start.sh` (deploy `solidtime-sync.sh`; background retry launch)
- Modify: `hooks/session-end.sh` (background launch with own sid)
- Test: `tests/solidtime-sync.test.sh`, `tests/session-start.test.sh`, `tests/session-end.test.sh`

**Interfaces:**
- Consumes: history store via `db.sh` (`st_has_sqlite`, `st_db_path`) and `history.jsonl`, same source rules as `session-query.sh`.
- Produces: running `solidtime-sync.sh` with no `--session` syncs every ended session whose ledger lacks `done`. Hooks launch it detached: `( bash "$HOME/.claude/session-env/solidtime-sync.sh" --session "$SESSION_ID" >/dev/null 2>&1 & )`.

- [ ] **Step 1: Write failing discovery test**

Append to `tests/solidtime-sync.test.sh` before `finish`:

```bash
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/solidtime-sync.test.sh` — FAIL (no discovery; run without `--session` does nothing).

- [ ] **Step 3: Implement discovery**

In `solidtime-sync.sh`, replace the final `if [ -n "$ONLY_SID" ] ...` block with:

```bash
_sl_pending_sids() {
  if command -v st_has_sqlite >/dev/null 2>&1 && st_has_sqlite && [ -f "$(st_db_path)" ]; then
    sqlite3 "$(st_db_path)" "SELECT session_id FROM sessions ORDER BY end_ts;" 2>/dev/null
  elif [ -f "$_SL_ENV/history.jsonl" ]; then
    jq -r '.session_id' "$_SL_ENV/history.jsonl" 2>/dev/null | sort -u
  fi
}

if [ -n "$ONLY_SID" ]; then
  _sl_sync_session "$ONLY_SID" || true
else
  while IFS= read -r sid; do
    [ -z "$sid" ] && continue
    grep -q '^done$' "$_SL_ENV/$sid/solidtime-synced" 2>/dev/null && continue
    _sl_sync_session "$sid" || true
  done <<EOF
$(_sl_pending_sids)
EOF
fi
```

- [ ] **Step 4: Wire the hooks**

`hooks/session-start.sh` — add `solidtime-sync.sh` to the deploy loop (the `for f in ...` list becomes `active-time.awk db.sh session-query.sh solidtime-sync.sh`), and after the timestamp block, before the final `echo`, add:

```bash
# Retry any pending Solidtime syncs in the background; never blocks the hook.
if [ -f "$HOME/.claude/session-env/solidtime.conf" ]; then
  ( bash "$HOME/.claude/session-env/solidtime-sync.sh" >/dev/null 2>&1 & ) 2>/dev/null || true
fi
```

`hooks/session-end.sh` — right before the `exit 0` inside the successful-upsert branch (where `st_import_events` used to be), add:

```bash
      if [ -f "$HOME/.claude/session-env/solidtime.conf" ]; then
        ( bash "$HOME/.claude/session-env/solidtime-sync.sh" --session "$SESSION_ID" >/dev/null 2>&1 & ) 2>/dev/null || true
      fi
```

Add to `tests/session-start.test.sh` (following its existing deploy assertions): assert `"$HOME/.claude/session-env/solidtime-sync.sh"` exists after running the hook. In `tests/session-end.test.sh`: create `solidtime.conf` in the fake HOME plus a stub `solidtime-sync.sh` that writes `$HOME/launched` when invoked; run the hook; poll up to 2s for the marker; assert it exists and the hook itself returned immediately (elapsed < 2s).

- [ ] **Step 5: Run the whole suite**

Run: `bash tests/run.sh`
Expected: all files PASS.

- [ ] **Step 6: Commit**

```bash
git add hooks/lib/solidtime-sync.sh hooks/session-start.sh hooks/session-end.sh tests/
git commit -m "feat(sync): pending-session discovery and background hook wiring"
```

---

### Task 8: `sync` object in `session-query.sh status`

**Files:**
- Modify: `hooks/lib/session-query.sh` (`sq_status`)
- Test: `tests/session-query.test.sh`

**Interfaces:**
- Consumes: `solidtime.conf` existence, per-session ledgers, `solidtime-sync.log`.
- Produces: `status` JSON gains `sync: {configured: bool, pending: n, last_error: "..."}` (`last_error` = last log line containing ` ERROR `, empty when none). When unconfigured: `{configured:false, pending:0, last_error:""}`.

- [ ] **Step 1: Write failing test**

In `tests/session-query.test.sh`, after the existing `status` assertions:

```bash
# sync status: unconfigured
out="$(bash "$SQ" status --session none)"
assert_eq "sync unconfigured" "false" "$(printf '%s' "$out" | jq -r '.sync.configured')"

# configured with one pending session and one error line
printf 'SOLIDTIME_URL=x\nSOLIDTIME_TOKEN=y\nSOLIDTIME_ORG_ID=z\n' > "$HOME/.claude/session-env/solidtime.conf"
printf '2026-08-21T10:00:00 ERROR session s1 bracket 0: HTTP 500\n' > "$HOME/.claude/session-env/solidtime-sync.log"
out="$(bash "$SQ" status --session none)"
assert_eq "sync configured" "true" "$(printf '%s' "$out" | jq -r '.sync.configured')"
assert_eq "sync pending counts unsynced" "2" "$(printf '%s' "$out" | jq -r '.sync.pending')"
assert_eq "sync last error surfaced" "1" "$(printf '%s' "$out" | jq -r '.sync.last_error' | grep -c 'HTTP 500')"
rm -f "$HOME/.claude/session-env/solidtime.conf"
```

(`pending` = the two sessions `s1`/`s2` the test file already upserted, neither having a ledger.)

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/session-query.test.sh` — FAIL (`.sync` is null).

- [ ] **Step 3: Implement**

In `sq_status`, before the final `jq -n`, add:

```bash
  local sync_conf=false sync_pending=0 sync_err=""
  if [ -f "$HOME/.claude/session-env/solidtime.conf" ]; then
    sync_conf=true
    local psid
    while IFS= read -r psid; do
      [ -z "$psid" ] && continue
      grep -q '^done$' "$HOME/.claude/session-env/$psid/solidtime-synced" 2>/dev/null || sync_pending=$((sync_pending + 1))
    done <<EOF
$(if [ "$src" = sqlite ]; then sqlite3 "$(st_db_path)" "SELECT session_id FROM sessions;" 2>/dev/null
  elif [ "$src" = jsonl ]; then jq -r '.session_id' "$(_sq_hist)" 2>/dev/null | sort -u; fi)
EOF
    sync_err="$(grep ' ERROR ' "$HOME/.claude/session-env/solidtime-sync.log" 2>/dev/null | tail -n1)"
  fi
```

and extend the final `jq -n` with `--argjson sconf "$sync_conf" --argjson spend "$sync_pending" --arg serr "$sync_err"` and the object `sync:{configured:$sconf, pending:$spend, last_error:$serr}`.

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/session-query.test.sh` — PASS. Then `bash tests/run.sh` — all green.

- [ ] **Step 5: Commit**

```bash
git add hooks/lib/session-query.sh tests/session-query.test.sh
git commit -m "feat(status): surface solidtime sync health (configured/pending/last_error)"
```

---

### Task 9: Commands, skill, README

Prompt/snippet files only — no query logic in them (project rule). Follow the frontmatter style of `commands/tag.md`.

**Files:**
- Create: `commands/sync.md`, `commands/sync-setup.md`, `skills/sync/SKILL.md`
- Modify: `README.md`

- [ ] **Step 1: `commands/sync-setup.md`**

Frontmatter: `description: Configure Solidtime sync (URL, API token, organization)` + `disable-model-invocation: true`. Behavior: (1) explain where to create an API token in the Solidtime UI (profile → API tokens) and where the organization id is visible; (2) collect `SOLIDTIME_URL`, token, org id from the user; (3) write `~/.claude/session-env/solidtime.conf` with the three values and `chmod 600`; (4) verify by running `bash ~/.claude/session-env/solidtime-sync.sh --verbose` and showing the result; never echo the token back in full (show first 6 chars).

- [ ] **Step 2: `commands/sync.md`**

Frontmatter: `description: Sync finished sessions to Solidtime now and show sync health`. Behavior: run `bash ~/.claude/session-env/solidtime-sync.sh --verbose`; then show `bash ~/.claude/session-env/session-query.sh status` `.sync` object (pending, last_error) and the last 10 lines of `~/.claude/session-env/solidtime-sync.log`. If unconfigured, point to `/session-tracker:sync-setup`.

- [ ] **Step 3: `skills/sync/SKILL.md`**

Frontmatter name `sync`, description: 'Use when user asks to sync time to Solidtime, "sincroniza com o solidtime", "manda as horas", "sync sessions", or asks whether sync is working/failing.' Body: same behavior as `commands/sync.md` (invoke the deployed script + status), plus: on errors shown in the log, explain the HTTP status in plain words (401 → token invalid, re-run setup; 404 → URL/org wrong; timeouts → instance unreachable, data is safe locally and will retry).

- [ ] **Step 4: README section**

Add "## Sync to Solidtime (optional)" after the Issue Tagging section: what it does (each active bracket becomes a time entry; multi-machine unified dashboards), setup via `/session-tracker:sync-setup`, that sync is background/local-first (nothing is lost when the instance is down), where the log lives, and that the token stays in a `chmod 600` file. Reference the spec file for design details. No pasted scripts (project rule).

- [ ] **Step 5: Full suite + commit**

Run: `bash tests/run.sh` — all green.

```bash
git add commands/sync.md commands/sync-setup.md skills/sync/SKILL.md README.md
git commit -m "feat(sync): sync + sync-setup commands, sync skill, README docs"
```

---

## Post-plan checks

- `bash tests/run.sh` fully green on macOS AND Linux if both available.
- Manual smoke (optional, needs a real instance): run `/session-tracker:sync-setup` against a docker-compose Solidtime, end a session, confirm entries appear with project/tag; correct `_SL_API_*` constants if the probe in Task 4 missed something.
- Release via `/release` (minor bump: new feature + bug fix).
