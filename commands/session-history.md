---
description: Show session history with duration totals, optionally filtered by date range or project
disable-model-invocation: true
---

# Session History

Read the session history log at `$HOME/.claude/session-env/history.jsonl` and display a summary of past sessions.

## Arguments

Optional arguments parsed from `$ARGUMENTS`:

- Date filter (first positional):
  - `today` — sessions whose `start_ts` falls on today's local date
  - `yesterday` — sessions from yesterday's local date
  - `7d` — last 7 days (rolling window)
  - `30d` — last 30 days (rolling window)
  - `YYYY-MM-DD..YYYY-MM-DD` — explicit inclusive date range
  - If omitted, default to `today`.
- `--project <substring>` — only include entries whose `project_dir` contains this substring (case-insensitive).

## Behavior

1. If `$HOME/.claude/session-env/history.jsonl` does not exist, report: "No session history yet. Complete at least one session to build a log."
2. Parse each JSONL line with `jq`. Each record has: `session_id`, `start_ts`, `end_ts`, `duration_seconds`, `project_dir`, `reason`.
3. Apply the date and project filters.
4. Print a markdown table with columns: `Date | Start | End | Duration | Project`.
   - `Date` formatted as `YYYY-MM-DD`.
   - `Start` / `End` formatted as `HH:MM` (local time).
   - `Duration` formatted as `Xh Ym` (or `Ym` when under an hour).
   - `Project` = basename of `project_dir` (full path shown only if there's ambiguity).
5. Print a footer line: `**Total: Xh Ym** across N session(s).`

## Implementation hint

Use `jq` with `strftime` / `strflocaltime` to format timestamps:

```bash
jq -r '[( .start_ts | strflocaltime("%Y-%m-%d") ),
        ( .start_ts | strflocaltime("%H:%M") ),
        ( .end_ts   | strflocaltime("%H:%M") ),
        .duration_seconds,
        .project_dir] | @tsv' "$HOME/.claude/session-env/history.jsonl"
```

Apply filters before formatting, sum `duration_seconds` for the total, and render as markdown.

Display the resulting table and total to the user.
