---
description: Group session history by issue key and propose postings to any connected MCP (Linear, Jira, Notion, ...)
disable-model-invocation: true
---

# Worklog

Turn completed sessions into structured worklog entries on whichever issue tracker the user has connected via MCP. Works with any MCP — Claude introspects the tool inventory at runtime rather than assuming a vendor.

## Arguments

Optional date filter parsed from `$ARGUMENTS`, same grammar as `/session-tracker:session-history`:

- `today` (default), `yesterday`, `7d`, `30d`, `YYYY-MM-DD`, `YYYY-MM-DD..YYYY-MM-DD`.

## Steps

1. If `$HOME/.claude/session-env/history.jsonl` is missing, tell the user there is nothing to post and stop.
2. Parse the log with `jq`, apply the date filter on `.start_ts`. Records may omit `issue_key` (older entries) — treat missing/empty as untagged.
3. **Group by `issue_key`**. For each non-empty key, compute: `total_duration_seconds`, session count, and the list of `(start_ts, end_ts)` intervals. Collect untagged entries separately under "Untagged".
4. Print a markdown summary:
   - One section per issue key with total duration (`Xh Ym`), session count, and each session's `HH:MM-HH:MM`.
   - A final "Untagged" section if any.
5. **Inline retroactive tagging.** If the Untagged section has any sessions, walk through them with the user *before* posting:
   - For each untagged session, list a short id (first 8 chars of `session_id`), human-readable `start_ts` (e.g. `2026-04-14 09:12`), duration (`Xh Ym`), and `project_dir`.
   - Prompt the user per session with three choices: **(s)kip**, **(t)ag retroactively** (then ask for the issue key), or **(b)atch-tag remaining** (then ask once for an issue key that will be applied to every remaining untagged entry).
   - Validate any provided key against `^[A-Z][A-Z0-9_]+-[0-9]+$`. Re-prompt on mismatch.
   - To persist the tag, **invoke `/session-tracker:tag-session <short_id> <KEY>` per session** rather than duplicating the `jq` rewrite here. That command handles atomicity, prefix collisions, and validation.
   - After all prompts, **re-read `history.jsonl` and re-group by `issue_key`** so the freshly tagged sessions land in their issue's bucket. Sessions the user chose to skip remain in the Untagged bucket and are excluded from the posting plan.
   - Caveat to remember: the tag rewrite is not locked against a concurrent `SessionEnd` append. The race is sub-second and unlikely for a single user — only worth a one-line warning if the user is clearly running multiple Claude Code windows.
6. **Introspect available MCP tools.** Scan the currently available tool names for patterns like `mcp__*Linear*`, `mcp__*atlassian*`, `mcp__*jira*`, `mcp__*Notion*`, `mcp__*toggl*`, `mcp__*clockify*`, or anything else that looks like a work tracker. Do NOT hardcode a list. Enumerate what you actually see and report it to the user.
7. For each grouped issue, propose a **posting plan** matched to one available MCP:
   - **Jira / Atlassian**: true worklog semantics. Post to the worklog endpoint with `timeSpent` (e.g. `2h30m`) and a comment summarizing the sessions.
   - **Linear**: no native worklog. Post a comment on the issue, e.g. `⏱ 2h30m worked — 3 sessions (HH:MM-HH:MM, ...)`.
   - **Notion**: append a row to a "Time Tracking" database **only if** the user supplies a database ID. Ask first.
   - **Other trackers** (Toggl, Clockify, etc.): adapt to their schema.
   - **No supported MCP connected**: skip posting and print a clean copy-pasteable markdown block per issue as the fallback.
8. **Before any tool call, verify the MCP tool's schema via ToolSearch** (`select:<tool_name>`) and confirm field names with the user. Different Linear/Jira MCPs disagree on field names — never assume.
9. **Show the full plan and ask for explicit confirmation** before executing any MCP tool call. The user must say yes per-issue or yes-to-all. No silent posting.
10. **Dedup check.** Before posting, read `$HOME/.claude/session-env/worklog-posted.log` and warn the user if a matching `<date> <issue_key> <tool>` line already exists for the current window. Offer to skip or re-post.
11. **After a successful post**, append one line to `$HOME/.claude/session-env/worklog-posted.log`:
    ```
    <ISO-date> <issue_key> <duration_seconds> <tool>
    ```
    (space-separated, `<ISO-date>` = today's `YYYY-MM-DD` when the worklog was submitted). Create the file if missing.

## Fallback markdown block

When no MCP is available, print (per issue) something like:

```
### LIN-456 — 2h 30m (3 sessions)
- 09:12-10:05 (53m)
- 11:00-12:20 (1h 20m)
- 14:00-14:17 (17m)
```

…so the user can paste it anywhere.

## Constraints

- Never post without confirmation.
- Never invent MCP tool field names — introspect via ToolSearch.
- Treat `issue_key == ""` as untagged; never guess the issue for untagged entries.
- Keep the plan concise: issue, total, session count, target MCP, tool call shape.
