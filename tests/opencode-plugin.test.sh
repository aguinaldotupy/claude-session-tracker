#!/usr/bin/env bash
# The opencode plugin shim: opencode's JS hooks -> the same shell hooks Claude
# Code drives. Skipped when no JS runtime is present.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$DIR/.."

RUNTIME=""
for r in bun node; do command -v "$r" >/dev/null 2>&1 && { RUNTIME="$r"; break; }; done
[ -n "$RUNTIME" ] || { echo "no bun/node — skipping"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
unset SESSION_TRACKER_HOME
PROJ="$TMP/proj"; mkdir -p "$PROJ"
SE="$TMP/.session-tracker"
SID="oc-session-1"

cat > "$TMP/drive.mjs" <<'JS'
const { SessionTracker } = await import(process.env.PLUGIN)
const hooks = await SessionTracker({ directory: process.env.PROJ, worktree: process.env.PROJ })
const sessionID = process.env.SID

await hooks["chat.message"]({ sessionID })
await hooks["tool.execute.before"]({ tool: "Read", sessionID, callID: "c1" })
await hooks["tool.execute.after"]({ tool: "Read", sessionID, callID: "c1", args: {} })
await hooks.event({ event: { type: "session.idle", properties: { sessionID } } })

const out = { env: {} }
await hooks["shell.env"]({ cwd: process.env.PROJ, sessionID }, out)
console.log(JSON.stringify(out.env))

await hooks.dispose()
JS

envjson="$(PLUGIN="$ROOT/opencode/plugin.js" PROJ="$PROJ" SID="$SID" "$RUNTIME" "$TMP/drive.mjs" 2>/dev/null)"

# --- the shell side saw a normal session ---
assert_eq "start timestamp written" "yes" \
  "$([ -s "$SE/$SID/session-tracker" ] && echo yes || echo no)"
assert_eq "cwd persisted for the sweeper" "$PROJ" "$(cat "$SE/$SID/cwd" 2>/dev/null)"
assert_eq "events recorded in order" "P T D S" \
  "$(awk '{printf "%s%s", sep, $1; sep=" "} END{print ""}' "$SE/$SID/events.log" 2>/dev/null)"
assert_eq "tool name carried through" "Read Read" \
  "$(awk '$1=="T"||$1=="D"{printf "%s%s", sep, $3; sep=" "} END{print ""}' "$SE/$SID/events.log" 2>/dev/null)"

# --- shell.env hands the session id to bash tool calls, so the skills work ---
assert_eq "shell.env exports the session id" "$SID" \
  "$(printf '%s' "$envjson" | jq -r '.CLAUDE_SESSION_ID // empty')"
assert_eq "shell.env exports a harness-neutral alias" "$SID" \
  "$(printf '%s' "$envjson" | jq -r '.SESSION_TRACKER_SESSION_ID // empty')"

# --- dispose is opencode's SessionEnd: the session reaches the store ---
if command -v sqlite3 >/dev/null 2>&1; then
  assert_eq "dispose records the session" "1" \
    "$(sqlite3 "$SE/history.db" "SELECT COUNT(*) FROM sessions WHERE session_id='$SID';" 2>/dev/null)"
  assert_eq "project resolved from the plugin's directory" "proj" \
    "$(sqlite3 "$SE/history.db" "SELECT p.name FROM sessions s JOIN projects p ON p.id=s.project_id WHERE s.session_id='$SID';" 2>/dev/null)"
fi

# --- session-query resolves the id from the neutral variable too ---
assert_eq "session-query honours SESSION_TRACKER_SESSION_ID" "$SID" \
  "$(SESSION_TRACKER_SESSION_ID="$SID" CLAUDE_SESSION_ID="" bash "$ROOT/hooks/lib/session-query.sh" status \
     | jq -r 'if .live.started_at > 0 then "'"$SID"'" else "unresolved" end')"

# --- a session opened in another project is attributed to THAT project ---
# One opencode process serves many sessions, and `session.created` carries the
# session's own directory. Without it every session lands under whatever
# directory the process was started in.
OTHER="$TMP/other-project"; mkdir -p "$OTHER"
cat > "$TMP/multi.mjs" <<'JS'
const { SessionTracker } = await import(process.env.PLUGIN)
const hooks = await SessionTracker({ directory: process.env.PROJ, worktree: process.env.PROJ })
await hooks.event({ event: { type: "session.created",
  properties: { info: { id: "oc-other", directory: process.env.OTHER } } } })
await hooks["chat.message"]({ sessionID: "oc-other" })
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "oc-other" } } })
await hooks.dispose()
JS
PLUGIN="$ROOT/opencode/plugin.js" PROJ="$PROJ" OTHER="$OTHER" "$RUNTIME" "$TMP/multi.mjs" 2>/dev/null

