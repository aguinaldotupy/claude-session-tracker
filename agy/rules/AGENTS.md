# Session Tracker Rules for Antigravity

When the user asks about working time, session duration, worklogs, or accumulated hours:
- Use the `session-status` skill to report active working time vs. wall-clock time and today's accumulated total.
- Use the `session-history` skill to query past sessions by date range (`today`, `yesterday`, `7d`, `30d`) or project.
- Use the `sync` skill to check Solidtime sync health or trigger a manual synchronization.

When the user explicitly asks to reset, restart, or zero out the session timer:
- Use the `reset-session` skill to reset the session elapsed timer.

In Antigravity, the active session corresponds to the conversation ID.
