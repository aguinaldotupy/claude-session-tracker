---
description: Tag the current session with an issue key (e.g. LIN-456) so the worklog groups time against the right ticket
disable-model-invocation: true
---

# Tag Session with Issue Key

Associates the currently running session with an issue key (Linear, Jira, etc.). The `SessionEnd` hook will write that key into the history log, and `/session-tracker:worklog` will group time by issue.

## Arguments

Parsed from `$ARGUMENTS`:

- A single issue key like `LIN-456`, `ABC-123`, `PROJ_X-42`. Must match `^[A-Z][A-Z0-9_]+-[0-9]+$`.
- Or `--clear` to remove the tag (the branch heuristic takes over again).

## Behavior

1. If `$CLAUDE_SESSION_FILE` is unset or its file does not exist, report that the session-tracker hook is not active and stop.
2. Compute the tag path: `"$(dirname "$CLAUDE_SESSION_FILE")/issue-tag"`.
3. If `$ARGUMENTS` equals `--clear`:
   - Delete the tag file if present.
   - Report: `Tag cleared — branch heuristic will be used on session end.`
4. Otherwise validate `$ARGUMENTS` against `^[A-Z][A-Z0-9_]+-[0-9]+$`:
   - On mismatch, report: `Invalid issue key "<input>". Expected format like LIN-456 or ABC-123.` and ask the user to retry.
   - On match, write the key (no trailing newline matter — a single line is fine) to the tag path and report: `Tagged current session as <KEY>.`
5. Remind the user the tag only affects the *current* session — run `/session-tracker:tag` again in a new session to re-tag.

## Implementation hint

```bash
if [ -z "${CLAUDE_SESSION_FILE:-}" ] || [ ! -f "$CLAUDE_SESSION_FILE" ]; then
  echo "Session file not found - session-tracker hook may not be active"
  exit 0
fi
TAG_FILE="$(dirname "$CLAUDE_SESSION_FILE")/issue-tag"
ARG="${ARGUMENTS:-}"
if [ "$ARG" = "--clear" ]; then
  rm -f "$TAG_FILE"
  echo "Tag cleared - branch heuristic will be used on session end."
elif [[ "$ARG" =~ ^[A-Z][A-Z0-9_]+-[0-9]+$ ]]; then
  printf '%s\n' "$ARG" > "$TAG_FILE"
  echo "Tagged current session as $ARG."
else
  echo "Invalid issue key \"$ARG\". Expected format like LIN-456 or ABC-123."
fi
```

Display the result to the user.
