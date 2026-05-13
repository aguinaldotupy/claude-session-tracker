---
name: session-status
description: Use when user asks about session duration, elapsed time, how long they've been working, or "quanto tempo". Also use when any skill or workflow needs to know session elapsed time.
---

# Session Status

Reports current Claude Code session elapsed time.

## Mechanism

A `SessionStart` hook writes `$(date +%s)` to `~/.claude/session-env/<session_id>/session-tracker`. The session ID is stable across compaction, so the timestamp survives context resets. The hook outputs `CLAUDE_SESSION_FILE=<path>` — use that path in the command below.

`UserPromptSubmit` and `Stop` hooks append `P <ts>` / `S <ts>` lines to `events.log` in the same directory. Active vs idle time is derived from those events: any gap between a `Stop` and the next `UserPromptSubmit` longer than `SESSION_IDLE_THRESHOLD_SECONDS` (default 300) counts as idle.

## Usage

Run this to get session elapsed time (replace `$CLAUDE_SESSION_FILE` with the path from the SessionStart hook output):

```bash
start=$(cat "$CLAUDE_SESSION_FILE" 2>/dev/null)
if [ -n "$start" ]; then
  now=$(date +%s)
  elapsed=$((now - start))

  # Idle: sum gaps between Stop and next UserPromptSubmit that exceed threshold.
  THRESHOLD="${SESSION_IDLE_THRESHOLD_SECONDS:-300}"
  EVENTS="$(dirname "$CLAUDE_SESSION_FILE")/events.log"
  idle=0
  if [ -f "$EVENTS" ]; then
    idle=$(awk -v th="$THRESHOLD" -v now="$now" '
      { kind=$1; ts=$2+0 }
      kind=="S" { last=ts; have=1; next }
      kind=="P" && have { g=ts-last; if (g>th) i+=g; have=0 }
      END { if (have) { g=now-last; if (g>th) i+=g } printf "%d", i+0 }
    ' "$EVENTS")
  fi
  [ "$idle" -gt "$elapsed" ] && idle="$elapsed"
  active=$((elapsed - idle))

  fmt() { h=$(( $1 / 3600 )); m=$(( ($1 % 3600) / 60 )); [ "$h" -gt 0 ] && printf '%dh %dm' "$h" "$m" || printf '%dm' "$m"; }
  started=$(date -r "$start" "+%H:%M" 2>/dev/null || date -d "@$start" "+%H:%M" 2>/dev/null)
  echo "Session: $(fmt "$elapsed") (active: $(fmt "$active"), idle: $(fmt "$idle"), started at ${started})"
else
  echo "Session file not found - hook may not be configured"
fi
```

## Daily Total (additional)

After showing the live session, also report today's accumulated total by summing `duration_seconds` from `$HOME/.claude/session-env/history.jsonl` for entries whose `start_ts` falls on today's local date, and adding the current live elapsed:

```bash
HISTORY="$HOME/.claude/session-env/history.jsonl"
today_past=0
if [ -f "$HISTORY" ]; then
  today=$(date +%Y-%m-%d)
  today_past=$(jq -s --arg today "$today" '
    map(select((.start_ts | strflocaltime("%Y-%m-%d")) == $today))
    | map(.duration_seconds) | add // 0
  ' "$HISTORY")
fi
total_today=$((today_past + elapsed))
th=$((total_today / 3600))
tm=$(((total_today % 3600) / 60))
if [ $th -gt 0 ]; then
  echo "Today: ${th}h ${tm}m (across finished + current sessions)"
else
  echo "Today: ${tm}m (across finished + current sessions)"
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
Session: 2h 15m (active: 1h 50m, idle: 25m, started at 14:30)
Today: 5h 42m (across finished + current sessions)
Current issue: LIN-456
```

Idle threshold is configurable via the `SESSION_IDLE_THRESHOLD_SECONDS` env var (default 300 = 5 minutes).

If the current session file is missing, inform: session tracking hook not configured.
If only the history file is missing, still show the live session and skip the Today line (or show it equal to the live elapsed).

To reset the live timer, tell the user they can use `/session-tracker:reset-session` or ask naturally.
To see a full worklog, suggest `/session-tracker:session-history`.
