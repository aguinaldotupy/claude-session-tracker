# Documentation Index

`session-tracker` tracks active working time, session history, and worklogs across multiple AI coding assistants, storing all metrics in a unified, local-first store.

---

## Installation & Setup Tutorials

Select your assistant to view detailed setup instructions:

| Assistant | Integration Type | Documentation Guide |
|---|---|---|
| **Claude Code** | Native Plugin (Marketplace / Local) | [Claude Code Setup Guide](claude-code.md) |
| **OpenCode** | JS Hook Adapter (`plugin.js`) | [OpenCode Setup Guide](opencode.md) |
| **Antigravity (AGY)** | Plugin Manifest & Hooks (`agy/`) | [Antigravity Setup Guide](antigravity.md) |

---

## Multi-Harness Feature Comparison

| Feature | Claude Code | OpenCode | Antigravity (AGY) |
|---|:---:|:---:|:---:|
| **Active Time Tracking** | Yes (`events.log`) | Yes (`events.log`) | Yes (`events.log`) |
| **SQLite History Store** | Yes (`history.db`) | Yes (`history.db`) | Yes (`history.db`) |
| **Slash Commands** | Yes (`/session-tracker:*`) | Yes (`/session-tracker/*`) | Via Agent Skills |
| **Agent Skills** | Yes | Yes | Yes (Native rules & skills) |
| **TUI Status Line** | Yes (`statusline-snippet.sh`) | No (TUI limitation) | No |
| **Crash Recovery Sweep** | At `SessionStart` | At `SessionStart` | Sidecar (every 5m) + `SessionStart` |
| **Solidtime Sync** | Background / Manual | Background / Manual | Sidecar / Manual / Agent |

---

## Shared Storage & Unified Worklog

Regardless of which tool you use (or if you switch between them throughout the day), all session data is centralized in `~/.session-tracker/`:

```text
~/.session-tracker/
├── history.db               # SQLite database containing all sessions and project links
├── config.yml               # Central configuration (e.g. Solidtime sync credentials)
├── current-session          # Active session pointer (during live turns)
├── solidtime-sync.log       # Background sync logs
└── <session_id>/            # Per-session data
    ├── session-tracker      # Start timestamp
    ├── events.log           # Heartbeat events (P, S, T, D)
    ├── cwd                  # Project working directory
    ├── issue-tag            # Issue key (e.g., LIN-456)
    └── solidtime-synced     # Sync ledger
```

---

## Design Specifications & Internal Plans

For deep dives into architectural decisions and protocol specs:
- [Solidtime Sync Design Spec](superpowers/specs/2026-08-21-solidtime-sync-design.md)
- [Architecture & Implementation Plans](superpowers/plans/)
