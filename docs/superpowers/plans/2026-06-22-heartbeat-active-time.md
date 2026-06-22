# Heartbeat-based Active Time Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make each session report real working time (additive, prompt→stop bracket + bounded reading grace) instead of inflating wall-clock, so concurrent sessions on the same project stay consistent; add tool heartbeats for a forensic timeline.

**Architecture:** A single canonical awk program (`hooks/lib/active-time.awk`) computes active seconds from one `events.log`. Two new hooks append tool heartbeats (`T`/`D`). `session-end.sh` and the statusline/skills all surface *active* as the headline number, demoting wall-clock to metadata. The statusline and skill snippets inline an equivalent of the awk because they are copied out of the plugin and cannot reference plugin-internal files.

**Tech Stack:** POSIX `sh`/`bash`, one-true-awk (BSD awk on macOS — no `strftime`, arrays OK), `jq`, plain-bash test harness (no framework).

## Global Constraints

- **Hooks must never block.** Every hook runs under `set -uo pipefail`, wraps its body in `{ ... } || exit 0`, and ends with `exit 0`. A tracker failure must never interrupt the user's session.
- **Detail level B only.** Heartbeats log the tool *type* (`Edit`, `Bash`), never arguments, paths, or command contents.
- **`events.log` line format** (whitespace-separated, time-ordered, append-only):
  `P <ts>` prompt · `T <ts> <Tool>` tool start · `D <ts> <Tool>` tool done · `S <ts>` stop.
- **`grace` default is 120** seconds, read from `SESSION_IDLE_THRESHOLD_SECONDS` (reinterpreted as the reading-tail cap). Old default was 300.
- **awk must be one-true-awk compatible** (no `strftime`, no gawk extensions). Format epoch→clock time in shell with `date -r <ts>` (macOS) falling back to `date -d @<ts>` (GNU).
- **`history.jsonl` schema is unchanged.** `active_seconds`, `idle_seconds`, `duration_seconds` all stay; only how `active_seconds` is computed changes.
- **Active is a pure function of one session's own `events.log`.** No reads of sibling sessions.

---

### Task 1: Active-time awk library + unit tests

The riskiest piece — the additive accounting. Build it test-first as a standalone awk program so every edge case is pinned before anything depends on it.

**Files:**
- Create: `tests/lib.sh`
- Create: `tests/active-time.test.sh`
- Create: `hooks/lib/active-time.awk`
- Create: `tests/run.sh`

**Interfaces:**
- Produces: `hooks/lib/active-time.awk` — reads an `events.log` (path arg or stdin), takes `-v grace=<sec>` and `-v t_end=<epoch>`, prints active seconds (integer) to stdout.
- Produces: `tests/lib.sh` — shell helpers `assert_eq <desc> <expected> <actual>` and `finish` (prints summary, exits non-zero if any failed).

- [ ] **Step 1: Write the test harness helper**

Create `tests/lib.sh`:

```bash
# Minimal test helpers. Source from *.test.sh files.
TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
  # assert_eq <description> <expected> <actual>
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
  fi
}

finish() {
  printf '\n%s: %d run, %d failed\n' "${0##*/}" "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
```

- [ ] **Step 2: Write the failing test**

