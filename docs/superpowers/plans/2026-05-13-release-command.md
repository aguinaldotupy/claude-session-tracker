# `/release` Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a user-level `/release` slash command + supporting skill that bumps semver, generates a CHANGELOG entry from Conventional Commits, tags, pushes, and creates a GitHub release in one shot.

**Architecture:** A thin slash command (`~/.claude/commands/release.md`) delegates to a skill (`~/.claude/skills/release-flow/`). The skill's logic lives in a small bash helper library (`lib/release.sh`) made of pure functions that can be unit-tested. The skill's `SKILL.md` orchestrates: preflight → confirm → execute, calling the library and external tools (`git`, `gh`, `jq`).

**Tech Stack:** Bash 3.2+ (macOS-compatible), `jq` for JSON, `git`, `gh` CLI. Optional `tomlq`/`yq` for TOML manifests with a `grep`/`sed` fallback. Test framework: plain bash with an inline `assert_eq` helper — no external dependency.

---

## File Structure

```
~/.claude/
├── commands/
│   └── release.md                       # slash command entry point
└── skills/
    └── release-flow/
        ├── SKILL.md                     # orchestration (bash recipe)
        ├── lib/
        │   └── release.sh               # pure helper functions
        └── tests/
            ├── run.sh                   # test runner + assert_eq
            ├── fixtures/                # sample manifests for tests
            │   ├── plugin.json
            │   ├── package.json
            │   ├── pyproject.toml
            │   └── Cargo.toml
            ├── test_parse_remote.sh
            ├── test_next_version.sh
            ├── test_infer_bump.sh
            ├── test_manifest_io.sh
            └── test_changelog.sh
```

**Boundary:** `lib/release.sh` contains only pure functions (string transforms, file IO on paths you pass in). All `git`/`gh`/network/interactive prompts live in `SKILL.md`. This keeps the unit-testable surface isolated from the side-effecting orchestration.

---

### Task 1: Scaffold directories and test runner

**Files:**
- Create: `~/.claude/skills/release-flow/lib/release.sh`
- Create: `~/.claude/skills/release-flow/tests/run.sh`
- Create: `~/.claude/skills/release-flow/tests/fixtures/` (directory)

- [ ] **Step 1: Create directory tree**

```bash
mkdir -p ~/.claude/skills/release-flow/lib
mkdir -p ~/.claude/skills/release-flow/tests/fixtures
mkdir -p ~/.claude/commands
```

- [ ] **Step 2: Create the test runner**

Write `~/.claude/skills/release-flow/tests/run.sh`:

```bash
#!/usr/bin/env bash
# Tiny bash test runner. Sources lib/release.sh, then sources each test_*.sh
# file in the same directory. Tests call assert_eq / assert_match.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib/release.sh"

PASS=0
FAIL=0
CURRENT_TEST=""

assert_eq() {
  local expected="$1" actual="$2" label="${3:-}"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    printf '  FAIL [%s] %s\n    expected: %q\n    actual:   %q\n' \
      "$CURRENT_TEST" "$label" "$expected" "$actual"
  fi
}

assert_match() {
  local pattern="$1" actual="$2" label="${3:-}"
  if printf '%s' "$actual" | grep -qE "$pattern"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    printf '  FAIL [%s] %s\n    pattern: %s\n    actual:  %q\n' \
      "$CURRENT_TEST" "$label" "$pattern" "$actual"
  fi
}

run_test() {
  CURRENT_TEST="$1"
  printf '• %s\n' "$CURRENT_TEST"
  "$1"
}

# Source library and all test files
# shellcheck source=/dev/null
. "$LIB"
for f in "$SCRIPT_DIR"/test_*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done

# Each test_*.sh file defines functions starting with `test_`. Discover & run them.
for fn in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
  run_test "$fn"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 3: Create empty library stub**

Write `~/.claude/skills/release-flow/lib/release.sh`:

```bash
#!/usr/bin/env bash
# Pure helper functions for the release-flow skill.
# No git/gh/network calls live here — those belong in SKILL.md orchestration.

