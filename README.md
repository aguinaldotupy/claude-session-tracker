<p align="center">
  <img src="art/github-header-banner.png" alt="Session Tracker" />
</p>

# session-tracker

Track active coding time, session duration, and worklogs across **Claude Code**, **OpenCode**, and **Google Antigravity (AGY)** with automatic timestamps, SQLite persistence, and optional Solidtime sync.

## Documentation Guides

- 📘 **[Overview & Comparison](docs/README.md)**: Full architecture, multi-harness comparison matrix, and shared store reference.
- 🟣 **[Claude Code Setup Guide](docs/claude-code.md)**: Marketplace install, manual configuration, status line snippet, commands, and skills.
- 🟢 **[OpenCode Setup Guide](docs/opencode.md)**: JS plugin adapter, symlink setup, event mappings, and commands.
- 🔵 **[Antigravity (AGY) Setup Guide](docs/antigravity.md)**: Native AGY plugin manifest, lifecycle hooks, agent rules, and background sidecar.

## Features

- **SessionStart hook** - saves a start timestamp under `~/.session-tracker/<session_id>/` and reports its path as `CLAUDE_SESSION_FILE` in hook output
- **SessionEnd hook** - appends completed sessions to a JSONL history log for worklog reports
- **Active (working) time** - active time is computed additively from `events.log`: each prompt→stop bracket counts in full, plus up to `SESSION_IDLE_THRESHOLD_SECONDS` (default 120s) of reading after each turn. A session left open while you work elsewhere stops accruing, so concurrent sessions on the same project stay honest. `PreToolUse`/`PostToolUse` heartbeats record tool activity for a forensic timeline.
- **Persistent session files** - session data survives session end so you can track hours later
- **`/session-tracker:session-status` skill** - check elapsed time, plus today's accumulated total
- **`/session-tracker:session-history` command + skill** - review past sessions filtered by date or project
- **`/session-tracker:reset-session` command** - reset the timer to zero
- **Auto-reset on `/clear`** - clearing the session automatically restarts the timer
- **Status line snippet** - optional integration for live timer display

## Installation

`session-tracker` supports three coding environments out-of-the-box, sharing the same store (`~/.session-tracker/`) and Solidtime configuration:

| Assistant | Quick Setup | Detailed Tutorial |
|---|---|---|
| **Claude Code** | `claude plugin install session-tracker@aguinaldotupy --scope user` | [Claude Code Guide](docs/claude-code.md) |
| **OpenCode** | Symlink `opencode/plugin.js` to `~/.config/opencode/plugins/` | [OpenCode Guide](docs/opencode.md) |
| **Antigravity (AGY)** | Symlink `agy/` to `~/.gemini/config/plugins/session-tracker` | [Antigravity Guide](docs/antigravity.md) |

---

### Claude Code

```bash
# 1. Add marketplace catalog
claude plugin marketplace add aguinaldotupy/claude-session-tracker

# 2. Install globally
claude plugin install session-tracker@aguinaldotupy --scope user
```
*For local dev, manual clone, or status line integration, see the [Claude Code Guide](docs/claude-code.md).*

### OpenCode

```bash
REPO=~/path/to/session-tracker      # your clone
OC=~/.config/opencode

mkdir -p "$OC/plugins" "$OC/skills" "$OC/commands"
ln -sf  "$REPO/opencode/plugin.js" "$OC/plugins/session-tracker.js"
ln -sfn "$REPO/commands"           "$OC/commands/session-tracker"
for skill in "$REPO"/skills/*/; do
  ln -sfn "$skill" "$OC/skills/$(basename "$skill")"
done
```
*For hook mappings and usage, see the [OpenCode Guide](docs/opencode.md).*

### Antigravity (AGY)

```bash
REPO=~/path/to/session-tracker      # your clone
AGY_CONFIG=~/.gemini/config

mkdir -p "$AGY_CONFIG/plugins"
ln -sfn "$REPO/agy" "$AGY_CONFIG/plugins/session-tracker"
```