Create `tests/active-time.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
AWK="$DIR/../hooks/lib/active-time.awk"

active() { awk -v grace="$1" -v t_end="$2" -f "$AWK"; }

# Empty log → 0
assert_eq "empty log is zero" "0" "$(printf '' | active 120 1000)"

# One prompt→stop interval of 60s
assert_eq "one working interval" "60" "$(printf 'P 1000\nS 1060\n' | active 120 1060)"

# Parked after stop: only grace (120) credited on top of the 60s of work
assert_eq "parked credits only grace" "180" "$(printf 'P 1000\nS 1060\n' | active 120 5000)"

# Short reading gap (<grace) fully credited: 60 + 40 + 60
assert_eq "short reading gap credited" "160" "$(printf 'P 1000\nS 1060\nP 1100\nS 1160\n' | active 120 1160)"

# Long reading gap capped at grace: 60 + 120 + 60
assert_eq "long gap capped at grace" "240" "$(printf 'P 1000\nS 1060\nP 1300\nS 1360\n' | active 120 1360)"

# Live mid-response: open bracket runs to t_end
assert_eq "live mid-response" "100" "$(printf 'P 1000\n' | active 120 1100)"

# Tool events hold the bracket open when Stop is missing (crash)
assert_eq "tools hold open bracket" "200" "$(printf 'P 1000\nT 1010 Read\nD 1050 Read\n' | active 120 1200)"

# Tools inside a bracket do not change the working total
assert_eq "tools inside bracket" "60" "$(printf 'P 1000\nT 1005 Edit\nD 1040 Edit\nS 1060\n' | active 120 1060)"

# Out-of-order / negative gaps are guarded: 60 + 0 + 20
assert_eq "negative gap guarded" "80" "$(printf 'P 1000\nS 1060\nP 1050\nS 1070\n' | active 120 1070)"

finish
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/active-time.test.sh`
Expected: FAIL — awk cannot open `hooks/lib/active-time.awk` (file does not exist), assertions report empty actuals.

- [ ] **Step 4: Implement the awk program**

Create `hooks/lib/active-time.awk`:

```awk
# active-time.awk — active (working) seconds from an events.log.
#
# Event lines (whitespace-separated, time-ordered):
#   P <ts>          prompt submitted  (engagement begins)
#   T <ts> <tool>   tool started      (keeps engagement open)
#   D <ts> <tool>   tool done         (keeps engagement open)
#   S <ts>          Claude stopped    (engagement ends; reading tail begins)
#
# Pass with -v:
#   grace  reading-tail cap in seconds (credited after a Stop before the next
#          engagement is treated as idle)
#   t_end  terminal epoch — `now` for a live session, `end_ts` at SessionEnd
#
# Prints active seconds (integer) to stdout.
BEGIN { open = -1; last_stop = -1; active = 0 }
{ kind = $1; ts = $2 + 0 }
kind == "P" || kind == "T" || kind == "D" {
  if (last_stop >= 0) {
    gap = ts - last_stop
    if (gap < 0) gap = 0
    active += (gap < grace ? gap : grace)
    last_stop = -1
  }
  if (open < 0) open = ts
  next
}
kind == "S" {
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
  } else if (last_stop >= 0) {
    gap = t_end - last_stop
    if (gap < 0) gap = 0
    active += (gap < grace ? gap : grace)
  }
  if (active < 0) active = 0
  printf "%d", active
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/active-time.test.sh`
Expected: PASS — `9 run, 0 failed`.

- [ ] **Step 6: Add the test runner**

Create `tests/run.sh`:

```bash
#!/usr/bin/env bash
# Run every *.test.sh in this directory; exit non-zero if any fail.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
rc=0
for f in "$DIR"/*.test.sh; do
  bash "$f" || rc=1
done
exit "$rc"
```

- [ ] **Step 7: Run the full suite**

Run: `bash tests/run.sh`
Expected: PASS — the active-time suite reports `9 run, 0 failed`.

- [ ] **Step 8: Commit**

```bash
git add hooks/lib/active-time.awk tests/lib.sh tests/active-time.test.sh tests/run.sh
git commit -m "feat: add additive active-time awk library with unit tests"
```

---

### Task 2: Tool-heartbeat hooks (Pre/PostToolUse)

**Files:**
- Create: `hooks/pre-tool-use.sh`
- Create: `hooks/post-tool-use.sh`
- Modify: `hooks/hooks.json`
- Create: `tests/hooks.test.sh`

**Interfaces:**
- Consumes: hook stdin JSON with `.session_id` and `.tool_name`.
- Produces: appends `T <ts> <Tool>` (pre) / `D <ts> <Tool>` (post) to `~/.claude/session-env/<session_id>/events.log`, where `<Tool>` is `.tool_name` stripped of whitespace.

- [ ] **Step 1: Write the failing test**

