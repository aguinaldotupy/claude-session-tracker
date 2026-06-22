# Design: Heartbeat-based active time (concurrent-session consistency)

- **Date:** 2026-06-22
- **Status:** Approved (pending spec review)
- **Plugin version target:** session-tracker (current 2.5.0)

## Problem

With multiple Claude Code sessions open on the **same project** on the **same device**, the
reported session time is unreliable. The headline number everywhere (statusline,
`session-status`, and `duration_seconds` in `history.jsonl`) is **wall-clock elapsed**
(`now - start`). A session left parked while the user works in a sibling session keeps
accruing wall-clock time, so its number inflates and does not reflect real attention/work.

Per-session **file isolation is already correct** — every hook and the statusline key off
`session_id` from stdin and write to `~/.claude/session-env/<session_id>/`, so concurrent
sessions never collide on disk. The defect is **semantic**, not structural.

### Root cause

The current model is **subtractive**: `active = elapsed - idle`, where `idle` is the sum of
`Stop → next Prompt` gaps exceeding a threshold (default 300s). Starting from wall-clock and
subtracting only long gaps means any period *not* recognized as a long gap is counted active —
including the time from session start to the first prompt, and a full grace per parked stretch.
That is what inflates.

## Goal

Each session reports **time that reflects real attention/work**, computed as a pure function of
its **own** `events.log`, monotonic (only grows), with no reads of sibling sessions. A parked
session must stop accruing.

## Non-goals

- **Cross-session arbitration** (crediting each wall-clock instant to at most one session).
  Rejected for now: requires persisting cwd per session, a global sweep-line merge across
  sibling logs, non-monotonic live numbers (a session's time could *shrink* on re-render), and
  it can *undercount* genuinely parallel agentic work. The heartbeats below make it tractable
  later if double-counting on fast switching ever becomes a real pain.
- **Cross-device aggregation / summing across sessions.** Out of scope.
- **Logging file paths or command contents.** Detail level B only (tool *type*, not target).

## Locked decisions

| Decision | Value |
|---|---|
| Approach | Additive active model + tool heartbeats (timeline) |
| Heartbeat detail | **B** — `<ts> <ToolName>`, no path/content |
| Heartbeat events | **PreToolUse + PostToolUse** (measures exact tool duration) |
| `grace` (reading tail after Stop) | **120s** default (was 300s), env-configurable |
| Forensic timeline surface | **Extend `session-history`** (no new command) |

## The active-time model

`events.log` is an append-only, time-ordered log of single-letter-keyed events:

```
P <ts>            # UserPromptSubmit  — prompt (existing)
T <ts> <Tool>     # PreToolUse        — tool start (new)
D <ts> <Tool>     # PostToolUse       — tool done  (new)
S <ts>            # Stop              — Claude finished (existing)
```

`active` is computed in a single pass with a terminal time `T_end` (= `now` for a live session,
= `end_ts` at SessionEnd):

```
active = 0
open      = -1     # start of the current engaged interval, or -1
last_stop = -1     # ts of the most recent Stop awaiting a reading tail, or -1

for each (kind, ts) in order:
    if kind in {P, T, D}:                 # any engagement event
        if last_stop >= 0:                # credit bounded reading tail after prev Stop
            active += min(grace, ts - last_stop)
            last_stop = -1
        if open < 0:                      # begin an engaged interval
            open = ts
    elif kind == S:
        if open >= 0:                     # close Claude-working interval
            active += ts - open
            open = -1
        last_stop = ts

# terminal (live tail)
if open >= 0:                             # mid-response right now
    active += T_end - open
elif last_stop >= 0:                      # after a Stop right now
    active += min(grace, T_end - last_stop)
```

### Why this fixes inflation

- **Before first prompt**: no engagement event → not counted.
- **Parked session**: after the last `Stop`, only `grace` (≤120s) is credited; the rest is idle.
  The number stops growing regardless of how long the session stays open.
- **Long agentic response** (one `P` … many `T/D` … one `S`, 25 min): the whole `[P, S]`
  bracket is credited — real work delivered. `T/D` heartbeats keep `open` set even if a `Stop`
  is missing (crash), so an unmatched `P` runs to `T_end`.
- **Long single tool** (e.g. 12-min `npm test`): covered by the enclosing `[P, S]` bracket;
  `T`/`D` additionally record its exact span for the timeline.

Properties: pure function of one file, monotonic, no sibling reads — the cheap path that kept
cross-session arbitration expensive does not apply here.

### Derived values

- `elapsed = T_end - start` (wall-clock) — kept as **metadata only**.
- `idle = elapsed - active` — for display ("aberta há 8h, 2h15m de trabalho").

## Hooks

- **New** `hooks/pre-tool-use.sh` — reads stdin, extracts `tool_name`, appends
  `T <ts> <Tool>` to `events.log`. Never blocks (`exit 0` on any error), mirroring the existing
  `user-prompt-submit.sh` / `stop.sh` shape.
- **New** `hooks/post-tool-use.sh` — same, appends `D <ts> <Tool>`.
- `hooks/hooks.json` — register both on `PreToolUse` / `PostToolUse` (matcher `""`, timeout 5).
- `hooks/session-end.sh` — replace the subtractive idle awk with the additive pass above to
  compute `active_seconds`. It invokes the canonical awk library directly (its sibling
  `hooks/lib/active-time.awk`). `duration_seconds` (wall-clock) and `idle_seconds` are still
  written (`idle_seconds = duration_seconds - active_seconds`), so the JSONL schema is unchanged.
- `hooks/session-start.sh` — **deploys** the canonical awk to a stable, plugin-independent path
  (`$HOME/.claude/session-env/active-time.awk`) on every start, so consumers that run outside the
  plugin directory (statusline, skills) share one implementation (see below).

The `<Tool>` token is taken from the hook's `tool_name` field verbatim (a single bareword like
`Edit`, `Bash`, `Read`). No arguments, paths, or command strings are logged.

