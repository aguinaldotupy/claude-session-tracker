# Contributing to session-tracker

Thank you for your interest in contributing to `session-tracker`! This project is a multi-harness plugin tracking active coding time, session history, and worklogs across **Claude Code**, **OpenCode**, and **Google Antigravity (AGY)**.

Please read this guide and our [Code of Conduct](CODE_OF_CONDUCT.md) before submitting contributions.

---

## Development Philosophy & Architecture

`session-tracker` is built with a minimalist, robust, zero-build philosophy:
- **Runtime**: Pure Bash shell scripts + `awk` + `jq` + SQLite. No npm, Python, pip, or package managers required.
- **Multi-Harness**: The store (`~/.session-tracker/`), history, time model, and Solidtime sync are harness-neutral. Adapters (`hooks/`, `opencode/plugin.js`, `agy/hook-adapter.sh`) map each assistant's lifecycle events into the same shell core.
- **Fail-Open Contract**: Hooks must **never** block the editor or agent. Every hook handles errors gracefully and exits `0`.
- **Local-First & Private**: Event logs only track timestamps and tool names (`events.log`), never tool arguments or prompt text.

---

## Getting Started

### Prerequisites
- **`bash`** (4.x+)
- **`jq`** (1.6+)
- **`sqlite3`** (for relational queries)
- **`curl`** (optional, for Solidtime sync testing)

### Local Setup
Clone the repository:
```bash
git clone https://github.com/aguinaldotupy/claude-session-tracker.git
cd claude-session-tracker
```

---

## Running Tests

All automated tests in the test suite must pass cleanly without failures. All tests run hermetically: each test file creates an isolated temporary directory via `mktemp -d` and re-exports `HOME`, so your personal `~/.session-tracker/` is never touched.

```bash
# Run the entire test suite
bash tests/run.sh

# Run a specific test suite
bash tests/session-query.test.sh
bash tests/session-start.test.sh
bash tests/session-end.test.sh
bash tests/reap.test.sh
bash tests/opencode-plugin.test.sh
bash tests/agy-plugin.test.sh
bash tests/solidtime-sync.test.sh
```

When writing new tests:
- Use assertions from `tests/lib.sh` (`assert_eq`, `assert_match`, `finish`).
- Ensure test cases clean up background processes or subshells.
- Verify that tests run deterministically with `SESSION_IDLE_THRESHOLD_SECONDS` unset.

---

## Key Invariants & Rules

When modifying or adding code, adhere strictly to these principles:

1. **Non-Blocking Execution**: Hooks have a strict 5-second timeout in `hooks.json`. Ensure every hook exits 0 even on syntax or runtime failures.
2. **Strict JSON Outputs**:
   - `session-query.sh` commands must always emit valid JSON on stdout and suppress stderr.
   - Antigravity hooks must output valid JSON (`{"decision": "allow"}` or `{}`).
3. **Never Hardcode Store Paths**: Always use `st_home` from `hooks/lib/db.sh` or `${SESSION_TRACKER_HOME:-$HOME/.session-tracker}`.
4. **Deploy Libs with Temp-file + Rename**: Detached processes (like `solidtime-sync.sh`) read scripts lazily by byte offset. Never overwrite files in-place with `cp -f`; write to a temporary file and atomically `mv` it.
5. **No Credential Leaks**: API tokens must never appear in log files or stderr.
6. **Time Window Synchronization**: Resetting a session (e.g. `/clear` or `reset-session`) must update both the start timestamp and truncate `events.log` in sync to avoid over-billing active time.

---

## Pull Request Process

1. **Create a branch**:
   ```bash
   git checkout -b feat/your-feature-name
   # or
   git checkout -b fix/your-bug-description
   ```
2. **Commit your changes**:
   Use clear, conventional commit messages:
   - `feat: add feature description`
   - `fix: resolve specific bug`
   - `docs: update documentation`
   - `test: add regression test`
3. **Verify tests and code review**:
   - Run `bash tests/run.sh` to ensure all tests pass.
   - Run `coderabbit review` if available.
4. **Submit a Pull Request**:
   Fill out the PR template with a summary of changes, motivation, and verification steps.

---

## Releases

Releases follow [Semantic Versioning](https://semver.org/). Releases are created via the automated `/release` skill, which updates the version in `.claude-plugin/plugin.json`, documents changes in `CHANGELOG.md`, tags the commit, and publishes the GitHub release.