Create `tests/hooks.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$DIR/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
SID="test-session-123"
EV="$TMP/.claude/session-env/$SID/events.log"

# PreToolUse appends a T line carrying the tool type
echo '{"session_id":"'"$SID"'","tool_name":"Edit"}' | bash "$ROOT/hooks/pre-tool-use.sh"
line=$(tail -n1 "$EV")
assert_eq "pre-tool-use kind is T" "T" "$(echo "$line" | awk '{print $1}')"
assert_eq "pre-tool-use logs tool type" "Edit" "$(echo "$line" | awk '{print $3}')"

# PostToolUse appends a D line
echo '{"session_id":"'"$SID"'","tool_name":"Bash"}' | bash "$ROOT/hooks/post-tool-use.sh"
line=$(tail -n1 "$EV")
assert_eq "post-tool-use kind is D" "D" "$(echo "$line" | awk '{print $1}')"
assert_eq "post-tool-use logs tool type" "Bash" "$(echo "$line" | awk '{print $3}')"

# Missing session_id: no crash, no file
echo '{}' | bash "$ROOT/hooks/pre-tool-use.sh"; rc=$?
assert_eq "missing session_id exits clean" "0" "$rc"

finish
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/hooks.test.sh`
Expected: FAIL — `pre-tool-use.sh` / `post-tool-use.sh` do not exist (`bash: ... No such file`), assertions fail.

- [ ] **Step 3: Implement `pre-tool-use.sh`**

Create `hooks/pre-tool-use.sh`:

```bash
#!/usr/bin/env bash
# PreToolUse hook: records a tool-start heartbeat (T <ts> <tool>) in the session
# events log. Powers active-time accounting and the forensic timeline. Detail
# level B — tool type only, never arguments or paths. Must never block — exit 0.

set -uo pipefail

{
  INPUT=$(cat)
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
  [ -z "$SESSION_ID" ] && exit 0
  TOOL=$(echo "$INPUT" | jq -r '.tool_name // "?"' | tr -d '[:space:]')
  [ -z "$TOOL" ] && TOOL="?"

  SESSION_DIR="$HOME/.claude/session-env/$SESSION_ID"
  EVENTS_FILE="$SESSION_DIR/events.log"

  mkdir -p "$SESSION_DIR"
  printf 'T %s %s\n' "$(date +%s)" "$TOOL" >> "$EVENTS_FILE"
} || exit 0

exit 0
```

- [ ] **Step 4: Implement `post-tool-use.sh`**

Create `hooks/post-tool-use.sh`:

```bash
#!/usr/bin/env bash
# PostToolUse hook: records a tool-done heartbeat (D <ts> <tool>) in the session
# events log, pairing with the PreToolUse T line to measure tool duration. Detail
# level B — tool type only. Must never block — exit 0 on error.

set -uo pipefail

{
  INPUT=$(cat)
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
  [ -z "$SESSION_ID" ] && exit 0
  TOOL=$(echo "$INPUT" | jq -r '.tool_name // "?"' | tr -d '[:space:]')
  [ -z "$TOOL" ] && TOOL="?"

  SESSION_DIR="$HOME/.claude/session-env/$SESSION_ID"
  EVENTS_FILE="$SESSION_DIR/events.log"

  mkdir -p "$SESSION_DIR"
  printf 'D %s %s\n' "$(date +%s)" "$TOOL" >> "$EVENTS_FILE"
} || exit 0

exit 0
```

- [ ] **Step 5: Make the hooks executable**

Run: `chmod +x hooks/pre-tool-use.sh hooks/post-tool-use.sh`
Expected: no output.

- [ ] **Step 6: Register the hooks in `hooks/hooks.json`**

Add two top-level keys inside `"hooks"` (alongside the existing `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`). Insert after the `SessionEnd` block:

```json
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/pre-tool-use.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/post-tool-use.sh",
            "timeout": 5
          }
        ]
      }
    ],
```

- [ ] **Step 7: Verify `hooks.json` is valid JSON**

Run: `jq -e '.hooks.PreToolUse and .hooks.PostToolUse' hooks/hooks.json`
Expected: prints `true`, exit 0.

- [ ] **Step 8: Run the test to verify it passes**

Run: `bash tests/hooks.test.sh`
Expected: PASS — `5 run, 0 failed`.

- [ ] **Step 9: Commit**

```bash
git add hooks/pre-tool-use.sh hooks/post-tool-use.sh hooks/hooks.json tests/hooks.test.sh
git commit -m "feat: add Pre/PostToolUse heartbeat hooks (tool-type detail)"
```

