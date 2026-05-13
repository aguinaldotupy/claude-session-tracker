# `/release` — Automated version bump, tag, and GitHub release

**Status:** Design approved
**Date:** 2026-05-13
**Scope:** User-level slash command + supporting skill, reusable across projects

## Goal

A single command that takes a repository from "feature commits merged" to
"published GitHub release" without manual editing of version files, CHANGELOG,
or `gh` invocations. The command infers the semver bump from Conventional
Commit history, generates a CHANGELOG entry, commits, tags, pushes, and creates
the release.

## Non-goals

- Multi-package monorepo coordination (single manifest per repo).
- Non-semver versioning schemes (calver, date-based).
- Pre-release / RC flows (`-rc.1`, `-beta`). Plain `vX.Y.Z` only.
- Cross-platform CI release workflows. This is a local-machine command.

## User-facing contract

### Invocation

```
/release            # normal flow
/release --dry-run  # print every action without executing
```

No bump-type argument: the bump is inferred and confirmed interactively. The
user can override the inferred type at the confirmation prompt.

### Output (happy path)

```
Detected manifest: .claude-plugin/plugin.json (current: 2.5.0)
Last tag: v2.5.0 (3 commits since)

Inferred bump: minor → 2.6.0
  feat: add /release command
  fix: handle missing CHANGELOG
  docs: update README

Proceed? [y/major/minor/patch/n]: y

Changes that will be made:
  • Bump 2.5.0 → 2.6.0 in .claude-plugin/plugin.json
  • Prepend [2.6.0] section to CHANGELOG.md (diff below)
  • git commit -m "chore(release): v2.6.0"
  • git tag -a v2.6.0
  • git push origin main --follow-tags
  • gh release create v2.6.0 --latest --notes-from-tag

--- CHANGELOG.md diff ---
[shown inline, no editor opens]

Confirm release? [y/N]: y

✓ Released v2.6.0
  https://github.com/<owner>/<repo>/releases/tag/v2.6.0
```

## Components

### 1. Slash command — `~/.claude/commands/release.md`

Thin wrapper that invokes the `release-flow` skill. Holds the user-facing
description and trigger phrases. Owns argument parsing (`--dry-run`).

### 2. Skill — `~/.claude/skills/release-flow/SKILL.md`

Where the logic lives. Reusable from any project. Skill description should
trigger on phrases like "create a release", "publish version", "tag and
release".

The skill is **rigid**: it follows the steps below in order, aborts on any
precondition failure, and does not improvise.

## Algorithm

### Phase 1 — Preconditions (abort on any failure)

1. `git rev-parse --is-inside-work-tree` succeeds.
2. Current branch is `main` or `master`. Otherwise abort:
   `release must run on main/master, got: <branch>`.
3. Working tree clean: `git status --porcelain` returns empty. Otherwise
   abort with the list of dirty files.
4. `gh auth status` succeeds.
5. A manifest is detected (see Detection order below). Otherwise abort:
   `no version manifest found`.
6. `CHANGELOG.md` exists at repo root. If not, abort:
   `CHANGELOG.md not found — create one first or run /release --init` (the
   `--init` flag is out of scope for v1; just abort).
7. There is at least one commit since the last tag. If `git log
   $(last_tag)..HEAD --oneline` is empty, abort: `no commits since <tag>`.

### Phase 2 — Detection

**Manifest detection order** (first match wins):
1. `.claude-plugin/plugin.json` → read `.version` via `jq`
2. `package.json` → read `.version` via `jq`
3. `pyproject.toml` → read `[project].version` via `tomlq` or a regex fallback
4. `Cargo.toml` → read `[package].version` via `tomlq` or regex fallback

If multiple are present, use the first match and emit a warning naming the
others.

**Last tag:**
```
last_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
```
If no tag exists, treat all commits as the range and default the bump
inference to `minor` (first non-1.0.0 release).

### Phase 3 — Bump inference

Parse commits in the range `$last_tag..HEAD` with `git log --format=%B`. For
each commit message:

| Pattern                                                | Bump  |
|--------------------------------------------------------|-------|
| Body contains `BREAKING CHANGE:` or subject has `!:`   | major |
| Subject starts with `feat:` or `feat(scope):`          | minor |
| Subject starts with `fix:`/`perf:`/`refactor:`         | patch |
| Subject starts with `docs:`/`chore:`/`test:`/`style:`/`build:`/`ci:` | (no contribution) |

The final bump is the highest level any commit triggered. If only
no-contribution commits exist, fall back to `patch` and warn:
`no feature/fix commits — defaulting to patch`.

### Phase 4 — User confirmation

Show the user:
- Detected manifest and current version
- Last tag and commit count since
- Inferred bump and target version
- List of subjects since last tag

