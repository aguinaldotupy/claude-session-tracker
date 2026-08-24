/**
 * session-tracker — opencode plugin.
 *
 * opencode has no shell-hook system and no session-end event, so this file is a
 * thin adapter: it maps opencode's JS hooks onto the exact same shell hooks
 * Claude Code drives, writing to the exact same store. Nothing about the
 * accounting, the storage, or the Solidtime sync is duplicated here — one
 * history, one worklog, one sync, whichever harness you happen to be in.
 *
 * Mapping:
 *   session.created      -> session-start.sh        (records the session's own cwd)
 *   chat.message         -> user-prompt-submit.sh   (P)
 *   tool.execute.before  -> pre-tool-use.sh         (T <tool>)
 *   tool.execute.after   -> post-tool-use.sh        (D <tool>)
 *   session.idle         -> stop.sh                 (S)
 *   session.error        -> stop-failure.sh         (SF)
 *   dispose              -> session-end.sh          (the store write)
 *   shell.env            -> exports the session id into bash tool calls, which
 *                           is how the skills locate the live session
 *
 * A hard kill skips dispose; reap-sessions.sh closes those sessions from their
 * own events.log on the next start, so nothing is lost either way.
 */
import { spawn } from "node:child_process"
import { existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

/** The plugin checkout that owns hooks/. This file lives in <root>/opencode/. */
function resolveRoot() {
  const candidates = []
  try {
    candidates.push(join(dirname(fileURLToPath(import.meta.url)), ".."))
  } catch {
    /* no import.meta.url (bundled) — fall through to the env var */
  }
  if (process.env.SESSION_TRACKER_PLUGIN_ROOT) candidates.push(process.env.SESSION_TRACKER_PLUGIN_ROOT)
  for (const c of candidates) {
    try {
      if (existsSync(join(c, "hooks", "session-start.sh"))) return c
    } catch {
      /* unreadable candidate — try the next */
    }
  }
  return null
}

/**
 * Run one hook with its JSON payload on stdin. Never rejects and never throws:
 * a tracker that breaks the editor is worse than a tracker that loses a tick.
 */
function runHook(root, script, payload) {
  return new Promise((resolve) => {
    let settled = false
    const done = () => {
      if (!settled) {
        settled = true
        resolve()
      }
    }
    try {
      const child = spawn("bash", [join(root, "hooks", script)], {
        stdio: ["pipe", "ignore", "ignore"],
      })
      child.on("error", done)
      child.on("close", done)
      child.stdin.on("error", done)
      child.stdin.end(JSON.stringify(payload))
    } catch {
      done()
    }
  })
}

/**
 * opencode spells the session id differently across hooks and events, and the
 * shape has moved before. Read it defensively rather than trusting one spot.
 */
function sessionIdOf(input) {
  if (!input) return undefined
  return input.sessionID || input.sessionId || input.session_id || (input.info && input.info.id) || undefined
}

export const SessionTracker = async ({ directory, worktree } = {}) => {
  const root = resolveRoot()
  if (!root) return {}

  const fallbackCwd = worktree || directory || process.cwd()
  const started = new Set()
  // One opencode process serves many sessions, and they need not share a
  // directory. `session.created` carries the session's own, which is what the
  // store groups by; without it every session would be filed under whatever
  // directory the process happened to start in.
  const sessionCwds = new Map()
  const cwdFor = (sessionID) => (sessionID && sessionCwds.get(sessionID)) || fallbackCwd

  // events.log has to stay time-ordered for active-time.awk, so the hooks run
  // one at a time. The chain is awaited only where losing a tick would cost a
  // whole bracket (idle, error, shutdown); the per-tool hooks fire and forget,
  // because ~20ms on every single tool call is a tax the editor should not pay.
  let chain = Promise.resolve()
  const enqueue = (script, payload) => {
    chain = chain.then(() => runHook(root, script, payload)).catch(() => {})
    return chain
  }

  // Claude Code has a SessionStart event; opencode does not, so the first time
  // a session id shows up it is initialised on the spot. `resume` is the right
  // source for that: session-start.sh writes the timestamp when none exists yet
  // and otherwise leaves the window alone, so re-attaching to a session already
  // in flight never truncates the events it has accumulated.
  const ensure = (sessionID) => {
    if (!sessionID || started.has(sessionID)) return
    started.add(sessionID)
    enqueue("session-start.sh", { session_id: sessionID, source: "resume", cwd: cwdFor(sessionID) })
  }

  return {
    "chat.message": async (input) => {
      const sessionID = sessionIdOf(input)
      ensure(sessionID)
      if (sessionID) enqueue("user-prompt-submit.sh", { session_id: sessionID })
    },

    "tool.execute.before": async (input) => {
      const sessionID = sessionIdOf(input)
      ensure(sessionID)
      if (sessionID) enqueue("pre-tool-use.sh", { session_id: sessionID, tool_name: input && input.tool })
    },

    "tool.execute.after": async (input) => {
      const sessionID = sessionIdOf(input)
      ensure(sessionID)
      if (sessionID) enqueue("post-tool-use.sh", { session_id: sessionID, tool_name: input && input.tool })
    },

    // The skills and the statusline locate the live session through the
    // environment. Claude Code sets CLAUDE_SESSION_ID; opencode sets nothing,
    // so the plugin does it here and every prompt file keeps working unchanged.
    "shell.env": async (input, output) => {
      const sessionID = sessionIdOf(input)
      if (!sessionID || !output || !output.env) return
      output.env.SESSION_TRACKER_SESSION_ID = sessionID
      output.env.CLAUDE_SESSION_ID = sessionID
    },

    event: async (input) => {
      const event = input && input.event
      const type = event && event.type
      const props = (event && event.properties) || {}
      const sessionID = sessionIdOf(props) || sessionIdOf(props.info)
      if (!sessionID) return
      if (type === "session.created") {
        // Seed the directory before the session is initialised, so the very
        // first hook already writes the right project.
        const dir = (props.info && props.info.directory) || undefined
        if (dir) sessionCwds.set(sessionID, dir)
        ensure(sessionID)
      } else if (type === "session.idle") {
        ensure(sessionID)
        await enqueue("stop.sh", { session_id: sessionID })
      } else if (type === "session.error") {
        await enqueue("stop-failure.sh", { session_id: sessionID })
      }
    },

    // opencode's closest thing to SessionEnd. Awaited: this is the write that
    // puts the session in the store and hands it to the Solidtime sync.
    dispose: async () => {
      await chain.catch(() => {})
      for (const sessionID of started) {
        await enqueue("session-end.sh", { session_id: sessionID, reason: "exit", cwd: cwdFor(sessionID) })
      }
    },
  }
}

export default SessionTracker