# Functions will be added incrementally per the implementation plan.
:
```

- [ ] **Step 4: Verify runner with zero tests**

Run: `bash ~/.claude/skills/release-flow/tests/run.sh`
Expected output: `0 passed, 0 failed` and exit code 0.

- [ ] **Step 5: Commit**

```bash
cd ~/.claude
git add skills/release-flow commands 2>/dev/null || true
# If ~/.claude is not a git repo, skip the commit and note it in the final summary.
git diff --cached --quiet || git commit -m "chore(release-flow): scaffold skill directory and test runner"
```

---

### Task 2: `parse_remote_url` — extract owner/repo from git remote

**Files:**
- Modify: `~/.claude/skills/release-flow/lib/release.sh`
- Create: `~/.claude/skills/release-flow/tests/test_parse_remote.sh`

- [ ] **Step 1: Write failing tests**

Write `~/.claude/skills/release-flow/tests/test_parse_remote.sh`:

```bash
test_parse_remote_ssh() {
  assert_eq "aguinaldotupy/claude-session-tracker" \
    "$(parse_remote_url 'git@github.com:aguinaldotupy/claude-session-tracker.git')" \
    "ssh url"
}

test_parse_remote_https() {
  assert_eq "aguinaldotupy/claude-session-tracker" \
    "$(parse_remote_url 'https://github.com/aguinaldotupy/claude-session-tracker.git')" \
    "https url"
}

test_parse_remote_no_dot_git() {
  assert_eq "owner/repo" \
    "$(parse_remote_url 'https://github.com/owner/repo')" \
    "no .git suffix"
}

test_parse_remote_unknown_format() {
  assert_eq "" \
    "$(parse_remote_url 'not-a-url' 2>/dev/null)" \
    "unrecognized input returns empty"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash ~/.claude/skills/release-flow/tests/run.sh`
Expected: 4 failures, all with `parse_remote_url: command not found`.

- [ ] **Step 3: Implement `parse_remote_url`**

Append to `~/.claude/skills/release-flow/lib/release.sh`:

```bash
# parse_remote_url <url> -> "owner/repo" on stdout, empty if unrecognized.
parse_remote_url() {
  local url="$1"
  local stripped="${url%.git}"
  case "$stripped" in
    git@github.com:*)            printf '%s' "${stripped#git@github.com:}" ;;
    https://github.com/*)        printf '%s' "${stripped#https://github.com/}" ;;
    ssh://git@github.com/*)      printf '%s' "${stripped#ssh://git@github.com/}" ;;
    *)                            return 1 ;;
  esac
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash ~/.claude/skills/release-flow/tests/run.sh`
Expected: `4 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
cd ~/.claude
git add skills/release-flow/lib/release.sh skills/release-flow/tests/test_parse_remote.sh
git diff --cached --quiet || git commit -m "feat(release-flow): parse_remote_url for github ssh/https"
```

---

### Task 3: `next_version` — compute next semver

**Files:**
- Modify: `~/.claude/skills/release-flow/lib/release.sh`
- Create: `~/.claude/skills/release-flow/tests/test_next_version.sh`

- [ ] **Step 1: Write failing tests**

Write `~/.claude/skills/release-flow/tests/test_next_version.sh`:

```bash
test_next_version_patch() {
  assert_eq "2.5.1" "$(next_version 2.5.0 patch)" "patch bump"
}

test_next_version_minor_resets_patch() {
  assert_eq "2.6.0" "$(next_version 2.5.3 minor)" "minor resets patch"
}

test_next_version_major_resets_minor_and_patch() {
  assert_eq "3.0.0" "$(next_version 2.5.3 major)" "major resets minor and patch"
}

test_next_version_v_prefix_stripped() {
  assert_eq "1.0.1" "$(next_version v1.0.0 patch)" "leading v is stripped"
}

test_next_version_invalid_level_errors() {
  ( next_version 1.0.0 weird ) 2>/dev/null
  assert_eq "1" "$?" "unknown level returns non-zero"
}

