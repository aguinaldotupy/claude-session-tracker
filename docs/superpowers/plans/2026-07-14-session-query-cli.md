# session-query CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract all session-tracker read logic (SQLite/JSONL guard, queries, forensic-timeline awk) out of the skill Markdown into one tested bash CLI, `session-query`, that returns structured JSON for the agent to render.

**Architecture:** A single bash executable `hooks/lib/session-query.sh` sources `hooks/lib/db.sh` (reusing `st_db_path`/`st_has_sqlite`/`st_sql_escape`) and exposes four read subcommands — `status`, `history`, `timeline`, `worklog` — each emitting JSON with a `source` field (`sqlite`/`jsonl`/`none`). SessionStart deploys `db.sh` + `session-query.sh` alongside the existing `active-time.awk` to `~/.claude/session-env/` so skills (which run outside the plugin dir) can invoke a stable path. Skills shrink to a one-line call plus render prose.

**Tech Stack:** bash (≥3.2), `jq`, `sqlite3` (soft), one-true-awk. Plain-bash test suite under `tests/`.

## Global Constraints

- **Behavior-preserving refactor.** Same numbers, same fallback semantics as today. No write-path changes (`session-end.sh`, `db.sh` write functions, `import-history`) — untouched.
- **Output is always valid JSON, exit 0** — even empty or on internal error (empty arrays + a `source`, never stderr leaking to the agent).
- **`source` field** = `"sqlite"` | `"jsonl"` | `"none"`. Guard: when `history.jsonl` exists (migration pending / sqlite3 absent) read the deduped JSONL; else SQLite; else none.
- **Portability (BSD↔GNU):** no `date -r`/`date -d` — only `date +%s`; all local-time formatting via `sqlite strftime(...,'unixepoch','localtime')` (SQLite) or `jq strflocaltime` (JSONL). awk stays one-true-awk safe (arrays only, no `strftime`/`gensub`). No `readlink -f`/`realpath` (use `pwd -P`). `flock` guarded. `sed` basic substitution only.
- **JSON never hand-built** — use `sqlite3 -json` / `jq -n`.
- **Reuse `db.sh`** via `source` (do not duplicate `st_db_path`/`st_has_sqlite`/`st_sql_escape`).
- **SQL safety:** every text filter value escaped via `st_sql_escape`; numeric-only values validated before interpolation.
- **Deduped JSONL fallback** always dedups by `session_id` (`group_by(.session_id)|max_by(.end_ts)`).
- **Reference spec:** `docs/superpowers/specs/2026-07-14-session-query-cli-design.md`.
- Tests require `sqlite3` + `jq` on PATH (present on dev machine).

---

## File Structure

**Create:**
- `hooks/lib/session-query.sh` — the read CLI (sources `db.sh`).
- `tests/session-query.test.sh` — CLI tests.

**Modify:**
- `hooks/session-start.sh` — deploy `db.sh` + `session-query.sh` (adds to the existing `active-time.awk` deploy).
- `skills/session-status/SKILL.md` — call `session-query status`; drop inline SQL/jq guard.
- `skills/session-history/SKILL.md` — call `session-query history` + `timeline`; drop inline SQL, JSONL fallback, and timeline awk.
- `commands/worklog.md` — use `session-query worklog` for grouping.
- `README.md` — `session-query` note + portability deps.
- `CHANGELOG.md` — `[Unreleased]`.

**Remove:**
- `tests/read-queries.test.sh` — its assertions migrate into `session-query.test.sh`.

---

## Task 1: CLI skeleton + source resolution + `status`

**Files:**
- Create: `hooks/lib/session-query.sh`
- Test: `tests/session-query.test.sh`

**Interfaces:**
- Produces: executable dispatch `session-query <subcommand> [args]`; internal `_sq_source() → stdout "sqlite"|"jsonl"|"none"`; `status [--session <id>]` emitting the §3.1 JSON.

- [ ] **Step 1: Write `hooks/lib/session-query.sh` (skeleton + `_sq_source` + `status`)**

