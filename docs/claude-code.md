# Claude Code Installation & Setup Guide

This guide walks you through installing, configuring, and using `session-tracker` in [Claude Code](https://claude.ai/code).

---

## Prerequisites

- **Claude Code**: version >= 2.1.x
- **`bash`** and **`jq`**: required for hook execution and read queries.
- **`sqlite3`**: recommended (pre-installed on macOS; available via `apt install sqlite3` or `brew install sqlite3`). If absent, `session-tracker` falls back to a JSON-lines store (`history.jsonl`).
- **`curl`**: required only if syncing to Solidtime.

---

## Installation Methods

### Method 1: Claude Code Marketplace (Recommended)

The easiest way to install and manage updates:

```bash
# 1. Register the marketplace catalog (one-time)
claude plugin marketplace add aguinaldotupy/claude-session-tracker

# 2. Install the plugin globally for your user
claude plugin install session-tracker@aguinaldotupy --scope user

# 3. Restart Claude Code or start a new session
claude
```

Verify installation inside Claude Code:
```
/plugin
```
Navigate to the **Installed** tab; `session-tracker` should appear active.

---

### Method 2: Local Development / Direct Flag

If you are developing or testing modifications to `session-tracker`:

```bash
# Clone the repository
git clone https://github.com/aguinaldotupy/claude-session-tracker.git
cd claude-session-tracker

# Launch Claude Code pointing directly to this directory
claude --plugin-dir .
```

---

### Method 3: Manual Git Clone

If you want to manually manage the plugin directory:

```bash
# Clone directly into Claude's plugins directory
git clone https://github.com/aguinaldotupy/claude-session-tracker.git \
  ~/.claude/plugins/marketplaces/claude-session-tracker
```

Then add or update your `~/.claude/settings.json`:

```json
{
  "enabledPlugins": {
    "session-tracker@claude-session-tracker": true
  }
}
```

### Method 4: Claude Projects and cloud sessions (claude.ai/code)

Project threads and other cloud sessions run in a throwaway Ubuntu VM. They load **nothing** from your machine: not plugins installed with Methods 1–3, and not plugins your repository's `.claude/settings.json` turns on. Adding the marketplace again from the desktop app's Code tab doesn't help either. That dialog manages your *local* plugins, which is why it answers "A marketplace with the same name as this repository already exists".

1. **Add the plugin to the project.** Open **Project settings > Plugins** and add `session-tracker`. It loads into each *new* thread; threads already running keep their old setup.
2. **Give the cloud environment the Solidtime config.** In **Project settings > Environment**, edit the environment and set:
   ```
   SOLIDTIME_URL=https://your-solidtime.example.com
   SOLIDTIME_TOKEN=...
   SOLIDTIME_ORG_ID=...
   ```
   Anyone who can use that environment can read its variables. Use an environment only you use, with a token you can revoke.
3. **Allow the Solidtime host** under the environment's network access. The default allowlist blocks it, and every sync then fails with a proxy `403`.
4. **Start a new thread** and work normally.

What to expect:

- **Cloud time only reaches Solidtime.** The VM's `~/.session-tracker` disappears with the VM, so cloud threads never show up in your local history, worklog or status line.
- **Sync runs after every turn**, not at session end, because a paused VM can be reclaimed without the session ever ending. Repeated syncs don't double-post: a turn that extends an earlier time block sends only the new part.
- **No `sqlite3` in the VM.** The store falls back to its JSON-lines file, with nothing for you to set up.
- **To check a thread**, ask it to run `bash ~/.session-tracker/session-query.sh status`. A `sync.last_error` value points at the problem (network, token or org id). The full log is at `~/.session-tracker/solidtime-sync.log` inside the VM.

Plain claude.ai chat Projects ignore plugin hooks entirely, so nothing can be tracked there.

---

## Optional: Status Line Integration

Display your active session timer directly in the Claude Code status line:

1. Locate or create your status line script at `~/.claude/statusline-command.sh`.
2. Append the snippet from [`statusline-snippet.sh`](../statusline-snippet.sh):

```bash
# Locate snippet from your cloned repo or installed marketplace plugin directory:
SNIPPET="${REPO:-$HOME/plugins/session-tracker}/statusline-snippet.sh"

if [ ! -f "$SNIPPET" ]; then
  SNIPPET=$(find ~/.claude/plugins -name "statusline-snippet.sh" 2>/dev/null | head -n 1)
fi

if [ -n "$SNIPPET" ] && [ -f "$SNIPPET" ]; then
  cat "$SNIPPET" >> ~/.claude/statusline-command.sh
  chmod +x ~/.claude/statusline-command.sh
else
  echo "Statusline snippet not found. Ensure the plugin is installed or repository is cloned."
fi
```

Ensure your `~/.claude/settings.json` has statusline enabled:

```json
{
  "statusLine": {
    "command": "bash ~/.claude/statusline-command.sh"
  }
}
```

When active, your status line displays active working time:
```text
tupy@host:project (main*) [Opus 4.6] 45m
```

---

## Usage in Claude Code

### 1. Check Session Time
Ask naturally in conversation or use the skill:
- `/session-tracker:session-status`
- *"quanto tempo de sessão?"*
- *"how long have I been working?"*

Example output:
```text
Trabalho: 48m · sessão aberta há 1h 23m (idle 35m, desde 14:30)
Hoje acumulado: 3h 12m (4 sessões)
```

### 2. Session History & Accumulated Hours
Query past sessions and accumulated time:
- `/session-tracker:session-history`
- `/session-tracker:session-history today`
- `/session-tracker:session-history 7d`
- `/session-tracker:session-history 30d`
- `/session-tracker:session-history --project my-repo`

### 3. Reset Session Timer
Zero out the active timer manually:
- `/session-tracker:reset-session`
- *"reset session timer"*
- Note: Running `/clear` in Claude Code also automatically restarts the session timer.

### 4. Issue Tagging & Worklog Posting
Tag a session with a ticket key (e.g., `PROJ-123`):
```bash
/session-tracker:tag PROJ-123
/session-tracker:tag --clear
```

If you forgot to tag a past session:
```bash
/session-tracker:tag-session a1b2c3d4 PROJ-123
```

Generate and post worklogs to connected issue trackers (Jira, Linear, Notion):
```bash
/session-tracker:worklog          # today
/session-tracker:worklog 7d       # past 7 days
```

### 5. Solidtime Sync (Optional)
Sync sessions automatically to [Solidtime](https://github.com/solidtime-io/solidtime):

1. Run the interactive setup:
   ```bash
   /session-tracker:sync-setup
   ```
2. Manually trigger a sync or inspect sync health:
   ```bash
   /session-tracker:sync
   ```

---

## Managing the Plugin

```bash
# Check installed plugins
claude plugin list

# Update to latest version
claude plugin update session-tracker@aguinaldotupy --scope user

# Temporarily disable
claude plugin disable session-tracker@aguinaldotupy --scope user

# Re-enable
claude plugin enable session-tracker@aguinaldotupy --scope user

# Uninstall
claude plugin uninstall session-tracker@aguinaldotupy --scope user
```

---

## Troubleshooting

- **Session not recording?** Verify that `~/.session-tracker/` exists. Ensure `bash` and `jq` are in your `$PATH`.
- **Nothing from a Claude Project / claude.ai/code thread?** Expected locally: cloud threads run in their own VM. See [Method 4](#method-4-claude-projects-and-cloud-sessions-claudeaicode); their time lands only in Solidtime.
- **Status line shows `--`?** The statusline snippet resolves the active session via `CLAUDE_SESSION_ID` or fallback directory. Ensure the snippet has executable permissions.
- **Inspect raw logs:** Check `~/.session-tracker/` files:
  - SQLite database: `~/.session-tracker/history.db`
  - Current session events: `~/.session-tracker/<session_id>/events.log`
  - Sync log: `~/.session-tracker/solidtime-sync.log`