test_next_version_invalid_version_errors() {
  ( next_version "1.0" patch ) 2>/dev/null
  assert_eq "1" "$?" "non-X.Y.Z input returns non-zero"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash ~/.claude/skills/release-flow/tests/run.sh`
Expected: 6 failures, `next_version: command not found`.

- [ ] **Step 3: Implement `next_version`**

Append to `~/.claude/skills/release-flow/lib/release.sh`:

```bash
# next_version <current> <patch|minor|major> -> next semver on stdout.
# Strips a leading "v" from <current>. Returns non-zero on bad input.
next_version() {
  local current="${1#v}"
  local level="$2"
  case "$current" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) return 1 ;;
  esac
  local major="${current%%.*}"
  local rest="${current#*.}"
  local minor="${rest%%.*}"
  local patch="${rest#*.}"
  case "$level" in
    major) printf '%d.0.0\n'    "$((major+1))" ;;
    minor) printf '%d.%d.0\n'   "$major" "$((minor+1))" ;;
    patch) printf '%d.%d.%d\n'  "$major" "$minor" "$((patch+1))" ;;
    *)     return 1 ;;
  esac
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash ~/.claude/skills/release-flow/tests/run.sh`
Expected: 10 passed total (4 from Task 2 + 6 here), 0 failed.

- [ ] **Step 5: Commit**

```bash
cd ~/.claude
git add skills/release-flow/lib/release.sh skills/release-flow/tests/test_next_version.sh
git diff --cached --quiet || git commit -m "feat(release-flow): next_version semver bumper"
```

---

### Task 4: `infer_bump` — classify Conventional Commits

**Files:**
- Modify: `~/.claude/skills/release-flow/lib/release.sh`
- Create: `~/.claude/skills/release-flow/tests/test_infer_bump.sh`

- [ ] **Step 1: Write failing tests**

Write `~/.claude/skills/release-flow/tests/test_infer_bump.sh`:

```bash
test_infer_bump_breaking_subject() {
  local input='feat!: drop python 3.8 support'
  assert_eq "major" "$(printf '%s\n' "$input" | infer_bump)" "feat! → major"
}

test_infer_bump_breaking_body() {
  local input='feat: new auth flow

BREAKING CHANGE: tokens are now required'
  assert_eq "major" "$(printf '%s\n' "$input" | infer_bump)" "BREAKING CHANGE body → major"
}

test_infer_bump_feat() {
  assert_eq "minor" "$(printf 'feat: add /release command\n' | infer_bump)" "feat → minor"
}

test_infer_bump_feat_with_scope() {
  assert_eq "minor" "$(printf 'feat(cli): add flag\n' | infer_bump)" "feat(scope) → minor"
}

test_infer_bump_fix() {
  assert_eq "patch" "$(printf 'fix: handle empty changelog\n' | infer_bump)" "fix → patch"
}

test_infer_bump_only_docs_defaults_patch() {
  local input='docs: tweak readme
chore: bump deps'
  assert_eq "patch" "$(printf '%s\n' "$input" | infer_bump)" "no feat/fix → patch"
}

test_infer_bump_highest_wins() {
  local input='fix: small thing
feat: new behaviour
docs: notes'
  assert_eq "minor" "$(printf '%s\n' "$input" | infer_bump)" "feat outranks fix"
}

test_infer_bump_empty_input() {
  ( printf '' | infer_bump ) 2>/dev/null
  assert_eq "1" "$?" "empty input returns non-zero"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash ~/.claude/skills/release-flow/tests/run.sh`
Expected: 8 new failures.

- [ ] **Step 3: Implement `infer_bump`**

Append to `~/.claude/skills/release-flow/lib/release.sh`:

```bash
# infer_bump  — reads commit messages from stdin (one commit per blank-line
# separated block, OR one subject per line). Prints major|minor|patch.
# Returns 1 if stdin is empty.
infer_bump() {
  local input
  input="$(cat)"
  [ -z "$input" ] && return 1

  # If any line/block triggers major, return major immediately.
  if printf '%s\n' "$input" | grep -qE '^[a-z]+(\([^)]+\))?!:' ; then
    printf 'major\n'; return 0
  fi
  if printf '%s\n' "$input" | grep -qE '^BREAKING CHANGE:' ; then
    printf 'major\n'; return 0
  fi
  if printf '%s\n' "$input" | grep -qE '^feat(\([^)]+\))?:' ; then
    printf 'minor\n'; return 0
  fi
  # Default: patch (fix/perf/refactor or docs-only fallback)
  printf 'patch\n'
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash ~/.claude/skills/release-flow/tests/run.sh`
Expected: 18 passed total, 0 failed.

- [ ] **Step 5: Commit**

```bash
cd ~/.claude
git add skills/release-flow/lib/release.sh skills/release-flow/tests/test_infer_bump.sh
git diff --cached --quiet || git commit -m "feat(release-flow): infer_bump classifies conventional commits"
```

---

### Task 5: Manifest detection and version IO

**Files:**
- Modify: `~/.claude/skills/release-flow/lib/release.sh`
- Create: `~/.claude/skills/release-flow/tests/test_manifest_io.sh`
- Create: `~/.claude/skills/release-flow/tests/fixtures/plugin.json`
- Create: `~/.claude/skills/release-flow/tests/fixtures/package.json`
- Create: `~/.claude/skills/release-flow/tests/fixtures/pyproject.toml`
- Create: `~/.claude/skills/release-flow/tests/fixtures/Cargo.toml`

- [ ] **Step 1: Create fixture files**

`~/.claude/skills/release-flow/tests/fixtures/plugin.json`:
```json
{ "name": "demo", "version": "1.2.3" }
```

`~/.claude/skills/release-flow/tests/fixtures/package.json`:
```json
{ "name": "demo", "version": "0.4.5" }
```

`~/.claude/skills/release-flow/tests/fixtures/pyproject.toml`:
```toml
[project]
name = "demo"
version = "0.9.0"
```

`~/.claude/skills/release-flow/tests/fixtures/Cargo.toml`:
```toml
[package]
name = "demo"
version = "1.0.0"
```

- [ ] **Step 2: Write failing tests**

Write `~/.claude/skills/release-flow/tests/test_manifest_io.sh`:

```bash
_setup_repo() {
  local layout="$1"
  local dir; dir="$(mktemp -d)"
  case "$layout" in
    plugin) mkdir -p "$dir/.claude-plugin"; cp "$SCRIPT_DIR/fixtures/plugin.json" "$dir/.claude-plugin/plugin.json" ;;
    node)   cp "$SCRIPT_DIR/fixtures/package.json" "$dir/" ;;
    py)     cp "$SCRIPT_DIR/fixtures/pyproject.toml" "$dir/" ;;
    rust)   cp "$SCRIPT_DIR/fixtures/Cargo.toml" "$dir/" ;;
  esac
  printf '%s' "$dir"
}