## Single source for the active computation

The additive algorithm lives in exactly one file, `hooks/lib/active-time.awk`. Consumers reach it
two ways depending on where they run:

- **Inside the plugin** (`session-end.sh`) — references its sibling `lib/active-time.awk` directly.
- **Outside the plugin** (`statusline-snippet.sh` copied into `~/.claude/`, and the skill snippets
  run in the user's shell) — reference the **deployed copy** at
  `$HOME/.claude/session-env/active-time.awk`, which `session-start.sh` refreshes each start. If
  the deployed copy is absent (e.g. statusline configured before this version ran), they fall back
  to wall-clock.

No logic block is duplicated: there is one `.awk` source; the only copy is a runtime deploy of
that file to a known path.

## Canonical number propagation

The headline number becomes **active** everywhere; wall-clock is demoted to metadata.

- **`statusline-snippet.sh`** — compute `active` from `events.log` by invoking the deployed awk
  (`$HOME/.claude/session-env/active-time.awk`) and emit that as `session_time`, instead of
  `now - start`. Falls back to wall-clock if `events.log` or the deployed awk is absent (legacy).
- **`skills/session-status`** — `active` is the headline; show wall-clock and idle as context,
  e.g. `Trabalho: 2h15m  ·  sessão aberta há 8h02m (idle 5h47m)`.
- **`skills/session-history`** — `history.jsonl` already carries `active_seconds`; it becomes the
  value rendered in the table and summed for totals. `duration_seconds` stays available for users
  who explicitly want wall-clock.

## Forensic timeline (session-history extension)

Detail-B heartbeats let `session-history` reconstruct a per-session timeline on request. The
per-session `events.log` persists under `~/.claude/session-env/<session_id>/` after the session
ends, and `history.jsonl` carries the `session_id`, so a chosen past session's log can be read
and rendered:

```
09:13  prompt
09:13  Read ×3, Edit ×2        (2m18s ativo)
09:31  Bash                    (4m02s)
09:35  stop → idle 22m
```

Tool spans use paired `T`/`D` by tool name in order (first unmatched `D` pairs with the last open
`T` of the same name). This is an additive view in the existing skill — no new command, no schema
change to `history.jsonl`.

## reset-session

`reset-session` already truncates `events.log` (`: > events.log`) alongside rewriting the start
timestamp, so the additive `active` correctly restarts at zero. **No change required** beyond
confirming the truncation remains (it does).

## Backward compatibility

- Logs containing only `P`/`S` (pre-upgrade sessions) compute correctly: the additive pass uses
  `P` to open and `S` to close brackets; absent `T`/`D` simply means no tool detail.
- `history.jsonl` schema is unchanged (`active_seconds` already present). Old rows with a
  subtractively-computed `active_seconds` remain as-is; only new rows use the additive value.
- `SESSION_IDLE_THRESHOLD_SECONDS` is reinterpreted as the `grace` knob; default changes
  300 → 120. Document the rename/default change in CHANGELOG.

## Edge cases

- **Missing `Stop`** (crash mid-response): trailing unmatched `P`/`T` keeps `open` set → credited
  to `T_end`. At SessionEnd, `T_end = end_ts`.
- **Tool with no enclosing `P`** (should not happen): a `T`/`D` still opens an engaged interval,
  so it is credited from that event onward rather than ignored.
- **`events.log` absent** (plugin installed mid-session): statusline/`session-status` fall back to
  wall-clock and note that detail is unavailable.
- **events.log growth**: Pre+Post roughly doubles heartbeat lines vs. Pre-only; still small
  append-only text. Per-session-dir retention/cleanup is **out of scope** (pre-existing; flagged).
- **Clock**: single device → all sessions share one `date +%s`; no skew within the model.

## Affected files

- `hooks/lib/active-time.awk` — **new**; the single source for the additive computation.
- `hooks/hooks.json` — register PreToolUse + PostToolUse.
- `hooks/pre-tool-use.sh` — **new**.
- `hooks/post-tool-use.sh` — **new**.
- `hooks/session-start.sh` — deploy `active-time.awk` to `$HOME/.claude/session-env/`.
- `hooks/session-end.sh` — additive `active` computation via the sibling awk lib.
- `statusline-snippet.sh` — emit active (deployed awk), not wall-clock.
- `skills/session-status/SKILL.md` — active as headline (deployed awk); wall-clock as metadata.
- `skills/session-history/SKILL.md` — render `active_seconds`; add forensic timeline view.
- `tests/` — **new**; plain-bash suite for the awk lib and hooks.
- `CHANGELOG.md` — note canonical-number change and `grace` default 300 → 120.
- `README.md` — update the time-tracking description.

## Out of scope (future)

- Cross-session arbitration (Approach 3) — heartbeats make it feasible later.
- Cross-device aggregation; per-session-dir cleanup/retention policy; logging tool targets.
