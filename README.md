# session-tracker

Track Claude Code session duration with automatic timestamps.

## Features

- **SessionStart hook** - saves timestamp to `/tmp/claude-session-$PPID`
- **SessionEnd hook** - cleans up temp file
- **`/session-status` skill** - check elapsed time anytime
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

Type `/session-status` or ask naturally:

- "how long is this session?"
- "quanto tempo de sessao?"
- "session duration"

Example output:

```
Session: 1h 23m (started at 14:30)
```

## Status Line (optional)

To show a live elapsed time in the status line, add the snippet from `statusline-snippet.sh` to your `~/.claude/statusline-command.sh`:

```bash
# Session elapsed time
session_time=""
session_file="/tmp/claude-session-$PPID"
if [ -f "$session_file" ]; then
    start=$(cat "$session_file")
    now=$(date +%s)
    elapsed=$((now - start))
    hours=$((elapsed / 3600))
    minutes=$(((elapsed % 3600) / 60))
    if [ $hours -gt 0 ]; then
        session_time="${hours}h${minutes}m"
    else
        session_time="${minutes}m"
    fi
fi

# Append to your printf output
if [ -n "$session_time" ]; then
    printf " \033[33m%s\033[0m" "$session_time"
fi
```

Example status line output:

```
tupy@host:project (main*) [Opus 4.6] 45m
```

## How It Works

1. `SessionStart` hook writes Unix timestamp to `/tmp/claude-session-$PPID`
2. `$PPID` is the Claude Code process PID - unique per session
3. `/session-status` reads the file and calculates elapsed time
4. `SessionEnd` hook removes the file on exit

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
- bash, date, cat (standard on macOS and Linux)

## License

MIT