test_detect_manifest_plugin_priority() {
  local dir; dir="$(_setup_repo plugin)"
  cp "$SCRIPT_DIR/fixtures/package.json" "$dir/"
  # plugin.json must win over package.json
  assert_eq ".claude-plugin/plugin.json" "$(detect_manifest "$dir")" "plugin wins"
  rm -rf "$dir"
}

test_detect_manifest_node() {
  local dir; dir="$(_setup_repo node)"
  assert_eq "package.json" "$(detect_manifest "$dir")" "node detected"
  rm -rf "$dir"
}

test_detect_manifest_python() {
  local dir; dir="$(_setup_repo py)"
  assert_eq "pyproject.toml" "$(detect_manifest "$dir")" "python detected"
  rm -rf "$dir"
}

test_detect_manifest_rust() {
  local dir; dir="$(_setup_repo rust)"
  assert_eq "Cargo.toml" "$(detect_manifest "$dir")" "rust detected"
  rm -rf "$dir"
}

test_detect_manifest_none() {
  local dir; dir="$(mktemp -d)"
  ( detect_manifest "$dir" ) 2>/dev/null
  assert_eq "1" "$?" "no manifest returns non-zero"
  rm -rf "$dir"
}

test_read_version_plugin() {
  local dir; dir="$(_setup_repo plugin)"
  assert_eq "1.2.3" "$(read_version "$dir/.claude-plugin/plugin.json")" "json version"
  rm -rf "$dir"
}

test_read_version_pyproject() {
  local dir; dir="$(_setup_repo py)"
  assert_eq "0.9.0" "$(read_version "$dir/pyproject.toml")" "toml version"
  rm -rf "$dir"
}

test_write_version_json() {
  local dir; dir="$(_setup_repo plugin)"
  write_version "$dir/.claude-plugin/plugin.json" "9.9.9"
  assert_eq "9.9.9" "$(read_version "$dir/.claude-plugin/plugin.json")" "json round-trip"
  rm -rf "$dir"
}