---

### Task 3: Compute active additively in `session-end.sh`

**Files:**
- Modify: `hooks/session-end.sh:34-59`
- Create: `tests/session-end.test.sh`

**Interfaces:**
- Consumes: `hooks/lib/active-time.awk` (Task 1), the session's `events.log`, `SESSION_IDLE_THRESHOLD_SECONDS` (grace, default 120).
- Produces: a `history.jsonl` line whose `active_seconds` is the additive value and `idle_seconds = duration_seconds - active_seconds`.

- [ ] **Step 1: Write the failing test**

Create `tests/session-end.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$DIR/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
SID="end-session-1"
SDIR="$TMP/.claude/session-env/$SID"
mkdir -p "$SDIR"

# Session started 10 min ago; one 60s working interval, then parked until now.
now=$(date +%s)
start=$((now - 600))
echo "$start" > "$SDIR/session-tracker"
printf 'P %s\nS %s\n' "$start" "$((start + 60))" > "$SDIR/events.log"

echo '{"session_id":"'"$SID"'","reason":"exit","cwd":"'"$TMP"'"}' | bash "$ROOT/hooks/session-end.sh"

HIST="$TMP/.claude/session-env/history.jsonl"
line=$(tail -n1 "$HIST")
# active = 60s work + 120s grace (parked gap >> grace) = 180
assert_eq "additive active_seconds" "180" "$(echo "$line" | jq -r '.active_seconds')"
# idle = duration - active; duration is ~600 so idle is ~420 and consistent
dur=$(echo "$line" | jq -r '.duration_seconds')
act=$(echo "$line" | jq -r '.active_seconds')
idl=$(echo "$line" | jq -r '.idle_seconds')
assert_eq "idle = duration - active" "$((dur - act))" "$idl"

finish
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/session-end.test.sh`
Expected: FAIL — current subtractive logic computes a different `active_seconds` (≈ `duration`, since the single short gap is below the old 300s threshold), so `additive active_seconds` asserts `180` vs an actual near `600`.

- [ ] **Step 3: Replace the idle block with additive active**

In `hooks/session-end.sh`, replace the block currently at lines 34–59 (from `IDLE_THRESHOLD="${SESSION_IDLE_THRESHOLD_SECONDS:-300}"` through `ACTIVE_SECONDS=$((DURATION - IDLE_SECONDS))`) with:

```bash
  # Compute active (working) time additively from events.log via the shared awk
  # library: each prompt→stop bracket is fully active, plus up to `grace` seconds
  # of reading after each Stop. Falls back to wall-clock when no events exist
  # (e.g. session predates this version).
  GRACE="${SESSION_IDLE_THRESHOLD_SECONDS:-120}"
  EVENTS_FILE="$SESSION_DIR/events.log"
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  AWK_LIB="$SCRIPT_DIR/lib/active-time.awk"
  ACTIVE_SECONDS="$DURATION"
  if [ -f "$EVENTS_FILE" ] && [ -f "$AWK_LIB" ]; then
    COMPUTED=$(awk -v grace="$GRACE" -v t_end="$END_TS" -f "$AWK_LIB" "$EVENTS_FILE" 2>/dev/null || echo "")
    case "$COMPUTED" in
      ''|*[!0-9]*) : ;;
      *) ACTIVE_SECONDS="$COMPUTED" ;;
    esac
  fi
  [ "$ACTIVE_SECONDS" -gt "$DURATION" ] && ACTIVE_SECONDS="$DURATION"
  IDLE_SECONDS=$((DURATION - ACTIVE_SECONDS))
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/session-end.test.sh`
Expected: PASS — `2 run, 0 failed`.

- [ ] **Step 5: Run the full suite (no regressions)**

Run: `bash tests/run.sh`
Expected: PASS — active-time (9), hooks (5), session-end (2), all `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add hooks/session-end.sh tests/session-end.test.sh
git commit -m "feat: compute active time additively at session end"
```

---

### Task 4: Statusline emits active, not wall-clock

**Files:**
- Modify: `statusline-snippet.sh`
- Create: `tests/statusline.test.sh`

