---
description: Retroactively tag (or clear) the issue key on an already-ended session inside history.jsonl
disable-model-invocation: true
---

# Tag a Past Session with an Issue Key

Rewrites the `issue_key` field for a single line in `~/.claude/session-env/history.jsonl`. Use this when a session ended on a branch with no detectable issue and got logged as untagged, or when the wrong key was attached.

## Arguments

Parsed from `$ARGUMENTS` (space separated):

1. `<session_id_or_short_prefix>` — full session id, or a unique prefix of at least 6 characters.
2. Either an issue key matching `^[A-Z][A-Z0-9_]+-[0-9]+$` (e.g. `LIN-456`, `ABC-123`, `PROJ_X-42`) **or** the literal `--clear` to blank the field.

Examples:

```
/session-tracker:tag-session abc12345 LIN-456
/session-tracker:tag-session 3f9e8a1c-... ABC-123
/session-tracker:tag-session abc12345 --clear
```

## Behavior

1. Resolve the history file: `HISTORY="$HOME/.claude/session-env/history.jsonl"`. If it is missing or empty, report `No history at $HISTORY — nothing to tag.` and stop.
2. Split `$ARGUMENTS` into `PREFIX` and `KEY_OR_FLAG`. If either is empty, print usage and stop.
3. If `PREFIX` is shorter than 6 characters and not a full session id, refuse: `Prefix too short — give at least 6 characters or the full session_id.`.
4. If `KEY_OR_FLAG` is not `--clear`, validate it against `^[A-Z][A-Z0-9_]+-[0-9]+$`. On mismatch report: `Invalid issue key "<input>". Expected format like LIN-456 or ABC-123.` and stop.
5. Count matches before rewriting:
   ```bash
   MATCHES=$(jq -c --arg sid "$PREFIX" \
     'select(.session_id == $sid or (.session_id | startswith($sid)))' \
     "$HISTORY" | wc -l | tr -d ' ')
   ```
   - `0` → `No session matches "<PREFIX>".` and stop.
   - `>1` → `Prefix "<PREFIX>" matches N sessions; pass a longer prefix or the full id.` and stop.
6. Determine the new value: `NEW_KEY=""` if `--clear`, otherwise `NEW_KEY="$KEY_OR_FLAG"`.
7. Rewrite atomically via a temp file in the same directory, then `mv` (rename is atomic on a single filesystem):

   ```bash
   jq -c --arg sid "$PREFIX" --arg key "$NEW_KEY" \
     'if (.session_id == $sid or (.session_id | startswith($sid))) then .issue_key = $key else . end' \
     "$HISTORY" > "$HISTORY.tmp" && mv "$HISTORY.tmp" "$HISTORY"
   ```

   This preserves every other field and the original line ordering.
8. Show the updated record(s) so the user can verify:
   ```bash
   jq --arg sid "$PREFIX" \
     'select(.session_id == $sid or (.session_id | startswith($sid)))' \
     "$HISTORY"
   ```
9. Report: `Tagged <short_id> as <KEY>.` (or `Cleared issue key on <short_id>.` for `--clear`).

## Concurrency caveat

`history.jsonl` is appended to by the `SessionEnd` hook. The rewrite reads the whole file, then renames a temp file over it. If a session happens to end during that window, that brand-new line will be lost. The race is tiny (sub-second, single user), but **avoid running this command at the exact moment another Claude Code window is shutting down**. There is no file locking — `mv` on the same filesystem is atomic, which is enough for normal use. If you ever suspect a lost line, the session can simply be retagged from the other window or recreated by hand.

## Implementation hint

```bash
HISTORY="$HOME/.claude/session-env/history.jsonl"
[ -s "$HISTORY" ] || { echo "No history at $HISTORY — nothing to tag."; exit 0; }

read -r PREFIX KEY_OR_FLAG _ <<< "${ARGUMENTS:-}"
if [ -z "${PREFIX:-}" ] || [ -z "${KEY_OR_FLAG:-}" ]; then
  echo "Usage: /session-tracker:tag-session <session_id_or_prefix> <ISSUE-KEY|--clear>"
  exit 0
fi
if [ "${#PREFIX}" -lt 6 ]; then
  echo "Prefix too short — give at least 6 characters or the full session_id."
  exit 0
fi

if [ "$KEY_OR_FLAG" = "--clear" ]; then
  NEW_KEY=""
elif [[ "$KEY_OR_FLAG" =~ ^[A-Z][A-Z0-9_]+-[0-9]+$ ]]; then
  NEW_KEY="$KEY_OR_FLAG"
else
  echo "Invalid issue key \"$KEY_OR_FLAG\". Expected format like LIN-456 or ABC-123."
  exit 0
fi

MATCHES=$(jq -c --arg sid "$PREFIX" \
  'select(.session_id == $sid or (.session_id | startswith($sid)))' \
  "$HISTORY" | wc -l | tr -d ' ')
case "$MATCHES" in
  0) echo "No session matches \"$PREFIX\"."; exit 0 ;;
  1) ;;
  *) echo "Prefix \"$PREFIX\" matches $MATCHES sessions; pass a longer prefix or the full id."; exit 0 ;;
esac

jq -c --arg sid "$PREFIX" --arg key "$NEW_KEY" \
  'if (.session_id == $sid or (.session_id | startswith($sid))) then .issue_key = $key else . end' \
  "$HISTORY" > "$HISTORY.tmp" && mv "$HISTORY.tmp" "$HISTORY"

jq --arg sid "$PREFIX" \
  'select(.session_id == $sid or (.session_id | startswith($sid)))' \
  "$HISTORY"

SHORT="${PREFIX:0:8}"
if [ "$KEY_OR_FLAG" = "--clear" ]; then
  echo "Cleared issue key on $SHORT."
else
  echo "Tagged $SHORT as $NEW_KEY."
fi
```

Display the result to the user.