test_write_version_toml() {
  local dir; dir="$(_setup_repo py)"
  write_version "$dir/pyproject.toml" "2.0.0"
  assert_eq "2.0.0" "$(read_version "$dir/pyproject.toml")" "toml round-trip"
  rm -rf "$dir"
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash ~/.claude/skills/release-flow/tests/run.sh`
Expected: 9 new failures.

- [ ] **Step 4: Implement manifest helpers**

Append to `~/.claude/skills/release-flow/lib/release.sh`:

```bash
# detect_manifest <repo_dir> -> path to manifest, relative to <repo_dir>.
# Detection order: plugin.json, package.json, pyproject.toml, Cargo.toml.
detect_manifest() {
  local dir="$1"
  if [ -f "$dir/.claude-plugin/plugin.json" ]; then
    printf '.claude-plugin/plugin.json\n'; return 0
  fi
  if [ -f "$dir/package.json" ]; then
    printf 'package.json\n'; return 0
  fi
  if [ -f "$dir/pyproject.toml" ]; then
    printf 'pyproject.toml\n'; return 0
  fi
  if [ -f "$dir/Cargo.toml" ]; then
    printf 'Cargo.toml\n'; return 0
  fi
  return 1
}

# read_version <manifest_path> -> version string on stdout.
read_version() {
  local path="$1"
  case "$path" in
    *.json)
      jq -r '.version' "$path"
      ;;
    *.toml)
      # Grep the first `version = "X.Y.Z"` line. Handles top-level [package]
      # or [project] tables. If the manifest has multiple version keys (e.g.
      # dependency pins), the first one wins — that's the package version
      # for both Cargo.toml and pyproject.toml in standard layouts.
      grep -m1 -E '^version[[:space:]]*=[[:space:]]*"[^"]+"' "$path" \
        | sed -E 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/'
      ;;
    *) return 1 ;;
  esac
}

# write_version <manifest_path> <new_version>
write_version() {
  local path="$1" new="$2"
  case "$path" in
    *.json)
      local tmp; tmp="$(mktemp)"
      jq --arg v "$new" '.version = $v' "$path" > "$tmp" && mv "$tmp" "$path"
      ;;
    *.toml)
      # Replace the first version line only. Portable BSD/GNU sed via a temp file.
      local tmp; tmp="$(mktemp)"
      awk -v new="$new" '
        BEGIN { done=0 }
        !done && /^version[[:space:]]*=[[:space:]]*"[^"]+"/ {
          sub(/"[^"]+"/, "\"" new "\"")
          done=1
        }
        { print }
      ' "$path" > "$tmp" && mv "$tmp" "$path"
      ;;
    *) return 1 ;;
  esac
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash ~/.claude/skills/release-flow/tests/run.sh`
Expected: 27 passed total, 0 failed.

- [ ] **Step 6: Commit**

```bash
cd ~/.claude
git add skills/release-flow/lib/release.sh skills/release-flow/tests/test_manifest_io.sh skills/release-flow/tests/fixtures
git diff --cached --quiet || git commit -m "feat(release-flow): detect/read/write version across json+toml manifests"
```

---

### Task 6: `generate_changelog_entry` — group commits into Keep-a-Changelog format

**Files:**
- Modify: `~/.claude/skills/release-flow/lib/release.sh`
- Create: `~/.claude/skills/release-flow/tests/test_changelog.sh`

- [ ] **Step 1: Write failing tests**

Write `~/.claude/skills/release-flow/tests/test_changelog.sh`:

```bash
test_changelog_groups_by_type() {
  local input='feat: add /release command
fix: handle empty changelog
docs: tweak readme
refactor: extract helper'
  local expected='## [2.6.0] - 2026-05-13

### Added
- add /release command

### Fixed
- handle empty changelog

### Changed
- extract helper'
  assert_eq "$expected" \
    "$(printf '%s\n' "$input" | generate_changelog_entry 2.6.0 2026-05-13)" \
    "grouped sections"
}

test_changelog_breaking_marked() {
  local input='feat!: drop old api
fix: minor'
  local out; out="$(printf '%s\n' "$input" | generate_changelog_entry 3.0.0 2026-05-13)"
  assert_match '\*\*Breaking:\*\* drop old api' "$out" "breaking prefix"
}

test_changelog_skips_when_no_relevant_commits() {
  local input='docs: x
chore: y'
  local out; out="$(printf '%s\n' "$input" | generate_changelog_entry 1.0.1 2026-05-13)"
  # Even when nothing maps, we still get a header + a "No notable changes" line.
  assert_match '## \[1.0.1\] - 2026-05-13' "$out" "header always present"
  assert_match 'No notable changes' "$out" "fallback line"
}

