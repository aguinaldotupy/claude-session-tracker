# Antigravity (AGY) Installation & Setup Guide

This guide walks you through installing, configuring, and using `session-tracker` as a plugin for **Google Antigravity** (`agy`).

---

## Overview

In Antigravity, `session-tracker` runs as a native plugin with lifecycle hooks, context rules, agent skills, and a background sidecar. It shares the same SQLite database (`~/.session-tracker/history.db`) and Solidtime configuration as Claude Code and OpenCode.

### Architecture Highlights
- **Hook Adapter (`agy/hook-adapter.sh`)**: Translates Antigravity camelCase JSON payloads to internal hooks and guarantees strict JSON output (`decision: "allow"` or `{}`).
- **Zero-Block Contract**: Hooks fail open (`exit 0`) and never block the agent or IDE.
- **Context Rules (`agy/rules/AGENTS.md`)**: Automatically instructs agents when to use `session-status`, `session-history`, `sync`, or `reset-session`.
- **Scheduled Sidecar (`session-reaper`)**: Runs background crash sweeping and Solidtime sync every 5 minutes.
- **Shared Store**: Work done across Antigravity, Claude Code, and OpenCode seamlessly aggregates into a unified worklog and Solidtime account.

---

## Prerequisites

- **Antigravity**: Antigravity CLI (`agy`) or Antigravity IDE.
- **`bash`** and **`jq`**: required for running the hook adapter.
- **`sqlite3`**: recommended (default on macOS).
- **`curl`**: required only if using Solidtime sync.

---

## Step-by-Step Installation

### 1. Clone the Repository

Clone the repository to a permanent path (e.g. `~/plugins/session-tracker`):

```bash
git clone https://github.com/aguinaldotupy/claude-session-tracker.git ~/plugins/session-tracker
```

### 2. Install the Plugin

#### Option A: `agy plugin install` (Recommended)

```bash
agy plugin install ~/plugins/session-tracker/agy
```

Antigravity stages a **copy** of the plugin into `~/.gemini/config/plugins/session-tracker/`. The copy is self-contained: `agy/hooks` and `agy/skills/*` are symlinks into the repo, and the installer copies what they point to, so the shell hooks and skills travel with it. Check it with `agy plugin list`.

#### Option B: Symlink (Follows the Repo)

Link the plugin instead of copying it, so a `git pull` is all an update takes:

```bash
REPO=~/plugins/session-tracker
AGY_CONFIG=~/.gemini/config

mkdir -p "$AGY_CONFIG/plugins"
ln -sfn "$REPO/agy" "$AGY_CONFIG/plugins/session-tracker"
```

#### Option C: Workspace Installation (Specific Project)
If you prefer enabling it only for a specific repository:

```bash
REPO=~/plugins/session-tracker
cd /path/to/your/project

# Antigravity discovers workspace plugins in .agents/plugins/:
mkdir -p .agents/plugins
ln -sfn "$REPO/agy" .agents/plugins/session-tracker
```

---

## Updating

```bash
cd ~/plugins/session-tracker && git pull
agy plugin install ~/plugins/session-tracker/agy   # Option A only: refreshes the staged copy
```

A symlinked install (Options B and C) needs only the `git pull`. Either way, the shared libraries in `~/.session-tracker/` are refreshed the next time a **new** conversation starts (in Antigravity or any other supported editor); conversations already open keep using the previous copy until then.

---

## Enable the Background Sidecar (Recommended)

Antigravity includes a native sidecar runner. To enable the scheduled session reaper and Solidtime sync (running every 5 minutes in the background), edit your `~/.gemini/config/config.json`:

```json
{
  "sidecars": {
    "session-tracker/session-reaper": {
      "enabled": true
    }
  }
}
```

This ensures that any session terminated abruptly (such as closing the IDE or terminal) is finalized using its last event timestamp, and pending time entries are pushed to Solidtime automatically.

---

## Auto-approving Query Skills (Optional Permissions)

To allow Antigravity to run `session-query.sh` (used by the `session-status`, `session-history`, and `sync` skills) without asking for interactive confirmation each time, configure a command grant in `~/.gemini/config/config.json`:

```json
{
  "userSettings": {
    "globalPermissionGrants": {
      "allow": [
        "command(bash /Users/<your-username>/.session-tracker/session-query.sh)"
      ]
    }
  }
}
```

> [!NOTE]
> - Use `command(...)` syntax. Do **not** use `unsandboxed(...)` (which is Claude Code syntax and ignored by Antigravity).
> - Do not include dynamic flags like `--session <uuid>` in permission rules. `session-query.sh` automatically detects the live Antigravity conversation via environment variables and the per-conversation pointers in `~/.session-tracker/current-sessions/`.


---

## How Hooks Work in Antigravity

Antigravity invokes lifecycle hooks registered in [`agy/hooks.json`](../agy/hooks.json):

| AGY Event | Hook Handler | Output Contract | Internal Action |
|---|---|---|---|
| `PreInvocation` | `hook-adapter.sh pre-invocation` | `{}` (or optional `injectSteps`) | Seeds session dir, writes `current-sessions/<conversation-id>`, logs prompt `P` |
| `PreToolUse` | `hook-adapter.sh pre-tool-use` | `{"decision": "allow"}` | Logs tool start heartbeat `T <tool>` |
| `PostToolUse` | `hook-adapter.sh post-tool-use` | `{}` | Logs tool completion `D <tool>` (or failure `DF <tool>`) |
| `Stop` | `hook-adapter.sh stop` | `{"decision": "allow"}` (or `"continue"`) | Logs stop `S`, checkpoints duration to SQLite, removes `current-sessions/<conversation-id>` |

---

## Using Session Tracker in Antigravity

Because Antigravity loads the plugin's rules and skills automatically, you can interact with the tracker directly using natural language prompts with your agent:

### 1. Session Duration & Active Working Time
Ask the agent:
- *"quanto tempo de sessão?"*
- *"how long have I been working?"*
- *"session status"*

The agent invokes the `session-status` skill and reports active working time vs. wall-clock time and today's accumulated total.

### 2. Querying History & Worklogs
Ask the agent:
- *"quanto trabalhei hoje?"*
- *"worklog do dia"*
- *"histórico de sessões da última semana"*
- *"show session history for project X"*

The agent invokes the `session-history` skill with optional filters (`today`, `7d`, `30d`, `--project <name>`).

### 3. Resetting the Active Timer
Ask the agent explicitly:
- *"reset timer"*
- *"zerar timer da sessão"*
- *"restart session time"*

The agent invokes the `reset-session` skill to restart the counter for the current conversation.

### 4. Solidtime Sync
Ask the agent:
- *"sincroniza com o solidtime"*
- *"sync sessions"*
- *"is sync working?"*

The agent invokes the `sync` skill to check connectivity or push unsynced time entries.

---

## Verification & Diagnostics

1. **Verify Plugin Registration:**
   In Antigravity, run any prompt. During the turn, verify that `~/.session-tracker/current-sessions/<your-conversation-id>` exists.
2. **Inspect the SQLite Store:**
   ```bash
   sqlite3 ~/.session-tracker/history.db "SELECT session_id, duration_seconds, active_seconds, project_name FROM sessions ORDER BY start_ts DESC LIMIT 5;"
   ```
3. **Inspect Active Events Log:**
   ```bash
   cat ~/.session-tracker/<conversation_id>/events.log
   ```
4. **Check Sidecar / Sync Logs:**
   ```bash
   cat ~/.session-tracker/solidtime-sync.log
   ```
