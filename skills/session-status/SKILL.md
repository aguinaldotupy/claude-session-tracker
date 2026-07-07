---
name: session-status
description: Use when user asks about session duration, elapsed time, how long they've been working, or "quanto tempo". Also use when any skill or workflow needs to know session elapsed time.
---

# Session Status

Reports current Claude Code session elapsed time.

## Mechanism

A `SessionStart` hook writes `$(date +%s)` to `~/.claude/session-env/<session_id>/session-tracker`. The session ID is stable across compaction, so the timestamp survives context resets. The hook outputs `CLAUDE_SESSION_FILE=<path>` — use that path in the command below.

`UserPromptSubmit`/`Stop` and `PreToolUse`/`PostToolUse` hooks append events to
`events.log`: `P <ts>` (prompt), `T <ts> <tool>` / `D <ts> <tool>` (tool
start/done), `S <ts>` (stop). **Active (working) time** is computed additively by
the shared awk that `SessionStart` deploys to `$HOME/.claude/session-env/active-time.awk`:
each `prompt → stop` bracket counts in full, plus up to `grace` seconds of reading
after each `Stop` (`SESSION_IDLE_THRESHOLD_SECONDS`, default 120). A session parked
while you work elsewhere stops accruing after the grace, so the number reflects real
attention rather than wall-clock. Wall-clock elapsed is reported as secondary context.

## Usage

Run this to get session elapsed time (replace `$CLAUDE_SESSION_FILE` with the path from the SessionStart hook output):

```bash
start=$(cat "$CLAUDE_SESSION_FILE" 2>/dev/null)
if [ -n "$start" ]; then
  now=$(date +%s)
  elapsed=$((now - start))                       # wall-clock (secondary)
  grace="${SESSION_IDLE_THRESHOLD_SECONDS:-120}"
  EVENTS="$(dirname "$CLAUDE_SESSION_FILE")/events.log"
  AWKLIB="$HOME/.claude/session-env/active-time.awk"

  active="$elapsed"                              # fallback when awk/events absent
  if [ -f "$EVENTS" ] && [ -f "$AWKLIB" ]; then
    active=$(awk -v grace="$grace" -v t_end="$now" -f "$AWKLIB" "$EVENTS")
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

## Daily Total (additional)

After showing the live session, also report today's accumulated total by adding
the current live active time to today's finished-session total.

Compute today's finished-session total from the SQLite store (one row per
session — no double-counting). Falls back to the legacy JSONL when `sqlite3`
or the DB is absent:

```bash
DB="$HOME/.claude/session-env/history.db"
today=$(date +%Y-%m-%d)
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB" ]; then
  today_past=$(sqlite3 "$DB" "SELECT COALESCE(SUM(active_seconds),0) FROM sessions WHERE date(start_ts,'unixepoch','localtime')='$today';")
else
  HIST="$HOME/.claude/session-env/history.jsonl"
  today_past=$([ -f "$HIST" ] && jq -s --arg t "$today" 'map(select((.start_ts|strflocaltime("%Y-%m-%d"))==$t)) | group_by(.session_id) | map(max_by(.end_ts).active_seconds) | add // 0' "$HIST" || echo 0)
fi
total_today=$((today_past + active))
```

Note the fallback jq now also dedups (`group_by(.session_id)|max_by(.end_ts)`)
so even the legacy path reports the corrected (non-inflated) total.

```bash
th=$((total_today / 3600))
tm=$(((total_today % 3600) / 60))
if [ $th -gt 0 ]; then
  echo "Trabalho hoje: ${th}h ${tm}m (sessões concluídas + atual)"
else
  echo "Trabalho hoje: ${tm}m (sessões concluídas + atual)"
fi
```

## Current Issue (additional)

If the session is associated with an issue, include one extra line. Resolution order mirrors the `SessionEnd` hook:

1. `"$(dirname "$CLAUDE_SESSION_FILE")/issue-tag"` exists → `Current issue: <KEY>`.
2. Else, if `cwd` is a git repo and the current branch matches `[A-Z][A-Z0-9_]+-[0-9]+` → `Current issue: <KEY> (from branch)`.
3. Else, omit the line entirely.

```bash
TAG_FILE="$(dirname "$CLAUDE_SESSION_FILE")/issue-tag"
if [ -f "$TAG_FILE" ]; then
  issue=$(head -n1 "$TAG_FILE" | tr -d '[:space:]')
  [ -n "$issue" ] && echo "Current issue: $issue"
elif command -v git >/dev/null 2>&1; then
  br=$(git branch --show-current 2>/dev/null || true)
  m=$(printf '%s\n' "$br" | grep -oE '[A-Z][A-Z0-9_]+-[0-9]+' | head -n1 || true)
  [ -n "$m" ] && echo "Current issue: $m (from branch)"
fi
```

## Output Format

Display to user:

```
Trabalho: 1h 50m · sessão aberta há 2h 15m (idle 25m, desde 14:30)
Trabalho hoje: 5h 42m (sessões concluídas + atual)
Current issue: LIN-456
```

The reading grace after each Stop is configurable via `SESSION_IDLE_THRESHOLD_SECONDS` (default 120 = 2 minutes). Active time is the headline; wall-clock ("aberta há…") is shown as context only.

If the current session file is missing, inform: session tracking hook not configured.
If only the history file is missing, still show the live session and skip the Trabalho hoje line (or show it equal to the live active).

To reset the live timer, tell the user they can use `/session-tracker:reset-session` or ask naturally.
To see a full worklog, suggest `/session-tracker:session-history`.