assert_eq "session.created cwd wins over the process directory" "$OTHER" \
  "$(cat "$SE/oc-other/cwd" 2>/dev/null)"
if command -v sqlite3 >/dev/null 2>&1; then
  assert_eq "session grouped under its own project" "other-project" \
    "$(sqlite3 "$SE/history.db" "SELECT p.name FROM sessions s JOIN projects p ON p.id=s.project_id WHERE s.session_id='oc-other';" 2>/dev/null)"
fi

# --- session id is read defensively: opencode spells it several ways ---
cat > "$TMP/shapes.mjs" <<'JS'
const { SessionTracker } = await import(process.env.PLUGIN)
const hooks = await SessionTracker({ directory: process.env.PROJ, worktree: process.env.PROJ })
await hooks["tool.execute.before"]({ tool: "Grep", info: { id: "oc-nested" } })
await hooks.dispose()
JS
PLUGIN="$ROOT/opencode/plugin.js" PROJ="$PROJ" "$RUNTIME" "$TMP/shapes.mjs" 2>/dev/null
assert_eq "session id found under info.id" "T" \
  "$(awk 'NR==1{print $1}' "$SE/oc-nested/events.log" 2>/dev/null)"

# --- an error can be the first thing ever seen for a session.
#     Without initialising it, the SF lands in a directory with no start
#     timestamp: dispose never sees the id, and the sweeper skips it for lack of
#     a session-tracker file. The session would vanish silently. ---
cat > "$TMP/errfirst.mjs" <<'JS'
const { SessionTracker } = await import(process.env.PLUGIN)
const hooks = await SessionTracker({ directory: process.env.PROJ, worktree: process.env.PROJ })
await hooks.event({ event: { type: "session.error", properties: { sessionID: "oc-err" } } })
await hooks.dispose()
JS
PLUGIN="$ROOT/opencode/plugin.js" PROJ="$PROJ" SID="$SID" "$RUNTIME" "$TMP/errfirst.mjs" 2>/dev/null
assert_eq "error-first session gets a start timestamp" "yes" \
  "$([ -s "$SE/oc-err/session-tracker" ] && echo yes || echo no)"
assert_eq "error-first session records SF" "SF" \
  "$(awk '$1=="SF"{print $1; exit}' "$SE/oc-err/events.log" 2>/dev/null)"
if command -v sqlite3 >/dev/null 2>&1; then
  assert_eq "error-first session is closed by dispose" "1" \
    "$(sqlite3 "$SE/history.db" "SELECT COUNT(*) FROM sessions WHERE session_id='oc-err';" 2>/dev/null)"
fi

# --- a missing plugin root must disable the shim, never throw ---
cat > "$TMP/norooot.mjs" <<'JS'
const { SessionTracker } = await import(process.env.PLUGIN)
const hooks = await SessionTracker({ directory: "/nowhere", worktree: "/nowhere" })
console.log(typeof hooks === "object" ? "ok" : "bad")
JS
mkdir -p "$TMP/isolated"
cp "$ROOT/opencode/plugin.js" "$TMP/isolated/plugin.js"
assert_eq "unresolvable root degrades quietly" "ok" \
  "$(PLUGIN="$TMP/isolated/plugin.js" "$RUNTIME" "$TMP/norooot.mjs" 2>/dev/null)"
assert_eq "unresolvable root registers no hooks" "0" \
  "$(PLUGIN="$TMP/isolated/plugin.js" "$RUNTIME" -e '
      const m = await import(process.env.PLUGIN)
      console.log(Object.keys(await m.SessionTracker({})).length)' 2>/dev/null)"

finish