**Interfaces:**
- Consumes: `$input` (statusline JSON with `.session_id`), the session's `events.log`, `SESSION_IDLE_THRESHOLD_SECONDS` (grace, default 120).
- Produces: `$session_time` (e.g. `3m`, `2h15m`) reflecting active time; falls back to wall-clock only when `events.log` is absent.

- [ ] **Step 1: Write the failing test**

Create `tests/statusline.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$DIR/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
SID="sl-session-1"
SDIR="$TMP/.claude/session-env/$SID"
mkdir -p "$SDIR"

now=$(date +%s)
start=$((now - 600))             # wall-clock would be 10m
echo "$start" > "$SDIR/session-tracker"
printf 'P %s\nS %s\n' "$start" "$((start + 60))" > "$SDIR/events.log"

input='{"session_id":"'"$SID"'"}'
session_time=""
. "$ROOT/statusline-snippet.sh"
# active = 60s work + 120s grace = 180s = 3m  (NOT the 10m wall-clock)
assert_eq "statusline shows active time" "3m" "$session_time"

# Legacy fallback: no events.log → wall-clock
rm -f "$SDIR/events.log"
session_time=""
. "$ROOT/statusline-snippet.sh"
assert_eq "statusline falls back to wall-clock" "10m" "$session_time"

finish
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/statusline.test.sh`
Expected: FAIL — the current snippet always emits wall-clock, so the first assertion gets `10m` instead of `3m`.

- [ ] **Step 3: Rewrite the computation block in `statusline-snippet.sh`**

Replace the body from `if [ -n "$sf" ] && [ -f "$sf" ]; then` through the closing `fi` of that block (the part that sets `start`/`elapsed`/`session_time`) with:

```bash
if [ -n "$sf" ] && [ -f "$sf" ]; then
  start=$(cat "$sf")
  now=$(date +%s)
  grace="${SESSION_IDLE_THRESHOLD_SECONDS:-120}"
  events="$(dirname "$sf")/events.log"
  if [ -f "$events" ]; then
    # Active (working) time: prompt→stop brackets plus up to `grace` reading tail.
    # Mirrors hooks/lib/active-time.awk (inlined because this snippet is copied
    # into the user's statusline, away from the plugin directory).
    secs=$(awk -v grace="$grace" -v t_end="$now" '
      BEGIN { open=-1; last=-1; a=0 }
      { k=$1; ts=$2+0 }
      k=="P"||k=="T"||k=="D" { if(last>=0){g=ts-last; if(g<0)g=0; a+=(g<grace?g:grace); last=-1} if(open<0)open=ts; next }
      k=="S" { if(open>=0){d=ts-open; if(d>0)a+=d; open=-1} last=ts; next }
      END { if(open>=0){d=t_end-open; if(d>0)a+=d} else if(last>=0){g=t_end-last; if(g<0)g=0; a+=(g<grace?g:grace)} if(a<0)a=0; printf "%d", a }
    ' "$events")
  else
    secs=$((now - start))   # legacy fallback: wall-clock
  fi
  case "$secs" in ''|*[!0-9]*) secs=0 ;; esac
  hours=$((secs / 3600))
  minutes=$(((secs % 3600) / 60))
  if [ $hours -gt 0 ]; then
    session_time="${hours}h${minutes}m"
  else
    session_time="${minutes}m"
  fi
fi
```

Also update the header comment block at the top of the file: change the description line from deriving elapsed time to "Derives **active** (working) time from the session's events.log; falls back to wall-clock when no events exist."

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/statusline.test.sh`
Expected: PASS — `2 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add statusline-snippet.sh tests/statusline.test.sh
git commit -m "feat: statusline reports active time with wall-clock fallback"
```

---

### Task 5: Update `session-status` skill (active as headline)

Documentation/skill change. The deliverable is verified by running the new snippet against a fixture.

**Files:**
- Modify: `skills/session-status/SKILL.md`

- [ ] **Step 1: Replace the Mechanism paragraph**

In `skills/session-status/SKILL.md`, replace the second Mechanism paragraph (the one starting "`UserPromptSubmit` and `Stop` hooks append `P <ts>` / `S <ts>`...") with:

```markdown
`UserPromptSubmit`/`Stop` and `PreToolUse`/`PostToolUse` hooks append events to
`events.log`: `P <ts>` (prompt), `T <ts> <tool>` / `D <ts> <tool>` (tool
start/done), `S <ts>` (stop). **Active (working) time** is computed additively:
each `prompt → stop` bracket counts in full, plus up to `grace` seconds of
reading after each `Stop` (`SESSION_IDLE_THRESHOLD_SECONDS`, default 120). A
session parked while you work elsewhere stops accruing after the grace, so the
number reflects real attention rather than wall-clock. Wall-clock elapsed is
reported as secondary context.
```

- [ ] **Step 2: Replace the Usage snippet**

Replace the bash block under `## Usage` with this active-first version:

```bash
start=$(cat "$CLAUDE_SESSION_FILE" 2>/dev/null)
if [ -n "$start" ]; then
  now=$(date +%s)
  elapsed=$((now - start))                       # wall-clock (secondary)
  grace="${SESSION_IDLE_THRESHOLD_SECONDS:-120}"
  EVENTS="$(dirname "$CLAUDE_SESSION_FILE")/events.log"

  active="$elapsed"                              # fallback when no events recorded
  if [ -f "$EVENTS" ]; then
    active=$(awk -v grace="$grace" -v t_end="$now" '
      BEGIN { open=-1; last=-1; a=0 }
      { k=$1; ts=$2+0 }
      k=="P"||k=="T"||k=="D" { if(last>=0){g=ts-last; if(g<0)g=0; a+=(g<grace?g:grace); last=-1} if(open<0)open=ts; next }
      k=="S" { if(open>=0){d=ts-open; if(d>0)a+=d; open=-1} last=ts; next }
      END { if(open>=0){d=t_end-open; if(d>0)a+=d} else if(last>=0){g=t_end-last; if(g<0)g=0; a+=(g<grace?g:grace)} if(a<0)a=0; printf "%d", a }
    ' "$EVENTS")
    case "$active" in ''|*[!0-9]*) active="$elapsed" ;; esac
  fi
  [ "$active" -gt "$elapsed" ] && active="$elapsed"
  idle=$((elapsed - active))

  fmt() { h=$(( $1 / 3600 )); m=$(( ($1 % 3600) / 60 )); [ "$h" -gt 0 ] && printf '%dh %dm' "$h" "$m" || printf '%dm' "$m"; }
  started=$(date -r "$start" "+%H:%M" 2>/dev/null || date -d "@$start" "+%H:%M" 2>/dev/null)
  echo "Trabalho: $(fmt "$active") · sessão aberta há $(fmt "$elapsed") (idle $(fmt "$idle"), desde ${started})"
else
  echo "Session file not found - hook may not be configured"
fi
```

- [ ] **Step 3: Update the Output Format and threshold note**

Under `## Output Format`, replace the first example line with:

```
Trabalho: 1h 50m · sessão aberta há 2h 15m (idle 25m, desde 14:30)
```

And replace the trailing threshold sentence with:

```
The reading grace after each Stop is configurable via `SESSION_IDLE_THRESHOLD_SECONDS` (default 120 = 2 minutes). Active time is the headline; wall-clock ("aberta há…") is shown as context only.
```

- [ ] **Step 4: Verify the snippet against a fixture**

Run:

```bash
TMP=$(mktemp -d); SID=ss-1; SDIR="$TMP/.claude/session-env/$SID"; mkdir -p "$SDIR"
now=$(date +%s); start=$((now-600))
echo "$start" > "$SDIR/session-tracker"
printf 'P %s\nS %s\n' "$start" "$((start+60))" > "$SDIR/events.log"
CLAUDE_SESSION_FILE="$SDIR/session-tracker"
# paste the Usage snippet here, or source a temp file containing it
```

Expected: output reads `Trabalho: 3m · sessão aberta há 10m (idle 7m, desde HH:MM)`.
Then `rm -rf "$TMP"`.

- [ ] **Step 5: Commit**

```bash
git add skills/session-status/SKILL.md
git commit -m "docs: make active time the headline in session-status skill"
```

---

### Task 6: Render active + forensic timeline in `session-history` skill

**Files:**
- Modify: `skills/session-history/SKILL.md`

