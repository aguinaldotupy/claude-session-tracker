---
name: session-history
description: Use when user asks about past sessions, worklog, accumulated hours, "quanto trabalhei hoje", "worklog do dia", "histórico de sessões", "horas trabalhadas", "session history", or wants to review time spent on projects across sessions.
---

# Session History

Reports aggregated Claude Code session history from the persistent JSONL log written by the `SessionEnd` hook.

## Mechanism

Each time a session ends, the `SessionEnd` hook appends one JSON line to `$HOME/.claude/session-env/history.jsonl` with:

```json
{"session_id":"...","start_ts":0,"end_ts":0,"duration_seconds":0,"active_seconds":0,"project_dir":"...","reason":"exit|clear|logout"}
```

The `active_seconds` field (working time) is what the table and totals report; `duration_seconds` (wall-clock) is available if you explicitly ask for it.

The current (still running) session is NOT in the log — only completed sessions are. If the user also wants the live elapsed time, combine with `session-tracker:session-status`.

## Usage

Parse the log with `jq`, filter by date and/or project, then render a markdown table.

### Filters

- Date: `today` (default), `yesterday`, `7d`, `30d`, or `YYYY-MM-DD..YYYY-MM-DD`.
- Project: substring match on `projects.project_root` OR `sessions.project_dir` (case-insensitive) — worktrees of the same repo group under the canonical root.

### Example: "quanto trabalhei hoje"

Prefer SQLite when available — it joins `projects` for the display name and
produces the `Branch/Issue` column via
`COALESCE(NULLIF(issue_key,''), NULLIF(branch,''), '—')`. Fall back to the
JSONL log (deduped to one row per session) when `sqlite3` or the DB is missing:

```bash
DB="$HOME/.claude/session-env/history.db"
today=$(date +%Y-%m-%d)
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB" ]; then
  sqlite3 -separator $'\t' "$DB" "
    SELECT strftime('%H:%M', s.start_ts, 'unixepoch','localtime'),
           strftime('%H:%M', s.end_ts,   'unixepoch','localtime'),
           s.active_seconds,
           p.name,
           COALESCE(NULLIF(s.issue_key,''), NULLIF(s.branch,''), '—')
    FROM sessions s LEFT JOIN projects p ON p.id = s.project_id
    WHERE date(s.start_ts,'unixepoch','localtime') = '$today'
    ORDER BY s.start_ts;"
else
  # legacy fallback (deduped): one row per session_id
  HIST="$HOME/.claude/session-env/history.jsonl"
  jq -rs --arg today "$today" '
    map(select((.start_ts|strflocaltime("%Y-%m-%d"))==$today))
    | group_by(.session_id) | map(max_by(.end_ts))
    | .[] | [ (.start_ts|strflocaltime("%H:%M")), (.end_ts|strflocaltime("%H:%M")),
              .active_seconds, (.project_dir|split("/")|last), (.issue_key // "—") ] | @tsv' "$HIST"
fi
```

### Sum total for the day

```bash
jq -s --arg today "$today" '
  map(select((.start_ts | strflocaltime("%Y-%m-%d")) == $today))
  | map(.active_seconds) | add // 0
' "$HISTORY"
```

Convert the integer seconds to `Xh Ym` for display.

## Output Format

Render a markdown table and a total, e.g.:

```
| Data       | Início | Fim   | Trabalho | Projeto         | Branch/Issue |
|------------|--------|-------|---------|-----------------|--------------|
| 2026-04-14 | 09:12  | 10:45 | 1h 33m  | session-tracker | BEL-1        |
| 2026-04-14 | 14:02  | 15:30 | 1h 28m  | onspot-web      | feature      |

**Total: 3h 1m em 2 sessões**
```

## Forensic timeline (single session)

When the user wants the "filme" of a specific past session, read its events —
from the `events` table in SQLite when the session was imported there, else
fall back to the live `events.log` (it persists at
`~/.claude/session-env/<session_id>/events.log` after the session ends;
`history.jsonl` carries the `session_id`). Pair `T`/`D` heartbeats per tool
name to show time spent per tool inside each working interval; `DF` closes the
bracket like `D` but flags the tool with `✗`, and `SF` ends the interval like
`S` but marks the stop as an API error. awk does the counting/pairing
(one-true-awk safe — arrays only, no `strftime`); the shell formats epoch →
`HH:MM`. Only the event **source** changes between the two branches — the awk
and the formatting loop below are unchanged either way:

```bash
SID="$1"                                   # session_id from history.jsonl
DB="$HOME/.claude/session-env/history.db"
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB" ] \
   && [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE session_id='$SID';")" -gt 0 ]; then
  EVENTS_SRC() { sqlite3 -separator ' ' "$DB" "SELECT kind, ts, COALESCE(tool,'') FROM events WHERE session_id='$SID' ORDER BY ts;"; }
else
  EV="$HOME/.claude/session-env/$SID/events.log"
  [ -f "$EV" ] || { echo "Sem timeline para a sessão $SID."; exit 0; }
  EVENTS_SRC() { cat "$EV"; }
fi

EVENTS_SRC | awk '
  function flush(){
    if(p>0){
      s=""
      for(t in dur){
        m=int(dur[t]/60); sec=dur[t]%60
        mark=(t in failed)?" ✗":""
        s=s (s==""?"":", ") t " " m "m" sec "s" mark
      }
      printf "WORK %d %d %d %s\n", p, (laststop>0?laststop:p), err, s
      for(t in dur) delete dur[t]
      for(t in opents) delete opents[t]
      for(t in failed) delete failed[t]
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
' | while read -r _tag pts sts err summary; do
  ph=$(date -r "$pts" +%H:%M 2>/dev/null || date -d "@$pts" +%H:%M)
  sh=$(date -r "$sts" +%H:%M 2>/dev/null || date -d "@$sts" +%H:%M)
  work=$((sts - pts)); [ "$work" -lt 0 ] && work=0
  printf '%s  prompt\n' "$ph"
  [ -n "$summary" ] && printf '       %s\n' "$summary"
  if [ "$err" = "1" ]; then
    printf '%s  stop — erro de API (trabalho %dm%02ds)\n' "$sh" "$((work/60))" "$((work%60))"
  else
    printf '%s  stop (trabalho %dm%02ds)\n' "$sh" "$((work/60))" "$((work%60))"
  fi
done
```

Renders e.g.:

```
09:13  prompt
       Read 0m12s, Edit 1m30s
09:31  stop (trabalho 18m02s)
09:35  prompt
       Bash 4m02s ✗
09:42  stop — erro de API (trabalho 7m10s)
```

Only tool *types* and durations are shown — no file paths or command contents
(detail level B). This timeline awk is unique to `session-history` (it pairs
`T`/`D`, flags `DF`/`SF` failures); it is unrelated to the active-time library.

## Edge cases

- Log missing → tell the user: "Sem histórico ainda — complete uma sessão para começar a registrar."
- Empty after filter → report "Nenhuma sessão encontrada para <filtro>."
- Very long rows → show `basename` of `project_dir` in the `Projeto` column; keep the full path only if asked.

To see the live (current) session time, use `/session-tracker:session-status`.