To enable the background session reaper & Solidtime sync sidecar in Antigravity, add to `~/.gemini/config/config.json`:

```json
{
  "sidecars": {
    "session-tracker/session-reaper": {
      "enabled": true
    }
  }
}
```
*For agent rules, skills, and sidecar configuration, see the [Antigravity Guide](docs/antigravity.md).*

### Verify Installation

Inside a Claude Code session:

```
/plugin
```

Navigate to the **Installed** tab - `session-tracker` should appear.

## Usage

### Check Session Time

Type `/session-tracker:session-status` or ask naturally:

- "how long is this session?"
- "quanto tempo de sessao?"
- "session duration"

Example output:

```
Trabalho: 48m · sessão aberta há 1h 23m (idle 35m, desde 14:30)
```

Active time credits each prompt→stop bracket fully, plus up to `SESSION_IDLE_THRESHOLD_SECONDS` seconds of reading after each turn (default 120). Tune it, e.g. `export SESSION_IDLE_THRESHOLD_SECONDS=60` for a stricter 1-minute reading grace. Wall-clock (shown as "aberta há…", i.e. "open for") is reported only as context.

### Reset Timer

Type `/session-tracker:reset-session` or ask naturally:

- "reset the session timer"
- "reiniciar o tempo"
- "restart timer"

The timer resets to zero from the current time. The `/clear` command also resets the timer automatically.

### Session History & Worklog

Each time a session ends, the `SessionEnd` hook records the session (id, start/end timestamps, duration, project, branch/issue, and exit reason) in the local SQLite database at `~/.session-tracker/history.db`. If `sqlite3` isn't installed, it falls back to appending a JSON line to `~/.session-tracker/history.jsonl` instead.

**Migration:** on the first session after upgrading, any existing `history.jsonl` is imported into SQLite automatically and renamed `history.jsonl.imported`. No action needed.

All of this is read through a single `session-query` helper (deployed to `~/.session-tracker/` on session start) that the `session-status`/`session-history` skills and the `worklog` command call and render — it owns the SQLite-vs-JSON-lines fallback and the query logic in one tested place.

Query it with `/session-tracker:session-history` or ask naturally:

- "quanto trabalhei hoje?"
- "worklog da semana"
- "session history last 7 days"
- "histórico de sessões nesse projeto"

The command accepts an optional date filter (`today`, `yesterday`, `7d`, `30d`, or `YYYY-MM-DD..YYYY-MM-DD`) and an optional `--project <substring>` filter. It prints a markdown table of sessions plus a total. See `commands/session-history.md` and `skills/session-history/SKILL.md` for details.

`/session-tracker:session-status` also reports today's accumulated total (previous completed sessions plus the current live elapsed).

### Issue Tagging & Worklog

Each finished session is tagged with an issue key (e.g. `LIN-456`, `ABC-123`) so the worklog can group time per ticket.

Resolution order used by the `SessionEnd` hook:

1. Explicit tag written via `/session-tracker:tag LIN-456` — stored at `~/.session-tracker/<session_id>/issue-tag`.
2. Branch heuristic — the first `[A-Z][A-Z0-9_]+-[0-9]+` match on the current git branch (works with common conventions like `feat/LIN-456-title`).
3. Empty if nothing resolves. Older entries without `issue_key` are treated as empty.

Tag the current session mid-flight:

```
/session-tracker:tag LIN-456
/session-tracker:tag --clear
```

Forgot to tag? Retroactively fix any session that already ended without an issue key:

```
/session-tracker:tag-session abc12345 LIN-456     # tag an old session by id prefix
/session-tracker:tag-session abc12345 --clear     # blank the tag again
```

The worklog flow itself also offers inline retroactive tagging — when it spots an "Untagged" bucket, it walks you through each session and lets you tag, batch-tag, or skip before anything is posted to your MCP.

Then post your worklog to whichever issue tracker MCP you have connected:

```
/session-tracker:worklog            # today (default)
/session-tracker:worklog 7d
/session-tracker:worklog 2026-04-01..2026-04-14
```