test_changelog_strips_scope() {
  local input='feat(cli): new flag'
  local out; out="$(printf '%s\n' "$input" | generate_changelog_entry 1.1.0 2026-05-13)"
  assert_match '- new flag' "$out" "scope removed from bullet"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash ~/.claude/skills/release-flow/tests/run.sh`
Expected: 4 new failures.

- [ ] **Step 3: Implement `generate_changelog_entry`**

Append to `~/.claude/skills/release-flow/lib/release.sh`:

```bash
# generate_changelog_entry <version> <iso_date>  -- reads commit subjects from
# stdin (one per line) and prints a Keep-a-Changelog section to stdout.
# Mapping: feat→Added, fix→Fixed, refactor/perf→Changed, breaking→Changed
# with **Breaking:** prefix. Other types (docs/chore/test/style/build/ci)
# are ignored. If nothing matched, emits "No notable changes."
generate_changelog_entry() {
  local version="$1" date="$2"
  local added=() fixed=() changed=()

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Detect breaking: type! or type(scope)!
    if [[ "$line" =~ ^([a-z]+)(\([^)]+\))?!: ]]; then
      local desc="${line#*: }"
      changed+=("**Breaking:** $desc")
      continue
    fi
    # Type with optional scope
    if [[ "$line" =~ ^([a-z]+)(\([^)]+\))?: ]]; then
      local type="${BASH_REMATCH[1]}"
      local desc="${line#*: }"
      case "$type" in
        feat)              added+=("$desc") ;;
        fix)               fixed+=("$desc") ;;
        refactor|perf)     changed+=("$desc") ;;
        *)                 : ;;  # skip docs/chore/test/style/build/ci
      esac
    fi
  done

  printf '## [%s] - %s\n' "$version" "$date"

  local printed=0
  if [ "${#added[@]}" -gt 0 ]; then
    printf '\n### Added\n'
    for x in "${added[@]}"; do printf -- '- %s\n' "$x"; done
    printed=1
  fi
  if [ "${#fixed[@]}" -gt 0 ]; then
    printf '\n### Fixed\n'
    for x in "${fixed[@]}"; do printf -- '- %s\n' "$x"; done
    printed=1
  fi
  if [ "${#changed[@]}" -gt 0 ]; then
    printf '\n### Changed\n'
    for x in "${changed[@]}"; do printf -- '- %s\n' "$x"; done
    printed=1
  fi
  if [ "$printed" -eq 0 ]; then
    printf '\n_No notable changes._\n'
  fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash ~/.claude/skills/release-flow/tests/run.sh`
Expected: 31 passed total, 0 failed.

- [ ] **Step 5: Commit**

```bash
cd ~/.claude
git add skills/release-flow/lib/release.sh skills/release-flow/tests/test_changelog.sh
git diff --cached --quiet || git commit -m "feat(release-flow): generate_changelog_entry groups commits per Keep-a-Changelog"
```

---

### Task 7: Orchestration — write the SKILL.md

**Files:**
- Create: `~/.claude/skills/release-flow/SKILL.md`

This task has no automated tests (it's the orchestration markdown). Verification is a manual dry-run in Task 9.

- [ ] **Step 1: Write the SKILL.md**

Write `~/.claude/skills/release-flow/SKILL.md`:

````markdown
---
name: release-flow
description: Use when the user asks to "release", "publish a version", "tag and release", "cut a release", or runs /release. Bumps semver, updates CHANGELOG.md, commits, tags, pushes, and creates a GitHub release. Aborts on dirty tree or non-main branch.
---

# Release Flow

End-to-end release for a single-manifest repository. Reads commits since
the last tag, infers a semver bump per Conventional Commits, generates a
CHANGELOG section, commits everything, tags, pushes, and publishes a
GitHub release marked as `--latest`.

## Preflight (abort on any failure)

Source the helper library and run these checks in the **current working
directory** of the user. Print a single line `release: <reason>` and stop
on any failure.

```bash
LIB="$HOME/.claude/skills/release-flow/lib/release.sh"
. "$LIB"

REPO="$(pwd)"

# 1. Inside a git work tree
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "release: not a git repo"; exit 1; }

# 2. On main or master
BRANCH="$(git -C "$REPO" branch --show-current)"
case "$BRANCH" in
  main|master) ;;
  *) echo "release: must be on main/master, got $BRANCH"; exit 1 ;;
esac

# 3. Clean working tree
if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
  echo "release: working tree not clean"
  git -C "$REPO" status --short
  exit 1
fi

# 4. gh authenticated
gh auth status >/dev/null 2>&1 || { echo "release: gh not authenticated"; exit 1; }

# 5. Manifest detected
MANIFEST="$(detect_manifest "$REPO")" \
  || { echo "release: no version manifest found"; exit 1; }

# 6. CHANGELOG.md exists
[ -f "$REPO/CHANGELOG.md" ] \
  || { echo "release: CHANGELOG.md not found"; exit 1; }

# 7. origin remote
ORIGIN_URL="$(git -C "$REPO" remote get-url origin 2>/dev/null)" \
  || { echo "release: no origin remote"; exit 1; }