```bash
#!/usr/bin/env bash
# session-query — read-only CLI for session-tracker. Emits JSON on stdout, always
# exits 0, never leaks stderr to the caller. Sources db.sh for shared helpers.
set -uo pipefail

_SQ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_SQ_DIR/db.sh"

_sq_hist() { printf '%s/.claude/session-env/history.jsonl' "$HOME"; }

# Which store is authoritative right now. While history.jsonl exists (migration
# pending or sqlite3 absent) the deduped JSONL is the complete source; otherwise
# SQLite; otherwise nothing.
_sq_source() {
  if [ -f "$(_sq_hist)" ] && command -v jq >/dev/null 2>&1; then echo jsonl
  elif st_has_sqlite && [ -f "$(st_db_path)" ]; then echo sqlite
  else echo none; fi
}

_sq_int() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

sq_status() {
  local sid="" now sdir start_ts live_elapsed live_active issue src
  while [ $# -gt 0 ]; do case "$1" in --session) sid="$2"; shift 2 ;; *) shift ;; esac; done
  [ -z "$sid" ] && sid="${CLAUDE_SESSION_ID:-}"
  now="$(date +%s)"
  src="$(_sq_source)"
  sdir="$HOME/.claude/session-env/$sid"
  start_ts=0; live_elapsed=0; live_active=0; issue=""
  if [ -n "$sid" ] && [ -f "$sdir/session-tracker" ]; then
    start_ts="$(_sq_int "$(cat "$sdir/session-tracker" 2>/dev/null)")"
    [ "$start_ts" -gt 0 ] && live_elapsed=$((now - start_ts))
    local awk_lib="$HOME/.claude/session-env/active-time.awk"
    if [ -f "$sdir/events.log" ] && [ -f "$awk_lib" ]; then
      live_active="$(_sq_int "$(awk -v grace="${SESSION_IDLE_THRESHOLD_SECONDS:-120}" -v t_end="$now" -f "$awk_lib" "$sdir/events.log" 2>/dev/null)")"
    fi
    [ -f "$sdir/issue-tag" ] && issue="$(head -n1 "$sdir/issue-tag" 2>/dev/null | tr -d '[:space:]')"
  fi
  local tsecs=0 tcount=0
  if [ "$src" = sqlite ]; then
    IFS='|' read -r tsecs tcount <<EOF
$(sqlite3 -separator '|' "$(st_db_path)" "SELECT COALESCE(SUM(active_seconds),0), COUNT(*) FROM sessions WHERE date(start_ts,'unixepoch','localtime')=date('now','localtime');" 2>/dev/null)
EOF
  elif [ "$src" = jsonl ]; then
    tsecs="$(jq -s 'map(select((.start_ts|strflocaltime("%Y-%m-%d"))==(now|strflocaltime("%Y-%m-%d")))) | group_by(.session_id) | map(max_by(.end_ts).active_seconds) | add // 0' "$(_sq_hist)" 2>/dev/null)"
    tcount="$(jq -s 'map(select((.start_ts|strflocaltime("%Y-%m-%d"))==(now|strflocaltime("%Y-%m-%d")))) | group_by(.session_id) | length' "$(_sq_hist)" 2>/dev/null)"
  fi
  tsecs="$(_sq_int "$tsecs")"; tcount="$(_sq_int "$tcount")"
  jq -n --arg source "$src" --argjson elapsed "$live_elapsed" --argjson active "$live_active" \
        --argjson started "$start_ts" --arg issue "$issue" --argjson tsecs "$tsecs" --argjson tcount "$tcount" \
    '{source:$source, live:{elapsed_seconds:$elapsed, active_seconds:$active, started_at:$started, issue_key:$issue}, today:{active_seconds:$tsecs, sessions:$tcount}}'
}

_sq_main() {
  local cmd="${1:-}"; shift 2>/dev/null || true
  case "$cmd" in
    status)   sq_status "$@" ;;
    *)        jq -n --arg source none '{source:$source,error:"unknown subcommand"}' ;;
  esac
}

_sq_main "$@" 2>/dev/null || jq -n --arg source none '{source:$source}'
```

- [ ] **Step 2: Write the failing test `tests/session-query.test.sh`**

```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
. "$DIR/../hooks/lib/db.sh"
SQ="$DIR/../hooks/lib/session-query.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
mkdir -p "$HOME/.claude/session-env"
# active-time.awk must be at the deployed path for `status`
cp "$DIR/../hooks/lib/active-time.awk" "$HOME/.claude/session-env/active-time.awk"
st_db_init

TODAY=$(date +%s)
st_upsert_session "s1" "/p/a" "/p/a" "main" "A-1" "$TODAY" "$TODAY" 100 100 0 "other" "$TODAY"
st_upsert_session "s2" "/p/a" "/p/a" "main" ""    "$TODAY" "$TODAY" 200 200 0 "other" "$TODAY"

# status: today total sums both (300), 2 sessions; source sqlite (no jsonl present)
out="$(bash "$SQ" status --session none)"
assert_eq "status is valid json" "0" "$(printf '%s' "$out" | jq -e . >/dev/null 2>&1; echo $?)"
assert_eq "status source sqlite" "sqlite" "$(printf '%s' "$out" | jq -r .source)"
assert_eq "status today total" "300" "$(printf '%s' "$out" | jq -r .today.active_seconds)"
assert_eq "status today count" "2" "$(printf '%s' "$out" | jq -r .today.sessions)"

# live session: fabricate a session dir with a closed bracket → active 60 + grace 120 = 180
SID="live-1"; SD="$HOME/.claude/session-env/$SID"; mkdir -p "$SD"
echo "1000" > "$SD/session-tracker"
printf 'P 1000\nS 1060\n' > "$SD/events.log"
out="$(bash "$SQ" status --session "$SID")"
assert_eq "status live active (60+grace120)" "180" "$(printf '%s' "$out" | jq -r .live.active_seconds)"
assert_eq "status live started_at" "1000" "$(printf '%s' "$out" | jq -r .live.started_at)"

finish
```

- [ ] **Step 3: Run test, expect PASS**

Run: `bash tests/session-query.test.sh`
Expected: all assertions pass (valid json, source sqlite, today 300/2, live active 180, started 1000). `chmod +x hooks/lib/session-query.sh` if invoking directly, but the test uses `bash "$SQ"` so no chmod needed.

- [ ] **Step 4: Commit**

```bash
git add hooks/lib/session-query.sh tests/session-query.test.sh
git commit -m "feat(cli): session-query skeleton + source guard + status"
```

---

## Task 2: `history` subcommand (+ range/filter internals)

**Files:**
- Modify: `hooks/lib/session-query.sh` (append internals + `sq_history`, add to dispatch)
- Test: `tests/session-query.test.sh` (append cases)

