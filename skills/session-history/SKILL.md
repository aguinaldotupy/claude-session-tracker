---
name: session-history
description: Use when user asks about past sessions, worklog, accumulated hours, "quanto trabalhei hoje", "worklog do dia", "histórico de sessões", "horas trabalhadas", "session history", or wants to review time spent on projects across sessions.
---

# Session History

Reports aggregated Claude Code session history via the `session-query` CLI, which reads the SQLite store written by the `SessionEnd` hook (with a JSON-lines fallback when `sqlite3` is unavailable).

## Mechanism

Each time a session ends, the `SessionEnd` hook upserts one row into the SQLite database at `$HOME/.claude/session-env/history.db` — one row per `session_id` in the `sessions` table (joined to `projects` for the canonical, worktree-grouped project), plus that session's heartbeats in `events`. Because the write is an upsert keyed on `session_id`, a session that ends repeatedly (e.g. across resume) stays a single row — totals are not double-counted. When `sqlite3` is absent the hook falls back to appending one JSON line to `$HOME/.claude/session-env/history.jsonl`, which the next session imports.

Each session row carries `active_seconds` (working time — what the table and totals report), `duration_seconds` (wall-clock, available on request), `branch`, and `issue_key`.

The current (still running) session is NOT in the store — only completed sessions are. If the user also wants the live elapsed time, combine with `session-tracker:session-status`.

## Usage

Call `session-query`, then render its JSON. The CLI owns the SQLite-vs-JSONL guard and the SQL/jq queries — no inline SQL needed here.

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

Only tool *types* and durations are shown — no file paths or command contents (detail level B).

## Output Format

Render a markdown table and a total, e.g.:

```
| Data       | Início | Fim   | Trabalho | Projeto         | Branch/Issue |
|------------|--------|-------|---------|-----------------|--------------|
| 2026-04-14 | 09:12  | 10:45 | 1h 33m  | session-tracker | BEL-1        |
| 2026-04-14 | 14:02  | 15:30 | 1h 28m  | onspot-web      | feature      |

**Total: 3h 1m em 2 sessões**
```

Forensic timeline renders e.g.:

```
09:13  prompt
       Read 0m12s, Edit 1m30s
09:31  stop (trabalho 18m02s)
09:35  prompt
       Bash 4m02s ✗
09:42  stop — erro de API (trabalho 7m10s)
```

## Edge cases

- `source == "none"` → tell the user: "Sem histórico ainda — complete uma sessão para começar a registrar."
- Empty `rows` after filter → report "Nenhuma sessão encontrada para <filtro>."
- Very long rows → show `basename` of the project path in the `Projeto` column (the CLI already returns the short `project` name); keep the full path only if asked.

To see the live (current) session time, use `/session-tracker:session-status`.