OWNER_REPO="$(parse_remote_url "$ORIGIN_URL")" \
  || { echo "release: cannot parse origin URL"; exit 1; }
```

## Gather range and infer bump

```bash
LAST_TAG="$(git -C "$REPO" describe --tags --abbrev=0 2>/dev/null || true)"
if [ -z "$LAST_TAG" ]; then
  RANGE="HEAD"
else
  RANGE="${LAST_TAG}..HEAD"
fi

SUBJECTS="$(git -C "$REPO" log "$RANGE" --format='%s')"
BODIES="$(git -C "$REPO" log "$RANGE" --format='%B')"
if [ -z "$SUBJECTS" ]; then
  echo "release: no commits since ${LAST_TAG:-repo start}"
  exit 1
fi

# Pass both subjects and bodies so BREAKING CHANGE in body is detected.
BUMP="$(printf '%s\n%s\n' "$SUBJECTS" "$BODIES" | infer_bump)"

CURRENT="$(read_version "$REPO/$MANIFEST")"
NEXT="$(next_version "$CURRENT" "$BUMP")"
```

## Show preview and ask the user

Display to the user (this is what Claude says, not what the script prints):

```
Detected manifest: <MANIFEST> (current: <CURRENT>)
Last tag: <LAST_TAG or "none"> (<N> commits since)

Inferred bump: <BUMP> → <NEXT>
<subject list>

Proceed? [y/major/minor/patch/n]
```

Wait for the user's reply. If they answer `major`, `minor`, or `patch`,
recompute `NEXT="$(next_version "$CURRENT" "$BUMP")"` with the chosen
level. If they answer anything other than `y` or one of those three
levels, abort with no side effects.

## Build the CHANGELOG diff

```bash
TODAY="$(date +%Y-%m-%d)"
NEW_SECTION="$(printf '%s\n' "$SUBJECTS" | generate_changelog_entry "$NEXT" "$TODAY")"

# Insert before the first existing `## [` line, or after the intro if none.
TMP="$(mktemp)"
awk -v block="$NEW_SECTION" '
  BEGIN { inserted=0 }
  !inserted && /^## \[/ { print block "\n"; inserted=1 }
  { print }
  END {
    if (!inserted) {
      print ""
      print block
    }
  }
' "$REPO/CHANGELOG.md" > "$TMP"

# Append a compare link at the very bottom.
if [ -n "$LAST_TAG" ]; then
  PREV="${LAST_TAG#v}"
  printf '[%s]: https://github.com/%s/compare/v%s...v%s\n' \
    "$NEXT" "$OWNER_REPO" "$PREV" "$NEXT" >> "$TMP"
else
  printf '[%s]: https://github.com/%s/releases/tag/v%s\n' \
    "$NEXT" "$OWNER_REPO" "$NEXT" >> "$TMP"
fi
```

Show the diff to the user (do not open `$EDITOR`):

```bash
diff -u "$REPO/CHANGELOG.md" "$TMP" || true
```

Prompt: `Confirm release? [y/N]`. On anything other than `y`, delete `$TMP`
and exit with no side effects.

## Execute

```bash
# 1. Bump manifest
write_version "$REPO/$MANIFEST" "$NEXT"

# 2. Apply CHANGELOG
mv "$TMP" "$REPO/CHANGELOG.md"

# 3. Commit
git -C "$REPO" add "$MANIFEST" CHANGELOG.md
git -C "$REPO" commit -m "chore(release): v$NEXT"

# 4. Tag
git -C "$REPO" tag -a "v$NEXT" -m "Release $NEXT"

# 5. Push
git -C "$REPO" push origin "$BRANCH" --follow-tags

# 6. Extract release notes from the new CHANGELOG section
NOTES="$(mktemp)"
awk -v ver="$NEXT" '
  $0 ~ "^## \\[" ver "\\]" { capture=1; next }
  capture && /^## \[/      { capture=0 }
  capture                  { print }
' "$REPO/CHANGELOG.md" > "$NOTES"

# 7. Create GitHub release
gh release create "v$NEXT" --title "v$NEXT" --latest --notes-file "$NOTES" \
  --repo "$OWNER_REPO"

rm -f "$NOTES"

