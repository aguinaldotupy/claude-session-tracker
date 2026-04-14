---
name: session-history
description: Use when user asks about past sessions, worklog, accumulated hours, "quanto trabalhei hoje", "worklog do dia", "histórico de sessões", "horas trabalhadas", "session history", or wants to review time spent on projects across sessions.
---

# Session History

Reports aggregated Claude Code session history from the persistent JSONL log written by the `SessionEnd` hook.

## Mechanism

Each time a session ends, the `SessionEnd` hook appends one JSON line to `$HOME/.claude/session-env/history.jsonl` with:

```json
{"session_id":"...","start_ts":0,"end_ts":0,"duration_seconds":0,"project_dir":"...","reason":"exit|clear|logout"}
```

The current (still running) session is NOT in the log — only completed sessions are. If the user also wants the live elapsed time, combine with `session-tracker:session-status`.

## Usage

Parse the log with `jq`, filter by date and/or project, then render a markdown table.

### Filters

- Date: `today` (default), `yesterday`, `7d`, `30d`, or `YYYY-MM-DD..YYYY-MM-DD`.
- Project: substring match on `project_dir` (case-insensitive).

### Example: "quanto trabalhei hoje"

```bash
HISTORY="$HOME/.claude/session-env/history.jsonl"
[ -f "$HISTORY" ] || { echo "Sem histórico de sessões ainda."; exit 0; }

today=$(date +%Y-%m-%d)
jq -r --arg today "$today" '
  select((.start_ts | strflocaltime("%Y-%m-%d")) == $today)
  | [ (.start_ts | strflocaltime("%H:%M")),
      (.end_ts   | strflocaltime("%H:%M")),
      .duration_seconds,
      (.project_dir | split("/") | last) ]
  | @tsv
' "$HISTORY"
```

### Sum total for the day

```bash
jq -s --arg today "$today" '
  map(select((.start_ts | strflocaltime("%Y-%m-%d")) == $today))
  | map(.duration_seconds) | add // 0
' "$HISTORY"
```

Convert the integer seconds to `Xh Ym` for display.

## Output Format

Render a markdown table and a total, e.g.:

```
| Data       | Início | Fim   | Duração | Projeto         |
|------------|--------|-------|---------|-----------------|
| 2026-04-14 | 09:12  | 10:45 | 1h 33m  | session-tracker |
| 2026-04-14 | 14:02  | 15:30 | 1h 28m  | onspot-web      |

**Total: 3h 1m em 2 sessões**
```

## Edge cases

- Log missing → tell the user: "Sem histórico ainda — complete uma sessão para começar a registrar."
- Empty after filter → report "Nenhuma sessão encontrada para <filtro>."
- Very long rows → show `basename` of `project_dir` in the `Projeto` column; keep the full path only if asked.

To see the live (current) session time, use `/session-tracker:session-status`.
