---
name: session-status
description: Use when user asks about session duration, elapsed time, how long they've been working, or "quanto tempo". Also use when any skill or workflow needs to know session elapsed time.
---

# Session Status

Reports current Claude Code session elapsed time.

## Mechanism

A `SessionStart` hook writes `$(date +%s)` to `~/.claude/session-env/<session_id>/session-tracker`. The session ID is stable across compaction, so the timestamp survives context resets.

`UserPromptSubmit`/`Stop` and `PreToolUse`/`PostToolUse` hooks append events to
`events.log`: `P <ts>` (prompt), `T <ts> <tool>` / `D <ts> <tool>` (tool
start/done), `S <ts>` (stop). **Active (working) time** is computed additively by
the shared awk that `SessionStart` deploys to `$HOME/.claude/session-env/active-time.awk`:
each `prompt → stop` bracket counts in full, plus up to `grace` seconds of reading
after each `Stop` (`SESSION_IDLE_THRESHOLD_SECONDS`, default 120). A session parked
while you work elsewhere stops accruing after the grace, so the number reflects real
attention rather than wall-clock. Wall-clock elapsed is reported as secondary context.

## Usage

Get the live session and today's total in one call, then render:

```bash
bash "$HOME/.claude/session-env/session-query.sh" status --session "$CLAUDE_SESSION_ID"
```

Returns JSON: `{live:{elapsed_seconds,active_seconds,started_at,issue_key}, today:{active_seconds,sessions}}`.
Render e.g. `Sessão: 1h 10m (ativo: 52m) · hoje: 5h 05m em 5 sessões`. Convert seconds to `Xh Ym`. If `issue_key` is set, show it. `source:"none"` means no history yet.

## Output Format

Display to user:

```
Trabalho: 1h 50m · sessão aberta há 2h 15m (desde 14:30)
Trabalho hoje: 5h 42m (sessões concluídas + atual)
Current issue: LIN-456
```

Active time (`live.active_seconds`) is the headline; wall-clock (`live.elapsed_seconds`, "aberta há…") is shown as context only. `live.started_at` (epoch) formats to `desde HH:MM`. The reading grace after each Stop is configurable via `SESSION_IDLE_THRESHOLD_SECONDS` (default 120 = 2 minutes).

If `source` is `"none"` and `live.started_at` is `0`, inform: session tracking hook not configured. If only today's total is empty (`today.sessions == 0`) but `live` has data, still show the live session and skip the "Trabalho hoje" line (or show it equal to the live active).

To reset the live timer, tell the user they can use `/session-tracker:reset-session` or ask naturally.
To see a full worklog, suggest `/session-tracker:session-history`.
