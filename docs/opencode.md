# OpenCode Installation & Setup Guide

This guide walks you through installing, configuring, and using `session-tracker` in [OpenCode](https://github.com/opencode-ai/opencode).

---

## Overview

The tracking core, SQLite store, and Solidtime sync are plain shell — nothing in them is specific to Claude Code. `opencode/plugin.js` acts as a native adapter that translates OpenCode JavaScript hooks into the exact same shell hooks. Both tools share the store under `~/.session-tracker/`, allowing seamless worklog and time tracking across editors.

---

## Prerequisites

- **OpenCode**: installed and configured.
- **`bash`** and **`jq`**: required for running the hook adapter and read scripts.
- **`sqlite3`**: recommended for relational queries and worktree grouping.
- **`curl`**: required only if using Solidtime sync.

---

## Step-by-Step Installation

OpenCode discovers plugins, skills, and commands from its configuration directory (`~/.config/opencode`).

### 1. Clone the Repository

Clone `session-tracker` to a permanent location on your system:

```bash
git clone https://github.com/aguinaldotupy/claude-session-tracker.git ~/plugins/session-tracker
```

### 2. Symlink the Plugin, Skills, and Commands

Run the following commands to link `session-tracker` into OpenCode:

```bash
# Define paths
REPO=~/plugins/session-tracker
OC=~/.config/opencode

# Create target directories
mkdir -p "$OC/plugins" "$OC/skills" "$OC/commands"

# Link the JavaScript plugin adapter
ln -sf "$REPO/opencode/plugin.js" "$OC/plugins/session-tracker.js"

# Link slash commands (namespaced as /session-tracker/*)
ln -sfn "$REPO/commands" "$OC/commands/session-tracker"

# Link skills individually
for skill in "$REPO"/skills/*/; do
  ln -sfn "$skill" "$OC/skills/$(basename "$skill")"
done
```

---

## How It Works: Hook & Event Mapping

OpenCode uses a JavaScript plugin architecture. The adapter (`opencode/plugin.js`) serializes execution through a single promise chain (ensuring `events.log` remains strictly time-ordered for `active-time.awk`) and maps OpenCode's plugin hooks and event-bus notifications to the underlying shell scripts:

| Handler Type | OpenCode Hook / Event | Shell Hook Executed | Description |
|---|---|---|---|
| **Event Bus** | `event: session.created` | Initializes directory | Seeds `~/.session-tracker/<session_id>/` and records session `cwd` |
| **Plugin Hook** | `chat.message` | `hooks/user-prompt-submit.sh` | Turn start, writes prompt heartbeat `P` |
| **Plugin Hook** | `tool.execute.before` | `hooks/pre-tool-use.sh` | Tool start heartbeat `T <tool>` |
| **Plugin Hook** | `tool.execute.after` | `hooks/post-tool-use.sh` | Tool completion heartbeat `D <tool>` |
| **Event Bus** | `event: session.idle` | `hooks/stop.sh` | Turn finished, writes `S` |
| **Event Bus** | `event: session.error` | `hooks/stop-failure.sh` | Turn error, writes `SF` |
| **Plugin Hook** | `shell.env` | Injects environment | Injects `SESSION_TRACKER_SESSION_ID` and `CLAUDE_SESSION_ID` into tool calls |
| **Cleanup Hook** | Plugin cleanup (`dispose`) | `hooks/session-end.sh` | Clean exit checkpoint: computes active time and writes to SQLite |

> [!NOTE]
> The adapter exports an unload cleanup function (`dispose`) to checkpoint active sessions during clean exit. If OpenCode is forcefully terminated (`kill -9`, power loss, or terminal crash), the session is never lost: the background sweeper (`reap-sessions.sh`) automatically recovers and finalizes the session from its last recorded event during the next session start.

---

## Usage in OpenCode

Commands in OpenCode are namespaced by directory name:

### 1. Check Session Time
```text
/session-tracker/session-status
```
Or ask the agent naturally:
- *"quanto tempo de sessão?"*
- *"how long is this session?"*

### 2. Session History
```text
/session-tracker/session-history
/session-tracker/session-history today
/session-tracker/session-history 7d
```

### 3. Reset Session Timer
```text
/session-tracker/reset-session
```

### 4. Issue Tagging & Worklog
```text
/session-tracker/tag LIN-456
/session-tracker/worklog
```

### 5. Solidtime Sync
```text
/session-tracker/sync-setup
/session-tracker/sync
```

---

## Differences with Claude Code

1. **No Status Line**: OpenCode's TUI does not currently expose a custom status line hook. You can inspect active working time anytime via `/session-tracker/session-status`.
2. **Crash & Ungraceful Exit Recovery**: Clean exits trigger OpenCode's `dispose` hook. If OpenCode is terminated forcefully (e.g. `kill -9` or power loss), the session is finalized by the automatic background sweeper (`reap-sessions.sh`) on your next session start.

---

## Troubleshooting

- **Plugin not loading?** Verify that `~/.config/opencode/plugins/session-tracker.js` points to the correct absolute path of `opencode/plugin.js`.
- **Verify symlinks:**
  ```bash
  ls -la ~/.config/opencode/plugins/
  ls -la ~/.config/opencode/skills/
  ls -la ~/.config/opencode/commands/
  ```
- **Inspect session data:**
  ```bash
  ls -la ~/.session-tracker/
  sqlite3 ~/.session-tracker/history.db "SELECT * FROM sessions ORDER BY start_ts DESC LIMIT 5;"
  ```