- [ ] **Step 1: Switch the rendered/summed value to `active_seconds`**

In `skills/session-history/SKILL.md`:

- In the "Example: quanto trabalhei hoje" jq block, change `.duration_seconds` to `.active_seconds` in the projected array.
- In the "Sum total for the day" jq block, change `map(.duration_seconds)` to `map(.active_seconds)`.
- In the Mechanism JSON example, leave the schema as-is but add a sentence after it: "The `active_seconds` field (working time) is what the table and totals report; `duration_seconds` (wall-clock) is available if you explicitly ask for it."
- In the Output Format table, rename the `Duração` column to `Trabalho` and note the values are active time.

- [ ] **Step 2: Add the forensic timeline section**

Append this section before `## Edge cases`:

````markdown
## Forensic timeline (single session)

When the user wants the "filme" of a specific past session, read its
`events.log` (it persists at `~/.claude/session-env/<session_id>/events.log`
after the session ends; `history.jsonl` carries the `session_id`). Pair `T`/`D`
heartbeats per tool name to show time spent per tool inside each working
interval. awk does the counting/pairing (one-true-awk safe); the shell formats
epoch → `HH:MM`:

```bash
SID="$1"                                   # session_id from history.jsonl
EVENTS="$HOME/.claude/session-env/$SID/events.log"
[ -f "$EVENTS" ] || { echo "Sem timeline para a sessão $SID."; exit 0; }

awk '
  function flush(){
    if(p>0){
      s=""
      for(t in dur){ m=int(dur[t]/60); sec=dur[t]%60; s=s (s==""?"":", ") t " " m "m" sec "s" }
      printf "WORK %d %d %s\n", p, (laststop>0?laststop:p), s
      for(t in dur) delete dur[t]
      for(t in opents) delete opents[t]
    }
  }
  { k=$1; ts=$2+0; tool=$3 }
  k=="P" { flush(); p=ts; laststop=0 }
  k=="T" { if(p>0) opents[tool]=ts }
  k=="D" { if(p>0 && (tool in opents)){ d=ts-opents[tool]; if(d<0)d=0; dur[tool]+=d; delete opents[tool] } }
  k=="S" { laststop=ts }
  END { flush() }
' "$EVENTS" | while read -r _tag pts sts summary; do
  ph=$(date -r "$pts" +%H:%M 2>/dev/null || date -d "@$pts" +%H:%M)
  sh=$(date -r "$sts" +%H:%M 2>/dev/null || date -d "@$sts" +%H:%M)
  work=$((sts - pts)); [ "$work" -lt 0 ] && work=0
  printf '%s  prompt\n' "$ph"
  [ -n "$summary" ] && printf '       %s\n' "$summary"
  printf '%s  stop (trabalho %dm%02ds)\n' "$sh" "$((work/60))" "$((work%60))"
done
```

Renders e.g.:

```
09:13  prompt
       Read 0m12s, Edit 1m30s
09:31  stop (trabalho 18m02s)
09:35  prompt
       Bash 4m02s
09:42  stop (trabalho 7m10s)
```

Only tool *types* and durations are shown — no file paths or command contents
(detail level B).
````

- [ ] **Step 3: Verify the timeline snippet against a fixture**

Run:

```bash
TMP=$(mktemp -d); export HOME="$TMP"; SID=hist-1; SDIR="$TMP/.claude/session-env/$SID"; mkdir -p "$SDIR"
printf 'P 1000\nT 1005 Edit\nD 1095 Edit\nT 1100 Read\nD 1112 Read\nS 1200\n' > "$SDIR/events.log"
# paste the timeline snippet with SID set to hist-1
rm -rf "$TMP"
```

Expected: a `09/..:..  prompt` line, a tool summary containing `Edit 1m30s` and `Read 0m12s`, and a `stop (trabalho 3m20s)` line. (Clock times depend on local TZ; durations are fixed: Edit 90s, Read 12s, work 200s.)

- [ ] **Step 4: Commit**

```bash
git add skills/session-history/SKILL.md
git commit -m "docs: report active time and add forensic timeline to session-history"
```

---

### Task 7: Docs — CHANGELOG, README, reset-session check

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `README.md`
- Verify only (no change expected): `skills/reset-session/SKILL.md`