**Interfaces:**
- Consumes: `_sq_source`, `st_db_path`, `st_sql_escape`, `_sq_hist`.
- Produces: `_sq_sql_where(range) → SQL fragment on start_ts`; `_sq_jq_range(range) → jq boolean expr on .start_ts`; `history [--range R] [--project P]` emitting the §3.2 JSON (rows with `start_local`/`end_local`).

- [ ] **Step 1: Write failing tests (append to `tests/session-query.test.sh`, before `finish`)**

```bash
# --- history ---
# s1 has issue A-1; s2 only a branch → branch_issue falls back to branch
outh="$(bash "$SQ" history --range today --project a)"
assert_eq "history valid json" "0" "$(printf '%s' "$outh" | jq -e . >/dev/null 2>&1; echo $?)"
assert_eq "history source sqlite" "sqlite" "$(printf '%s' "$outh" | jq -r .source)"
assert_eq "history count 2" "2" "$(printf '%s' "$outh" | jq -r .count)"
assert_eq "history total 300" "300" "$(printf '%s' "$outh" | jq -r .total_active_seconds)"
assert_eq "history row s1 branch_issue=issue" "A-1" "$(printf '%s' "$outh" | jq -r '.rows[] | select(.active_seconds==100) | .branch_issue')"
assert_eq "history row s2 branch_issue=branch" "main" "$(printf '%s' "$outh" | jq -r '.rows[] | select(.active_seconds==200) | .branch_issue')"
assert_eq "history row has start_local HH:MM" "5" "$(printf '%s' "$outh" | jq -r '.rows[0].start_local' | grep -cE '^[0-9]{2}:[0-9]{2}$' | sed 's/1/5/')"

# project filter miss → empty rows, still valid json, count 0
outm="$(bash "$SQ" history --range today --project nope)"
assert_eq "history filter miss count 0" "0" "$(printf '%s' "$outm" | jq -r .count)"
assert_eq "history filter miss valid json" "0" "$(printf '%s' "$outm" | jq -e . >/dev/null 2>&1; echo $?)"

# a session from 1970 (start_ts small) is excluded by --range today
st_upsert_session "old" "/p/a" "/p/a" "main" "" 1000 1100 50 50 0 "other" 1101
assert_eq "history today excludes old" "2" "$(bash "$SQ" history --range today --project a | jq -r .count)"
assert_eq "history 30d also excludes 1970" "2" "$(bash "$SQ" history --range 30d --project a | jq -r .count)"
```

Note: the `grep -cE ... | sed 's/1/5/'` trick asserts the `start_local` matches `HH:MM` (grep count 1 → mapped to "5" to equal the expected "5"); if the format is wrong grep yields 0. Keep it exactly.

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash tests/session-query.test.sh`
Expected: FAIL — `history` returns the unknown-subcommand JSON (`.source == "none"`), so `history source sqlite` fails.

- [ ] **Step 3: Implement `history` (append to `hooks/lib/session-query.sh` before `_sq_main`; add `history)` to the dispatch case)**

```bash
# SQL WHERE fragment (on start_ts) for a --range value. Portable: SQLite date().
_sq_sql_where() {
  case "$1" in
    today)     echo "date(start_ts,'unixepoch','localtime')=date('now','localtime')" ;;
    yesterday) echo "date(start_ts,'unixepoch','localtime')=date('now','-1 day','localtime')" ;;
    7d)        echo "date(start_ts,'unixepoch','localtime')>=date('now','-6 days','localtime')" ;;
    30d)       echo "date(start_ts,'unixepoch','localtime')>=date('now','-29 days','localtime')" ;;
    *..*)      local f="${1%%..*}" t="${1##*..}"
               f="$(st_sql_escape "$f")"; t="$(st_sql_escape "$t")"
               echo "date(start_ts,'unixepoch','localtime') BETWEEN date('$f') AND date('$t')" ;;
    *)         echo "date(start_ts,'unixepoch','localtime')=date('now','localtime')" ;;
  esac
}

# jq boolean on . for the JSONL fallback. Uses local date strings (portable).
_sq_jq_range() {
  case "$1" in
    today)     echo '(.start_ts|strflocaltime("%Y-%m-%d")) == (now|strflocaltime("%Y-%m-%d"))' ;;
    yesterday) echo '(.start_ts|strflocaltime("%Y-%m-%d")) == ((now-86400)|strflocaltime("%Y-%m-%d"))' ;;
    7d)        echo '(.start_ts|strflocaltime("%Y-%m-%d")) >= ((now-6*86400)|strflocaltime("%Y-%m-%d"))' ;;
    30d)       echo '(.start_ts|strflocaltime("%Y-%m-%d")) >= ((now-29*86400)|strflocaltime("%Y-%m-%d"))' ;;
    *..*)      local f="${1%%..*}" t="${1##*..}"
               printf '(.start_ts|strflocaltime("%%Y-%%m-%%d")) >= "%s" and (.start_ts|strflocaltime("%%Y-%%m-%%d")) <= "%s"' "$f" "$t" ;;
    *)         echo '(.start_ts|strflocaltime("%Y-%m-%d")) == (now|strflocaltime("%Y-%m-%d"))' ;;
  esac
}

