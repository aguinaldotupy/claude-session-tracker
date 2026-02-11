# session-tracker

Track Claude Code session duration with automatic timestamps.

## Features

- **SessionStart hook** - saves timestamp to `/tmp/claude-session-$PPID`
- **SessionEnd hook** - cleans up temp file
- **`/session-status` skill** - check elapsed time anytime
- **Status line snippet** - optional integration for live timer display

## Install

Add the marketplace to `~/.claude/settings.json`:

```json
{
  "pluginMarketplaces": [
    "https://github.com/aguinaldotupy/claude-code-plugins"
  ],
  "enabledPlugins": {
    "session-tracker@aguinaldotupy": true
  }
}
```

Or install locally for development:

```bash
git clone https://github.com/aguinaldotupy/session-tracker ~/.claude/plugins/marketplaces/session-tracker
```

Then enable in settings:

```json
{
  "enabledPlugins": {
    "session-tracker@session-tracker": true
  }
}
```

## Usage

Ask Claude: "how long is this session?" or type `/session-status`.

## Status Line (optional)

To show elapsed time in the status line, add the snippet from `statusline-snippet.sh` to your `~/.claude/statusline-command.sh`. Example output:

```
tupy@host:project (main*) [Opus 4.6] 45m
```

## How It Works

1. `SessionStart` hook writes Unix timestamp to `/tmp/claude-session-$PPID`
2. `$PPID` is the Claude Code process PID - unique per session
3. `/session-status` reads the file and calculates elapsed time
4. `SessionEnd` hook removes the file on exit

## Requirements

- Claude Code >= 2.1.x
- bash, date, cat (standard on macOS and Linux)

## License

MIT