# 8. Print success URL
echo "✓ Released v$NEXT"
echo "  https://github.com/$OWNER_REPO/releases/tag/v$NEXT"
```

## Dry-run mode

If invoked with the `--dry-run` flag, run all of the above through the
"build CHANGELOG diff" step, print the diff, print every command from
the "Execute" section without running them, and exit. Do not modify the
manifest, CHANGELOG, git index, or remote.

## Rollback

If a command in the Execute phase fails:

- **Before push (steps 1–4):** the local commit and tag exist but the
  remote is untouched. Tell the user:
  ```
  release: <step> failed.
  To roll back: git reset --hard HEAD~1 && git tag -d v$NEXT
  ```
- **After push, before release (step 5 succeeded, 7 failed):** the remote
  has the tag. Tell the user:
  ```
  release: gh release create failed.
  Tag is already pushed. Re-run: gh release create v$NEXT --latest --notes-file <path>
  ```
  Do not delete the pushed tag automatically.
````

- [ ] **Step 2: Commit**

```bash
cd ~/.claude
git add skills/release-flow/SKILL.md
git diff --cached --quiet || git commit -m "feat(release-flow): SKILL.md orchestration"
```

---

### Task 8: Slash command wrapper

**Files:**
- Create: `~/.claude/commands/release.md`

- [ ] **Step 1: Write the command file**

Write `~/.claude/commands/release.md`:

```markdown
---
description: Bump version, update CHANGELOG, tag, push, and create a GitHub release in one shot.
---

# /release

Invoke the `release-flow` skill to run the full release pipeline against
the current repository.

Arguments:
- (none) — normal flow with confirmation prompts
- `--dry-run` — show what would happen without executing

Trigger phrases that should also activate this: "cut a release",
"publish a version", "release", "tag and release", "ship it".

## Behavior

Follow the `release-flow` skill exactly. Do not skip the preflight checks
even if the user seems to be in a hurry. The skill aborts cleanly on any
precondition failure — surface its message verbatim.

If the user passes `--dry-run`, run the dry-run path from the skill and
clearly label the output as a dry run so the user does not mistake it
for a real release.
```

- [ ] **Step 2: Commit**

```bash
cd ~/.claude
git add commands/release.md
git diff --cached --quiet || git commit -m "feat(commands): /release wrapper for release-flow skill"
```

---

### Task 9: End-to-end dry-run smoke test on session-tracker

**Files:** none modified — verification only.

- [ ] **Step 1: Restart Claude in `/Users/tupy/plugins/session-tracker`**

The skill and command are user-level, so a Claude restart is required for
them to be discoverable.

- [ ] **Step 2: Make a throwaway commit so there is something to release**

```bash
cd /Users/tupy/plugins/session-tracker
echo "" >> README.md
git add README.md
git commit -m "chore: trigger release flow smoke test"
```

- [ ] **Step 3: Run `/release --dry-run`**

In Claude, invoke `/release --dry-run`. Verify the output contains:
- Detected manifest: `.claude-plugin/plugin.json (current: 2.5.0)`
- Last tag: `v2.5.0 (1 commit since)`
- Inferred bump: `patch → 2.5.1`
- A diff showing a new `## [2.5.1] - <today>` block prepended to CHANGELOG.md
- The list of commands that would execute (commit, tag, push, gh release create)

- [ ] **Step 4: Confirm no side effects**

```bash
cd /Users/tupy/plugins/session-tracker
git status                                # should show only README.md commit
git tag --list 'v2.5.1'                   # should be empty
jq -r .version .claude-plugin/plugin.json # should still be 2.5.0
```

- [ ] **Step 5: Roll back the throwaway commit**

```bash
git reset --hard HEAD~1
```

- [ ] **Step 6: Document the smoke test result**

If the dry run produced the expected output, record it in the plan as a
checkmark and proceed. If it failed, capture the failure and revisit the
relevant task before continuing.

---

## Self-Review Notes

- All spec sections are covered: manifest detection (Task 5), bump
  inference (Task 4), CHANGELOG generation (Task 6), preflight + execute
  + rollback (Task 7), dry-run (Task 7), slash command (Task 8), smoke
  test against this repo (Task 9).
- Pre-release / monorepo / signing are deliberately out of scope per the
  spec's "Open future work" section.
- Type consistency: `parse_remote_url` returns `owner/repo`,
  `detect_manifest` returns a path relative to repo root, `read_version`
  and `next_version` both deal in plain `X.Y.Z` strings. The orchestration
  builds `v$NEXT` everywhere a tag/release is referenced.
- One gap I noticed and fixed inline: the original spec mentioned
  `[Unreleased]` curated mode but the user picked "generate from commits"
  during brainstorming — this plan only implements that path. No
  `[Unreleased]` parsing logic appears anywhere.