sq_history() {
  local range="today" project="" src rows total count
  while [ $# -gt 0 ]; do case "$1" in --range) range="$2"; shift 2 ;; --project) project="$2"; shift 2 ;; *) shift ;; esac; done
  src="$(_sq_source)"
  if [ "$src" = sqlite ]; then
    local where; where="$(_sq_sql_where "$range")"
    local pfilter="1"
    if [ -n "$project" ]; then local ep; ep="$(st_sql_escape "$project")"; pfilter="(p.project_root LIKE '%$ep%' OR s.project_dir LIKE '%$ep%')"; fi
    rows="$(sqlite3 -json "$(st_db_path)" "
      SELECT s.start_ts AS start,
             strftime('%H:%M', s.start_ts,'unixepoch','localtime') AS start_local,
             s.end_ts AS end,
             strftime('%H:%M', s.end_ts,'unixepoch','localtime') AS end_local,
             s.active_seconds AS active_seconds,
             p.name AS project,
             COALESCE(NULLIF(s.issue_key,''),NULLIF(s.branch,''),'—') AS branch_issue
      FROM sessions s LEFT JOIN projects p ON p.id=s.project_id
      WHERE $where AND $pfilter ORDER BY s.start_ts;" 2>/dev/null)"
    [ -z "$rows" ] && rows='[]'
  elif [ "$src" = jsonl ]; then
    local rexpr pexpr; rexpr="$(_sq_jq_range "$range")"
    if [ -n "$project" ]; then pexpr="((.project_dir//\"\")|ascii_downcase|contains(\"$(printf '%s' "$project" | tr '[:upper:]' '[:lower:]')\"))"; else pexpr="true"; fi
    rows="$(jq -s --sort-keys "map(select(($rexpr) and ($pexpr))) | group_by(.session_id) | map(max_by(.end_ts))
      | map({start:.start_ts, start_local:(.start_ts|strflocaltime(\"%H:%M\")), end:.end_ts, end_local:(.end_ts|strflocaltime(\"%H:%M\")),
             active_seconds:(.active_seconds // .duration_seconds // 0), project:((.project_dir//\"\")|split(\"/\")|last), branch_issue:((.issue_key // \"—\"))})" "$(_sq_hist)" 2>/dev/null)"
    [ -z "$rows" ] && rows='[]'
  else
    rows='[]'
  fi
  printf '%s' "$rows" | jq -e . >/dev/null 2>&1 || rows='[]'
  total="$(printf '%s' "$rows" | jq '[.[].active_seconds]|add // 0')"
  count="$(printf '%s' "$rows" | jq 'length')"
  jq -n --arg source "$src" --argjson rows "$rows" --argjson total "$total" --argjson count "$count" \
    '{source:$source, total_active_seconds:$total, count:$count, rows:$rows}'
}
```

Add to the `_sq_main` case, before `*)`:
```bash
    history)  sq_history "$@" ;;
```

- [ ] **Step 4: Run test, expect PASS**

Run: `bash tests/session-query.test.sh`
Expected: all history assertions pass (count 2, total 300, branch_issue precedence, start_local HH:MM, filter miss, today/30d exclude 1970).

- [ ] **Step 5: Commit**

```bash
git add hooks/lib/session-query.sh tests/session-query.test.sh
git commit -m "feat(cli): session-query history (range + project filter, JSONL fallback)"
```

---

## Task 3: `timeline` subcommand (awk moves into the CLI)

**Files:**
- Modify: `hooks/lib/session-query.sh` (append `sq_timeline`, add to dispatch)
- Test: `tests/session-query.test.sh` (append cases)

**Interfaces:**
- Consumes: `st_db_path`, `st_has_sqlite`, `_sq_source`.
- Produces: `timeline <session_id>` emitting the §3.3 JSON (`intervals[]` with `tools[]`, `failed`, `api_error`).

- [ ] **Step 1: Write failing tests (append before `finish`)**

```bash
# --- timeline ---
# build events for s1 directly in the events table
sqlite3 "$(st_db_path)" "DELETE FROM events WHERE session_id='s1';
  INSERT INTO events(session_id,ts,kind,tool) VALUES
   ('s1',2000,'P',NULL),('s1',2005,'T','Read'),('s1',2017,'D','Read'),
   ('s1',2020,'T','Bash'),('s1',2262,'DF','Bash'),('s1',2400,'SF',NULL);"
outt="$(bash "$SQ" timeline s1)"
assert_eq "timeline valid json" "0" "$(printf '%s' "$outt" | jq -e . >/dev/null 2>&1; echo $?)"
assert_eq "timeline one interval" "1" "$(printf '%s' "$outt" | jq -r '.intervals|length')"
assert_eq "timeline api_error (SF)" "true" "$(printf '%s' "$outt" | jq -r '.intervals[0].api_error')"
assert_eq "timeline Read seconds" "12" "$(printf '%s' "$outt" | jq -r '.intervals[0].tools[]|select(.tool=="Read").seconds')"
assert_eq "timeline Bash failed (DF)" "true" "$(printf '%s' "$outt" | jq -r '.intervals[0].tools[]|select(.tool=="Bash").failed')"

# unknown session → empty intervals, valid json
oute="$(bash "$SQ" timeline nope-xyz)"
assert_eq "timeline unknown empty" "0" "$(printf '%s' "$oute" | jq -r '.intervals|length')"
assert_eq "timeline unknown valid json" "0" "$(printf '%s' "$oute" | jq -e . >/dev/null 2>&1; echo $?)"
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash tests/session-query.test.sh`
Expected: FAIL — `timeline` unknown subcommand → `.intervals` is null.

- [ ] **Step 3: Implement `timeline` (append before `_sq_main`; add `timeline)` to dispatch)**

```bash
# Forensic timeline. Events come from the SQLite `events` table when present,
# else the live events.log. The awk pairs T/D per tool, flags DF (failed) and SF
# (api_error), and emits one JSON object per line; the shell wraps into intervals.
sq_timeline() {
  local sid="${1:-}" src rows
  src="$(_sq_source)"
  local ev_src=""
  if st_has_sqlite && [ -f "$(st_db_path)" ] \
     && [ "$(sqlite3 "$(st_db_path)" "SELECT COUNT(*) FROM events WHERE session_id='$(st_sql_escape "$sid")';" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
    ev_src="$(sqlite3 -separator ' ' "$(st_db_path)" "SELECT kind, ts, COALESCE(tool,'') FROM events WHERE session_id='$(st_sql_escape "$sid")' ORDER BY ts;" 2>/dev/null)"
  elif [ -f "$HOME/.claude/session-env/$sid/events.log" ]; then
    ev_src="$(cat "$HOME/.claude/session-env/$sid/events.log" 2>/dev/null)"
  fi
  rows="$(printf '%s\n' "$ev_src" | awk '
    function flush(){
      if(p>0){
        printf "{\"prompt\":%d,\"stop\":%d,\"work\":%d,\"api_error\":%s,\"tools\":[", p, (laststop>0?laststop:p), ((laststop>0?laststop:p)-p), (err?"true":"false")
        first=1
        for(t in dur){ printf "%s{\"tool\":\"%s\",\"seconds\":%d,\"failed\":%s}", (first?"":","), t, dur[t], ((t in failed)?"true":"false"); first=0 }
        printf "]}\n"
        for(t in dur) delete dur[t]; for(t in opents) delete opents[t]; for(t in failed) delete failed[t]
      }
    }
    { k=$1; ts=$2+0; tool=$3 }
    k=="P"  { flush(); p=ts; laststop=0; err=0 }
    k=="T"  { if(p>0) opents[tool]=ts }
    k=="D"  { if(p>0 && (tool in opents)){ d=ts-opents[tool]; if(d<0)d=0; dur[tool]+=d; delete opents[tool] } }
    k=="DF" { if(p>0){ if(tool in opents){ d=ts-opents[tool]; if(d<0)d=0; dur[tool]+=d; delete opents[tool] } failed[tool]=1 } }
    k=="S"  { laststop=ts }
    k=="SF" { laststop=ts; err=1 }
    END { flush() }
  ' 2>/dev/null)"
  # rows is newline-delimited JSON objects (may be empty). Assemble + add *_local.
  local arr; arr="$(printf '%s\n' "$rows" | jq -s '
    map({prompt:.prompt, prompt_local:(.prompt|strflocaltime("%H:%M")), stop:.stop, stop_local:(.stop|strflocaltime("%H:%M")),
         work_seconds:.work, api_error:.api_error, tools:.tools})' 2>/dev/null)"
  [ -z "$arr" ] && arr='[]'
  printf '%s' "$arr" | jq -e . >/dev/null 2>&1 || arr='[]'
  jq -n --arg source "$src" --argjson intervals "$arr" '{source:$source, intervals:$intervals}'
}
```

Add to `_sq_main` case:
```bash
    timeline) sq_timeline "$@" ;;
```

- [ ] **Step 4: Run test, expect PASS**

Run: `bash tests/session-query.test.sh`
Expected: all timeline assertions pass (1 interval, api_error true, Read 12s, Bash failed true, unknown session empty).

- [ ] **Step 5: Commit**

```bash
git add hooks/lib/session-query.sh tests/session-query.test.sh
git commit -m "feat(cli): session-query timeline (awk pairing → JSON)"
```

---

## Task 4: `worklog` subcommand

**Files:**
- Modify: `hooks/lib/session-query.sh` (append `sq_worklog`, add to dispatch)
- Test: `tests/session-query.test.sh` (append cases)

**Interfaces:**
- Consumes: `_sq_source`, `_sq_sql_where`, `_sq_jq_range`, `st_db_path`, `st_sql_escape`, `_sq_hist`.
- Produces: `worklog [--range R] [--project P]` emitting the §3.4 JSON (`by_issue[]` + `untagged`).

- [ ] **Step 1: Write failing tests (append before `finish`)**

```bash
# --- worklog ---
# s1 has issue A-1 (100s); s2 untagged (200s); add s3 with A-1 (50s) today
st_upsert_session "s3" "/p/a" "/p/a" "main" "A-1" "$TODAY" "$TODAY" 50 50 0 "other" "$TODAY"
outw="$(bash "$SQ" worklog --range today --project a)"
assert_eq "worklog valid json" "0" "$(printf '%s' "$outw" | jq -e . >/dev/null 2>&1; echo $?)"
assert_eq "worklog A-1 total (100+50)" "150" "$(printf '%s' "$outw" | jq -r '.by_issue[]|select(.issue_key=="A-1").active_seconds')"
assert_eq "worklog A-1 sessions" "2" "$(printf '%s' "$outw" | jq -r '.by_issue[]|select(.issue_key=="A-1").sessions')"
assert_eq "worklog untagged total (s2)" "200" "$(printf '%s' "$outw" | jq -r '.untagged.active_seconds')"
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash tests/session-query.test.sh`
Expected: FAIL — `worklog` unknown subcommand → `.by_issue` null.

- [ ] **Step 3: Implement `worklog` (append before `_sq_main`; add `worklog)` to dispatch)**

```bash
# Group finished sessions by issue_key; sessions with no issue_key aggregate into
# `untagged`. Same range/project filters as history.
sq_worklog() {
  local range="today" project="" src by untag
  while [ $# -gt 0 ]; do case "$1" in --range) range="$2"; shift 2 ;; --project) project="$2"; shift 2 ;; *) shift ;; esac; done
  src="$(_sq_source)"
  if [ "$src" = sqlite ]; then
    local where; where="$(_sq_sql_where "$range")"
    local pfilter="1"
    if [ -n "$project" ]; then local ep; ep="$(st_sql_escape "$project")"; pfilter="(p.project_root LIKE '%$ep%' OR s.project_dir LIKE '%$ep%')"; fi
    by="$(sqlite3 -json "$(st_db_path)" "
      SELECT s.issue_key AS issue_key, MIN(p.name) AS project, SUM(s.active_seconds) AS active_seconds, COUNT(*) AS sessions
      FROM sessions s LEFT JOIN projects p ON p.id=s.project_id
      WHERE $where AND $pfilter AND COALESCE(s.issue_key,'')<>'' GROUP BY s.issue_key ORDER BY active_seconds DESC;" 2>/dev/null)"
    untag="$(sqlite3 -json "$(st_db_path)" "
      SELECT COALESCE(SUM(s.active_seconds),0) AS active_seconds, COUNT(*) AS sessions
      FROM sessions s LEFT JOIN projects p ON p.id=s.project_id
      WHERE $where AND $pfilter AND COALESCE(s.issue_key,'')='';" 2>/dev/null)"
  elif [ "$src" = jsonl ]; then
    local rexpr pexpr; rexpr="$(_sq_jq_range "$range")"
    if [ -n "$project" ]; then pexpr="((.project_dir//\"\")|ascii_downcase|contains(\"$(printf '%s' "$project" | tr '[:upper:]' '[:lower:]')\"))"; else pexpr="true"; fi
    local base; base="$(jq -s "map(select(($rexpr) and ($pexpr))) | group_by(.session_id) | map(max_by(.end_ts))" "$(_sq_hist)" 2>/dev/null)"
    by="$(printf '%s' "$base" | jq 'map(select((.issue_key//"")!="")) | group_by(.issue_key)
      | map({issue_key:.[0].issue_key, project:(.[0].project_dir|split("/")|last), active_seconds:(map(.active_seconds//.duration_seconds//0)|add), sessions:length})' 2>/dev/null)"
    untag="$(printf '%s' "$base" | jq '[ .[] | select((.issue_key//"")=="") ] | {active_seconds:(map(.active_seconds//.duration_seconds//0)|add // 0), sessions:length}' 2>/dev/null)"
  fi
  [ -z "$by" ] && by='[]'; printf '%s' "$by" | jq -e . >/dev/null 2>&1 || by='[]'
  [ -z "$untag" ] && untag='{"active_seconds":0,"sessions":0}'
  # sqlite3 -json wraps untag in an array; unwrap if needed
  untag="$(printf '%s' "$untag" | jq 'if type=="array" then .[0] // {active_seconds:0,sessions:0} else . end' 2>/dev/null)"
  [ -z "$untag" ] && untag='{"active_seconds":0,"sessions":0}'
  jq -n --arg source "$src" --argjson by "$by" --argjson untagged "$untag" \
    '{source:$source, by_issue:$by, untagged:$untagged}'
}
```

Add to `_sq_main` case:
```bash
    worklog)  sq_worklog "$@" ;;
```

- [ ] **Step 4: Run test, expect PASS**

Run: `bash tests/session-query.test.sh`
Expected: worklog assertions pass (A-1 150s / 2 sessions, untagged 200s).

- [ ] **Step 5: Commit**

```bash
git add hooks/lib/session-query.sh tests/session-query.test.sh
git commit -m "feat(cli): session-query worklog (group by issue + untagged)"
```

---

## Task 5: JSONL-fallback + no-store guard tests

**Files:**
- Test: `tests/session-query.test.sh` (append cases) — no production change; this task locks in the guard behavior that motivated the CLI.

- [ ] **Step 1: Write failing-then-passing tests (append before `finish`)**

```bash
# --- guard: source resolution ---
# (a) with a history.jsonl present, reads the COMPLETE deduped JSONL (source jsonl),
#     even though the partial DB exists — this is the v3.0.1/3.0.2 regression guard.
HJ="$HOME/.claude/session-env/history.jsonl"
cat > "$HJ" <<JSON
{"session_id":"j1","project_dir":"/p/z","active_seconds":10,"duration_seconds":10,"idle_seconds":0,"start_ts":$TODAY,"end_ts":$TODAY,"issue_key":"","reason":"other"}
{"session_id":"j1","project_dir":"/p/z","active_seconds":40,"duration_seconds":40,"idle_seconds":0,"start_ts":$TODAY,"end_ts":$((TODAY+5)),"issue_key":"","reason":"other"}
{"session_id":"j2","project_dir":"/p/z","active_seconds":25,"duration_seconds":25,"idle_seconds":0,"start_ts":$TODAY,"end_ts":$TODAY,"issue_key":"","reason":"other"}
JSON
gj="$(bash "$SQ" history --range today)"
assert_eq "guard prefers jsonl when present" "jsonl" "$(printf '%s' "$gj" | jq -r .source)"
# deduped: j1 keeps 40 (max end), j2 25 → total 65, 2 rows
assert_eq "jsonl deduped total" "65" "$(printf '%s' "$gj" | jq -r .total_active_seconds)"
assert_eq "jsonl deduped count" "2" "$(printf '%s' "$gj" | jq -r .count)"
rm -f "$HJ"

# (b) sqlite3 stubbed off PATH + jsonl present → source jsonl
cat > "$HJ" <<JSON
{"session_id":"k1","project_dir":"/p/z","active_seconds":7,"duration_seconds":7,"idle_seconds":0,"start_ts":$TODAY,"end_ts":$TODAY,"issue_key":"","reason":"other"}
JSON
FAKEBIN="$HOME/fakebin"; mkdir -p "$FAKEBIN"
for b in jq awk sed grep cat head printf date tr dirname basename mkdir bash; do ln -sf "$(command -v $b)" "$FAKEBIN/$b" 2>/dev/null; done
assert_eq "no sqlite3 → jsonl" "jsonl" "$(PATH="$FAKEBIN" bash "$SQ" history --range today | jq -r .source)"
rm -f "$HJ"

# (c) no DB and no jsonl → source none, empty
rm -f "$(st_db_path)"
gn="$(bash "$SQ" history --range today)"
assert_eq "no store → source none" "none" "$(printf '%s' "$gn" | jq -r .source)"
assert_eq "no store → count 0" "0" "$(printf '%s' "$gn" | jq -r .count)"
assert_eq "no store → valid json" "0" "$(printf '%s' "$gn" | jq -e . >/dev/null 2>&1; echo $?)"
```

- [ ] **Step 2: Run test, expect PASS**

Run: `bash tests/session-query.test.sh`
Expected: all guard assertions pass (jsonl preferred, deduped 65/2, sqlite-absent → jsonl, no-store → none/0). If (a) fails with `sqlite`, the guard in `_sq_source` is wrong (must check jsonl first).

- [ ] **Step 3: Commit**

```bash
git add tests/session-query.test.sh
git commit -m "test(cli): guard/source-resolution coverage (jsonl-preferred, deduped, none)"
```

---

## Task 6: SessionStart deploys db.sh + session-query.sh

**Files:**
- Modify: `hooks/session-start.sh`
- Test: `tests/session-start.test.sh` (append cases)

**Interfaces:**
- Consumes: the existing `active-time.awk` deploy block.

- [ ] **Step 1: Write failing tests (append to `tests/session-start.test.sh`, before `finish`)**

```bash
# --- deploy of db.sh + session-query.sh for skills ---
echo '{"session_id":"dep-1","source":"startup"}' | bash "$ROOT/hooks/session-start.sh" >/dev/null
DEST="$TMP/.claude/session-env"
assert_eq "db.sh deployed" "yes" "$([ -f "$DEST/db.sh" ] && echo yes || echo no)"
assert_eq "session-query.sh deployed" "yes" "$([ -f "$DEST/session-query.sh" ] && echo yes || echo no)"
assert_eq "deployed session-query runs" "0" "$(bash "$DEST/session-query.sh" status --session none | jq -e . >/dev/null 2>&1; echo $?)"
```

Note: `tests/session-start.test.sh` already defines `TMP`, `ROOT`, `HOME`; reuse them. `bash "$DEST/session-query.sh"` works because the deployed copy sources its sibling deployed `db.sh`.

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash tests/session-start.test.sh`
Expected: FAIL — `db.sh deployed` (only active-time.awk is copied today).

- [ ] **Step 3: Modify `hooks/session-start.sh`**

Find the existing AWK deploy block:
```bash
AWK_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/active-time.awk"
if [ -f "$AWK_SRC" ]; then
  cp -f "$AWK_SRC" "$HOME/.claude/session-env/active-time.awk" 2>/dev/null || true
fi
```
Replace it with a loop that also deploys `db.sh` and `session-query.sh`:
```bash
# Deploy read-side libs to a stable, plugin-independent path so the statusline
# and skills (which run outside the plugin dir) can source/invoke them.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
for f in active-time.awk db.sh session-query.sh; do
  [ -f "$LIB_DIR/$f" ] && cp -f "$LIB_DIR/$f" "$HOME/.claude/session-env/$f" 2>/dev/null || true
done
```

- [ ] **Step 4: Run test, expect PASS**

Run: `bash tests/session-start.test.sh`
Expected: all pass — db.sh + session-query.sh deployed, deployed CLI runs and emits valid JSON. Existing assertions still pass.

- [ ] **Step 5: Commit**

```bash
git add hooks/session-start.sh tests/session-start.test.sh
git commit -m "feat(hooks): SessionStart deploys db.sh + session-query.sh for skills"
```

---

## Task 7: Rewrite skills, worklog command, docs; remove read-queries.test.sh

**Files:**
- Modify: `skills/session-status/SKILL.md`, `skills/session-history/SKILL.md`, `commands/worklog.md`, `README.md`, `CHANGELOG.md`
- Remove: `tests/read-queries.test.sh`

- [ ] **Step 1: Rewrite `skills/session-status/SKILL.md`**

Replace the entire "today's accumulated total" bash block (the `DB=`/`HIST=`/`if command -v sqlite3 …` snippet through `total_today=…`) with a single call + render instruction:

````markdown
Get the live session and today's total in one call, then render:

```bash
bash "$HOME/.claude/session-env/session-query.sh" status --session "$CLAUDE_SESSION_ID"
```

Returns JSON: `{live:{elapsed_seconds,active_seconds,started_at,issue_key}, today:{active_seconds,sessions}}`.
Render e.g. `Sessão: 1h 10m (ativo: 52m) · hoje: 5h 05m em 5 sessões`. Convert seconds to `Xh Ym`. If `issue_key` is set, show it. `source:"none"` means no history yet.
````

- [ ] **Step 2: Rewrite `skills/session-history/SKILL.md`**

Replace the three query blocks ("quanto trabalhei hoje", "Sum total for the day", and the whole "Forensic timeline" bash block including the awk) with calls to the CLI:

````markdown
### Table + total

```bash
bash "$HOME/.claude/session-env/session-query.sh" history --range 7d --project bel
```
Filters: `--range today|yesterday|7d|30d|FROM..TO` (default today), `--project <substr>`.
Returns `{total_active_seconds, count, rows:[{start_local,end_local,active_seconds,project,branch_issue}]}`.
Render a markdown table `| Data | Início | Fim | Trabalho | Projeto | Branch/Issue |` using `start_local`/`end_local` and `active_seconds`→`Xh Ym`; footer `Total: … em N sessões`.

### Forensic timeline (single session)

```bash
bash "$HOME/.claude/session-env/session-query.sh" timeline "$SID"
```
Returns `{intervals:[{prompt_local,stop_local,work_seconds,api_error,tools:[{tool,seconds,failed}]}]}`.
Render each interval as `HH:MM prompt` / tool durations (append `✗` when `failed`) / `HH:MM stop` (append `— erro de API` when `api_error`). Empty `intervals` → "Sem timeline para a sessão".
````

Keep the Mechanism/Filters prose; delete the old inline SQL, the jq fallback, and the timeline awk.

- [ ] **Step 3: Update `commands/worklog.md`**

Read the file first. Replace its data-gathering step (whatever reads history) with:
```bash
bash "$HOME/.claude/session-env/session-query.sh" worklog --range 7d
```
Returns `{by_issue:[{issue_key,project,active_seconds,sessions}], untagged:{active_seconds,sessions}}`. Keep the existing MCP-posting proposal prose unchanged — only the grouping source changes.

- [ ] **Step 4: Remove the migrated test**

```bash
git rm tests/read-queries.test.sh
```
Its query assertions are now covered by `tests/session-query.test.sh` (Tasks 2 & 5). Confirm coverage: history grouping/filter (Task 2), guard/source (Task 5).

- [ ] **Step 5: Update `README.md`**

Under requirements/usage, note (human-focused, no raw scripts): the read path goes through a single `session-query` helper deployed to `~/.claude/session-env/`; list deps — `bash`, `jq` (required), `sqlite3` (recommended; falls back to a JSON-lines log), and that native Windows needs WSL/Git Bash.

- [ ] **Step 6: Update `CHANGELOG.md` `[Unreleased]`**

```markdown
## [Unreleased]

### Changed
- Read path consolidated into a single tested `session-query` CLI
  (`hooks/lib/session-query.sh`, deployed to `~/.claude/session-env/`). The
  `session-status`, `session-history`, and `worklog` skills/commands now call it
  and render its JSON instead of embedding SQL/awk/jq. Behavior is unchanged;
  the SQLite-vs-JSONL guard and the forensic-timeline awk now live (and are
  tested) in one place.
```

- [ ] **Step 7: Run the full suite + commit**

Run: `bash tests/run.sh`
Expected: every suite `0 failed`, including `session-query.test.sh`; `read-queries.test.sh` no longer listed.

```bash
git add skills/session-status/SKILL.md skills/session-history/SKILL.md commands/worklog.md README.md CHANGELOG.md
git commit -m "refactor(skills): call session-query CLI; drop inline SQL/awk; remove read-queries test"
```

---

## Self-Review notes (reconciled)

- **Spec coverage:** §3.1 status → T1; §3.2 history + `start_local`/`end_local` → T2; §3.3 timeline → T3; §3.4 worklog → T4; §4 guard/source → T1/T5; §4.1 deploy → T6; §5 skill rewrite + §6 test migration → T7; §8 portability (sqlite strftime / jq strflocaltime, no `date -r/-d`, one-true-awk) → enforced in T1–T4 code + Global Constraints; §9 edge cases (empty timeline, no-store, quoted `--project`) → T3/T5 tests + `st_sql_escape` usage.
- **Placeholder scan:** none; every step has complete code.
- **Type consistency:** subcommand fn names (`sq_status`/`sq_history`/`sq_timeline`/`sq_worklog`), helpers (`_sq_source`/`_sq_sql_where`/`_sq_jq_range`/`_sq_hist`/`_sq_int`), and JSON field names (`source`, `live`, `today`, `rows`, `start_local`, `branch_issue`, `intervals`, `api_error`, `by_issue`, `untagged`) are identical across tasks and match the spec.
