# session-tracker

Track Claude Code session duration with automatic timestamps.

## Features

- **SessionStart hook** - saves timestamp in plugin directory, exports `CLAUDE_SESSION_FILE` env var
- **Persistent session files** - session data survives session end so you can track hours later
- **`/session-tracker:session-status` skill** - check elapsed time anytime
- **`/session-tracker:reset-session` command** - reset the timer to zero
- **Auto-reset on `/clear`** - clearing the session automatically restarts the timer
- **Status line snippet** - optional integration for live timer display

## Installation

### Option 1: From Marketplace (recommended)

```bash
# Add as a standalone marketplace plugin
claude plugin marketplace add aguinaldotupy/claude-session-tracker

# Install the plugin
claude plugin install session-tracker@aguinaldotupy --scope user

# Restart Claude Code to activate hooks
```

### Option 2: Local Install (development)

```bash
git clone https://github.com/aguinaldotupy/claude-session-tracker.git
claude --plugin-dir ./claude-session-tracker
```

### Option 3: Manual Install

```bash
# Clone into the plugins directory
git clone https://github.com/aguinaldotupy/claude-session-tracker.git \
  ~/.claude/plugins/marketplaces/claude-session-tracker
```

Then enable in `~/.claude/settings.json`:

```json
{
  "enabledPlugins": {
    "session-tracker@claude-session-tracker": true
  }
}
```

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
Session: 1h 23m (started at 14:30)
```

### Reset Timer

Type `/session-tracker:reset-session` or ask naturally:

- "reset the session timer"
- "reiniciar o tempo"
- "restart timer"

The timer resets to zero from the current time. The `/clear` command also resets the timer automatically.

## Status Line (optional)

To show elapsed time in the status line, copy the contents of `statusline-snippet.sh` into your `~/.claude/statusline-command.sh`.

Example output:

```
tupy@host:project (main*) [Opus 4.6] 45m
```

## How It Works

1. On session start, a timestamp is saved to the plugin directory as `session-tracker-$SESSION_ID` and the full path is exported as `CLAUDE_SESSION_FILE` via `CLAUDE_ENV_FILE`
2. The session ID is stable across context compaction, so the timestamp survives compact and resume without extra hooks
3. `/session-tracker:session-status` and the statusline read the file using `$CLAUDE_SESSION_FILE`
4. Session files persist after session end - no data is lost when closing Claude Code
5. Using `/clear` or starting a new session creates a fresh timestamp

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
- bash, date, cat, jq (standard on macOS and Linux; install jq if missing)

## License

MIT