Prompt: `Proceed? [y/major/minor/patch/n]`. The user may force a different
bump by typing the level. `n` aborts cleanly with no side effects.

### Phase 5 — CHANGELOG entry generation

Group commits by type into Keep-a-Changelog sections:

| Conventional type        | CHANGELOG section |
|--------------------------|-------------------|
| `feat`                   | Added             |
| `fix`                    | Fixed             |
| `refactor`, `perf`       | Changed           |
| `BREAKING CHANGE` / `!`  | Changed (prefixed with **Breaking:**) |
| `docs`, `chore`, others  | excluded          |

For each included commit, take the subject line minus the type prefix as the
bullet. Strip trailing issue references if present.

Insert the new section **immediately before** the most recent existing
version section (i.e. before the first `## [X.Y.Z]` line in the file), so the
newest release ends up on top per Keep-a-Changelog convention. If no version
sections exist yet, insert after the intro paragraph that follows the `#
Changelog` H1. Add a comparison link at the bottom of the file:
`[X.Y.Z]: https://github.com/<owner>/<repo>/compare/v<prev>...v<new>`.

Owner/repo derived from `git remote get-url origin` (parsing both
`git@github.com:owner/repo.git` and `https://github.com/owner/repo.git`).

### Phase 6 — Diff preview

Show the CHANGELOG diff inline (using `git diff --no-index` against a temp
file, or constructed manually). No editor opens. Prompt:
`Confirm release? [y/N]`. Anything other than `y` aborts and reverts any
unstaged changes the skill made to the working tree.

### Phase 7 — Execute

In order, stop on first failure:
1. Update manifest (jq + `mv` for JSON; sed for TOML).
2. Write updated CHANGELOG.
3. `git add <manifest> CHANGELOG.md`
4. `git commit -m "chore(release): vX.Y.Z"`
5. `git tag -a vX.Y.Z -m "Release X.Y.Z"`
6. `git push origin <branch> --follow-tags`
7. Extract the new version's section from CHANGELOG (everything between
   `## [X.Y.Z]` and the next `## [` or EOF) into a temp file.
8. `gh release create vX.Y.Z --title "vX.Y.Z" --latest --notes-file <tmp>`

### Phase 8 — Rollback

If any step in Phase 7 fails after the manifest/CHANGELOG were already
committed but before the push succeeded:
- Print the failure and the manual recovery commands (`git reset --hard
  HEAD~1`, `git tag -d vX.Y.Z`).
- Do **not** attempt automatic rollback — leave the working tree intact so
  the user can inspect.

If the failure is after the push but before `gh release create`, instruct
the user to run `gh release create vX.Y.Z --latest --notes-file ...`
manually. Do not undo the push.

## Dry-run mode

`/release --dry-run` runs phases 1–6 exactly as normal, then prints every
command from phase 7 that would execute (without running them) and exits.
No files are modified.

## File touches

The skill writes to:
- `<repo>/<manifest>` — bumped version field only
- `<repo>/CHANGELOG.md` — new section prepended, new compare link appended
- Git: one commit, one tag, one push, one GitHub release

The skill reads from:
- `git log`, `git describe`, `git remote`, `git status`, `git branch`
- The manifest file
- `CHANGELOG.md`

## Error message conventions

All abort paths print a single line beginning with `release: ` and a short
reason, plus (where relevant) a suggested remediation. No multi-line tracebacks.

## Edge cases

- **First release ever (no tags):** treat entire history as range; default to
  `1.0.0` if manifest is at `0.x`, else use inferred bump.
- **Manifest version disagrees with last tag:** warn but proceed using the
  manifest as source of truth.
- **No `origin` remote:** abort — push and `gh` both require it.
- **`gh` not installed:** abort with install hint.
- **`tomlq` not installed (for TOML projects):** fall back to a `grep -E`
  regex that reads `^version *= *"X.Y.Z"$`. Write via sed in place.

## Testing strategy

Manual smoke tests, one per supported manifest type:
1. Plugin (`plugin.json`) — this very repo, after the next feature commit.
2. Node (`package.json`) — scratch repo with one feat commit.
3. Python (`pyproject.toml`) — scratch repo, same.
4. Rust (`Cargo.toml`) — scratch repo, same.

Each test runs `/release --dry-run` first, then the real flow. Verifies:
manifest updated, CHANGELOG entry correct, commit + tag + push + release
all visible.

## Open future work (out of scope for v1)

- `--init` flag to scaffold a CHANGELOG.md.
- Pre-release versions (`-rc.N`).
- Monorepo / multi-manifest support.
- Release notes templates beyond Keep-a-Changelog default.
- Signing tags (`git tag -s`).