- [ ] **Step 1: Confirm `reset-session` already clears events.log**

Run: `grep -n 'events.log' skills/reset-session/SKILL.md`
Expected: shows the `: > "$(dirname "$CLAUDE_SESSION_FILE")/events.log"` line. The additive model needs no further change — truncating `events.log` resets active to zero. No edit.

- [ ] **Step 2: Add a CHANGELOG entry**

Insert a new section directly under the header block (above `## [2.5.0] - 2026-05-13`):

```markdown
## [Unreleased]

### Added
- `PreToolUse`/`PostToolUse` hooks append tool heartbeats (`T <ts> <tool>` /
  `D <ts> <tool>`, tool type only) to `events.log`.
- Forensic per-session timeline in the `session-history` skill, showing time
  spent per tool type inside each working interval.
- Shared `hooks/lib/active-time.awk` library and a plain-bash test suite under
  `tests/`.

### Changed
- **Active time is now computed additively** (prompt→stop brackets plus a
  bounded reading grace) instead of subtracting idle gaps from wall-clock. A
  session parked while you work in another session on the same project no longer
  inflates — it stops accruing after the grace. Active is now the headline
  number in the statusline, `session-status`, and `session-history`; wall-clock
  is shown as secondary context.
- `SESSION_IDLE_THRESHOLD_SECONDS` is reinterpreted as the reading-grace cap and
  its default changes from 300s to **120s**.
```

- [ ] **Step 3: Update README time-tracking description**

In `README.md`:

- Replace the "Active vs idle time" bullet (line ~13) with:

```markdown
- **Active (working) time** - active time is computed additively from `events.log`: each prompt→stop bracket counts in full, plus up to `SESSION_IDLE_THRESHOLD_SECONDS` (default 120s) of reading after each turn. A session left open while you work elsewhere stops accruing, so concurrent sessions on the same project stay honest. `PreToolUse`/`PostToolUse` heartbeats record tool activity for a forensic timeline.
```

- Replace the example line (~83) with:

```markdown
Trabalho: 48m · sessão aberta há 1h 23m (idle 35m, desde 14:30)
```

- Replace the idle explanation paragraph (~86) with:

```markdown
Active time credits each prompt→stop bracket fully, plus up to `SESSION_IDLE_THRESHOLD_SECONDS` seconds of reading after each turn (default 120). Tune it, e.g. `export SESSION_IDLE_THRESHOLD_SECONDS=60` for a stricter 1-minute reading grace. Wall-clock ("aberta há…") is shown only as context.
```

- Replace the mechanism bullet (~168) with:

```markdown
6. `UserPromptSubmit`/`Stop` and `PreToolUse`/`PostToolUse` hooks append `P`/`S` and `T`/`D <tool>` lines to `events.log`; active time is computed additively (prompt→stop brackets plus a bounded reading grace) by `hooks/lib/active-time.awk`
```

- [ ] **Step 4: Run the full suite once more**

Run: `bash tests/run.sh`
Expected: PASS — all suites `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md README.md
git commit -m "docs: document additive active time and tool heartbeats"
```

---

## Self-Review notes

- **Spec coverage:** active model → Task 1; `T`/`D` hooks + format → Task 2; session-end additive → Task 3; statusline canonical → Task 4; session-status canonical → Task 5; session-history render + forensic timeline → Task 6; reset-session (no change) + CHANGELOG/README → Task 7. Backward-compat (legacy `events.log`, no-events fallback) covered in Tasks 3/4/5. All spec sections map to a task.
- **Version bump:** intentionally NOT done here — left to the existing `/release` flow, which consumes the `[Unreleased]` CHANGELOG section.
- **DRY caveat:** the awk appears in the lib (Task 1), the statusline (Task 4), and the two skills (Tasks 5–6). The lib is canonical; the others are inlined because they are copied/executed outside the plugin directory. They must stay byte-equivalent in logic — if the algorithm changes, update all four.
- **Grace semantics:** `SESSION_IDLE_THRESHOLD_SECONDS` is reused (not renamed) to avoid breaking existing user config; only its meaning and default change. Documented in CHANGELOG.
