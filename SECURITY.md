# Security Policy

## Supported Versions

Security updates are applied to the latest release and the `main` branch. Users are encouraged to stay up to date with the latest release.

| Version | Supported          |
| ------- | ------------------ |
| Latest release / `main` | :white_check_mark: |
| Older releases          | :x:                |

---

## Reporting a Vulnerability

We take the security of `session-tracker` seriously. If you discover a vulnerability or security issue, please do **not** open a public issue.

Instead, please report it through one of the following methods:

1. **GitHub Private Vulnerability Reporting (Preferred)**:
   Go to the repository's [Security tab](https://github.com/aguinaldotupy/claude-session-tracker/security/advisories) and click **"Report a vulnerability"**.

2. **Email**:
   Contact Aguinaldo Tupy at `aguinaldotupy@gmail.com` with:
   - A description of the vulnerability
   - Steps to reproduce or proof of concept
   - Potential impact
   - Any suggested mitigations

### Response Timeline
- **Acknowledgment**: Within 48 hours of report submission.
- **Assessment & Triage**: Within 5 business days.
- **Fix & Disclosure**: Coordinated release and advisory published upon patch availability.

---

## Privacy & Security Architecture

`session-tracker` is designed with local-first security principles:

- **No Sensitive Prompt or Tool Argument Logging**:
  `events.log` records only one-letter event markers and tool names (e.g., `T run_command`, `D run_command`). Arguments, prompt contents, file contents, and tool outputs are **never** captured or written to disk.

- **Credential Protection**:
  API tokens (such as `SOLIDTIME_TOKEN`) are saved only in `<home>/config.yml` (`chmod 600`) or read from environment variables. Tokens are never written to `solidtime-sync.log` or stderr, and verbose output filters out auth headers.

- **Non-Blocking Hook Safety**:
  Hooks are designed to fail open (`exit 0`) and never block host environment execution (Claude Code, OpenCode, or Antigravity).

- **Local-First SQLite Storage**:
  Session history and metrics reside strictly on your local machine in `~/.session-tracker/history.db`. External network calls only occur if Solidtime sync is explicitly configured.