`/session-tracker:worklog` is **MCP-agnostic** — it introspects the tool inventory at runtime and adapts to whatever is connected. It supports true Jira worklog semantics (`timeSpent`), Linear comments (since Linear has no native worklog), and Notion time-tracking databases, and falls back to a clean copy-pasteable markdown block when no tracker MCP is available. Every post is previewed and confirmed before any tool call; posts are logged to `~/.session-tracker/worklog-posted.log` for dedup.

See `commands/tag.md` and `commands/worklog.md` for full details.

## Sync to Solidtime (optional)

Optionally sync finished sessions to a [Solidtime](https://github.com/solidtime-io/solidtime) instance (self-hosted or `solidtime.io`) for a unified, multi-machine dashboard. Each active-time bracket (a prompt→stop engagement, the same accounting used everywhere else in the plugin) becomes one Solidtime time entry, so a session's entries sum to its active time. The project is auto-created by name, and the session's issue key (e.g. `LIN-456`) becomes a Solidtime tag.

Set it up with:

```
/session-tracker:sync-setup
```

which walks you through creating an API token in the Solidtime UI, finding the organization id, and saves them to `~/.session-tracker/config.yml` (created `chmod 600` — the token is sent only to the instance you configured in `SOLIDTIME_URL`, and is never written to any other file or log). Use an `https://` URL unless your instance is on a trusted local network: the token travels as a bearer header, so a plain `http://` URL sends it in the clear.

Headless or ephemeral environments (CI, cloud, sandbox VMs) where writing that file is awkward can instead set `SOLIDTIME_URL`, `SOLIDTIME_TOKEN`, and `SOLIDTIME_ORG_ID` as environment variables. The file, when present, always takes precedence over the environment.

Sync is background and local-first: hooks never wait on the network, and a Solidtime instance that's down for days loses nothing — every finished session stays in the local store until it syncs. It runs on three triggers: automatically in the background right after a session ends, again on the next `SessionStart` to retry anything still pending, and on demand via `/session-tracker:sync`. Only sessions that end after you configure sync are sent — history recorded before setup stays local, so turning sync on never floods your Solidtime account with past work. Trigger a sync manually, or check sync health (pending count, last error), with:

```
/session-tracker:sync
```

or ask naturally ("sync my time to Solidtime", "is sync working?"). Sync activity is logged to `~/.session-tracker/solidtime-sync.log` (self-rotating). See `commands/sync.md`, `commands/sync-setup.md`, `skills/sync/SKILL.md`, and `docs/superpowers/specs/2026-08-21-solidtime-sync-design.md` for full details.

## Status Line (optional)

To show elapsed time in the status line, copy the contents of `statusline-snippet.sh` into your `~/.claude/statusline-command.sh`.

Example output:

```
tupy@host:project (main*) [Opus 4.6] 45m
```

The time shown is **active** (working) time — the same number `session-status` headlines, not wall-clock.

## How It Works

1. On session start, the `SessionStart` hook reads `session_id` from its stdin JSON and writes the start timestamp to `~/.session-tracker/<session_id>/session-tracker`, then prints that path back as `CLAUDE_SESSION_FILE` in its hook output (no `CLAUDE_ENV_FILE` indirection)
2. The session ID is stable across context compaction, so the timestamp survives compact and resume without extra hooks
3. `/session-tracker:session-status` and the statusline locate the file by `session_id` under `~/.session-tracker/<session_id>/` and read it from that per-session directory
4. Session files persist after session end - no data is lost when closing Claude Code
5. Using `/clear` or starting a new session creates a fresh timestamp
6. `UserPromptSubmit`/`Stop` and `PreToolUse`/`PostToolUse` hooks append `P`/`S` and `T`/`D <tool>` lines to `events.log`; active time is computed additively (prompt→stop brackets plus a bounded reading grace) by `hooks/lib/active-time.awk`, which `SessionStart` deploys to `~/.session-tracker/active-time.awk` for the statusline and skills to share
7. If a session dies without a `SessionEnd` — a crash, a `kill`, power loss — the next session start sweeps it up in the background and records it from its own last event, so the time still lands in your history and your Solidtime sync

## Where your data lives

Everything the plugin writes lives in one directory:

```
~/.session-tracker/
├── history.db                  # the session store (SQLite)
├── config.yml                  # plugin config (sync credentials; chmod 600)
├── solidtime-sync.log
├── <session_id>/               # one directory per session
│   ├── session-tracker         # start timestamp
│   ├── events.log              # prompt/stop/tool events
│   ├── cwd, issue-tag          # project + issue context
│   └── solidtime-synced        # per-session sync ledger
└── active-time.awk, db.sh, session-query.sh, …   # libs deployed on session start
```

Set `SESSION_TRACKER_HOME` to put it somewhere else.

### config.yml

One file for the whole plugin. Today it holds the optional Solidtime
credentials; `/session-tracker:sync-setup` writes them for you, but it is plain
YAML you can also edit by hand:

```yaml
solidtime:
  url: https://app.solidtime.io
  token: 1|abcdef...
  org_id: 0192f...
```

It is **parsed, not executed** — a token containing `|`, `#`, `$` or quotes needs
no special care. The supported syntax is deliberately small: `section:` plus one
level of `key: value`, `#` comments, and optional quotes around a value. Lists,
deeper nesting and multi-line values are not supported, and anything
unparseable is ignored rather than guessed at.

**Upgrading from v3 or earlier?** Nothing to do. The store used to live in
`~/.claude/session-env/` and the sync credentials in a shell-sourced
`solidtime.conf`; the first session start after the update moves the directory,
converts the config to `config.yml`, and keeps the originals (a symlink at the
old path, and `solidtime.conf.migrated` beside the new file). A status line
snippet you already pasted into `settings.json` keeps working untouched. Neither
path is tied to Claude Code any more, which is what lets a second harness share
the same history.

### Sessions that never got a clean shutdown

`SessionEnd` is an optimization, not a guarantee — Claude Code can be killed and
machines lose power. Everything the accounting needs is already on disk in
`events.log`, so a background sweep at session start closes any session that has
been silent for more than 4 hours, using its **last recorded event** as the end
time (never the current time — that is the last moment we know you were
working). Sessions with no events at all are left alone rather than given an
invented end time.

Two knobs, both optional:

| Variable | Default | Effect |
|---|---|---|
| `SESSION_TRACKER_STALE_SECONDS` | `14400` (4h) | Silence after which a session is treated as dead |
| `SESSION_TRACKER_REAP_WINDOW_DAYS` | `7` | How far back the sweep looks |

If a swept session turns out to still be alive, it corrects itself: the real
`SessionEnd` overwrites the swept row.

## Managing the Plugin

```bash
# Disable without uninstalling
claude plugin disable session-tracker@aguinaldotupy --scope user

# Re-enable
claude plugin enable session-tracker@aguinaldotupy --scope user

# Uninstall
claude plugin uninstall session-tracker@aguinaldotupy --scope user

# Update to latest version
claude plugin update session-tracker@aguinaldotupy --scope user
```

## Requirements

- Claude Code >= 2.1.x
- **`bash`** and **`jq`** — required. All read queries (status, history,
  timeline, worklog) run through the `session-query` helper, which needs both.
- **`sqlite3`** — recommended, not required. The session history is stored in
  a local SQLite database at `~/.session-tracker/history.db`. If `sqlite3`
  is not installed the plugin still works: `session-query` falls back to a
  JSON-lines log (`history.jsonl`) for the same reads. Install `sqlite3` to
  get the relational store, correct cross-session totals, and per-project
  (worktree-aware) grouping. Present by default on macOS.
- **`curl`** — required only for the optional Solidtime sync (see above).
  Without it, sync logs one line to `~/.session-tracker/solidtime-sync.log`
  and stays inert; everything else is unaffected. Present by default on macOS.
- **Native Windows** is not supported directly — use WSL or Git Bash, since
  the hooks and `session-query` are POSIX shell/`awk`.

## License

MIT
