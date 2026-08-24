#!/usr/bin/env bash
# Shared SQLite helpers for session-tracker. Source this file; functions never block.
# Callers are responsible for their own `|| exit 0` guards.

# Data + config home. Harness-neutral (Claude Code, opencode, anything that can
# run a shell hook): SESSION_TRACKER_HOME wins, else ~/.session-tracker. Resolved
# on every call, never cached, so a caller can scope it with a HOME/env override.
st_home() { printf '%s' "${SESSION_TRACKER_HOME:-$HOME/.session-tracker}"; }

# Where the store lived before v4: a Claude-Code-specific path.
st_legacy_home() { printf '%s' "$HOME/.claude/session-env"; }

# One-time move off the legacy path, then leave a symlink behind: statusline
# snippets users already pasted into settings.json point at the old path, and a
# solidtime-sync.sh running detached from a previous session resolves its own
# paths at runtime. Both keep working through the link. Never fails hard.
st_migrate_home() {
  local new legacy
  new="$(st_home)"; legacy="$(st_legacy_home)"
  if [ "$new" = "$legacy" ]; then return 0; fi
  # Only a real directory migrates: a symlink means we already ran.
  if [ ! -d "$legacy" ] || [ -L "$legacy" ]; then return 0; fi
  # A hook that fired before SessionStart may have already mkdir'd an empty new
  # home; rmdir clears that (and only that) so the move still happens. A new home
  # with real content is never clobbered — leave both and let the user merge.
  if [ -e "$new" ]; then
    [ -d "$new" ] || return 0
    rmdir "$new" 2>/dev/null || return 0
  fi
  mkdir -p "$(dirname "$new")" 2>/dev/null || return 0
  # Re-check right before the move: two sessions can start at once, and if the
  # other one already migrated, `legacy` is now the symlink it left behind --
  # `mv` would drop that symlink *inside* the new home and delete the path every
  # already-pasted statusline snippet still resolves through.
  if [ -L "$legacy" ]; then return 0; fi
  mv "$legacy" "$new" 2>/dev/null || return 0
  ln -s "$new" "$legacy" 2>/dev/null || true
}

st_db_path() { printf '%s/history.db' "$(st_home)"; }

# --- configuration -----------------------------------------------------------
# One file for the whole plugin: <home>/config.yml. Replaces the shell-sourced
# solidtime.conf, which executed whatever it contained and made a Sanctum token
# (`<id>|<random>`) a quoting hazard. Nothing here is evaluated — the parser
# emits NAME=value lines and the loader exports them one by one.
st_config_file() { printf '%s/config.yml' "$(st_home)"; }

# Deliberately a small YAML *subset*, so no yq/python dependency creeps in:
#   key: value                      -> KEY=value
#   section:                        -> opens a section
#     key: value                    -> SECTION_KEY=value
# Comments (#) and blank lines are skipped; one layer of matching outer quotes
# is stripped; `-` in a key becomes `_`. Everything else — lists, nesting past
# one level, anchors, multi-line scalars, inline comments after a value — is not
# supported, and unparseable lines are dropped rather than guessed at.
# A second argument of `sections` restricts the output to section-scoped keys.
st_config_parse() {
  [ -r "${1:-}" ] || return 1
  awk -v sections_only="${2:-}" '
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*#/) next
      if (line ~ /^[[:space:]]*$/) next
      n = match(line, /[^[:space:]]/)
      if (n == 0) next
      indent = n - 1
      rest = substr(line, n)
      if (rest !~ /^[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*:/) next
      ci = index(rest, ":")
      key = substr(rest, 1, ci - 1); sub(/[[:space:]]+$/, "", key)
      val = substr(rest, ci + 1)
      sub(/^[[:space:]]+/, "", val); sub(/[[:space:]]+$/, "", val)
      gsub(/-/, "_", key)
      if (indent == 0) {
        if (val == "") { section = toupper(key); next }
        section = ""
        if (sections_only != "") next
        name = toupper(key)
      } else {
        if (section == "") next
        name = section "_" toupper(key)
      }
      if (length(val) > 1) {
        q = substr(val, 1, 1)
        if ((q == "\"" || q == "\047") && substr(val, length(val), 1) == q)
          val = substr(val, 2, length(val) - 2)
      }
      if (name ~ /^[A-Z_][A-Z0-9_]*$/) print name "=" val
    }
  ' "$1" 2>/dev/null
}

# Export every key in config.yml. Non-zero when the file is absent/unreadable so
# callers can tell "no config" from "config that set nothing".
#
# A key with no value is skipped, never exported as "": the env-var config mode
# (SOLIDTIME_* provisioned by an ephemeral host) is a *fallback* for whatever the
# file does not set, and exporting an empty string would overwrite a working
# credential with nothing -- which is exactly the shape st_migrate_config
# produces for a legacy conf whose token it could not read.
#
# Only section-scoped keys are exported. A bare `path:` or `home:` at the top
# level would otherwise clobber PATH/HOME for whoever loaded the config, and no
# top-level key is read by anything -- so this drops capability nobody asked for
# rather than bolting on a denylist. Readers still see them via st_config_parse.
st_config_load() {
  local f name value
  f="$(st_config_file)"
  [ -r "$f" ] || return 1
  while IFS='=' read -r name value; do
    [ -n "$name" ] || continue
    [ -n "$value" ] || continue
    export "$name=$value"
  done <<CONFIG
$(st_config_parse "$f" sections)
CONFIG
  return 0
}

# Emit a value that reads back identically. Raw is safe for tokens and URLs
# (inline comments are not stripped); quote only what the parser would mangle.
_st_yaml_val() {
  case "${1:-}" in
    '')            printf '' ;;
    [\'\"]*|*' ')  printf "'%s'" "$1" ;;
    *)             printf '%s' "$1" ;;
  esac
}

# st_config_set <section> <key> <value> -- rewrite exactly one key, in place,
# leaving every other line (and every other section) byte-identical. The setup
# command uses this instead of regenerating the file: config.yml is the whole
# plugin's config now, so a wholesale overwrite would drop whatever else lives
# in it. Creates the file, and the section, when missing.
st_config_set() {
  local section="${1:-}" key="${2:-}" value="${3:-}" f tmp
  [ -n "$section" ] && [ -n "$key" ] || return 1
  f="$(st_config_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  if [ ! -f "$f" ]; then ( umask 077; : > "$f" ) 2>/dev/null || return 1; fi
  tmp="$f.tmp.$$"
  # The value travels in the environment, not through `-v`: awk expands escape
  # sequences in a -v assignment, so a token containing a backslash would be
  # written back mangled.
  ST_CFG_VAL="$(_st_yaml_val "$value")" \
  awk -v sec="$section" -v key="$key" '
    BEGIN { val = ENVIRON["ST_CFG_VAL"] }
    function emit(k, v) { if (v == "") print "  " k ":"; else print "  " k ": " v }
    BEGIN { cur = ""; done = 0; seen = 0 }
    {
      line = $0; sub(/\r$/, "", line)
      if (line ~ /^[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*:/) {
        # a new top-level key ends the section we were meant to write into
        if (cur == sec && !done) { emit(key, val); done = 1 }
        ci = index(line, ":")
        name = substr(line, 1, ci - 1); sub(/[[:space:]]+$/, "", name)
        rest = substr(line, ci + 1)
        sub(/^[[:space:]]+/, "", rest); sub(/[[:space:]]+$/, "", rest)
        if (rest == "") { cur = name; if (name == sec) seen = 1 } else cur = ""
        print line; next
      }
      if (cur == sec && line ~ /^[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*:/) {
        ci = index(line, ":")
        k = substr(line, 1, ci - 1)
        sub(/^[[:space:]]+/, "", k); sub(/[[:space:]]+$/, "", k)
        if (k == key) { if (!done) { emit(key, val); done = 1 } next }
      }
      print line
    }
    END { if (!done) { if (!seen) print sec ":"; emit(key, val) } }
  ' "$f" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# One indented `key: value` line, or a bare `key:` when the value is empty --
# a trailing space is invisible and the first editor to strip whitespace would
# rewrite the file for no reason.
_st_yaml_line() {
  if [ -z "${2:-}" ]; then printf '  %s:\n' "$1"; else printf '  %s: %s\n' "$1" "$(_st_yaml_val "$2")"; fi
}

# One-time conversion of the legacy solidtime.conf. The old file is *sourced*
# to read it — exactly what the old client did, so a conf that built one value
# from another converts to what it actually evaluated to — then archived as
# .migrated rather than deleted.
st_migrate_config() {
  local new legacy vals url token org member
  new="$(st_config_file)"
  legacy="$(st_home)/solidtime.conf"
  if [ -f "$new" ]; then return 0; fi
  if [ ! -f "$legacy" ] || [ ! -r "$legacy" ]; then return 0; fi
  vals="$(
    set +u
    . "$legacy" >/dev/null 2>&1 || exit 1
    printf '%s\n%s\n%s\n%s\n' "${SOLIDTIME_URL:-}" "${SOLIDTIME_TOKEN:-}" \
                              "${SOLIDTIME_ORG_ID:-}" "${SOLIDTIME_MEMBER_ID:-}"
  )" || return 0
  url="$(printf '%s' "$vals" | sed -n 1p)"
  token="$(printf '%s' "$vals" | sed -n 2p)"
  org="$(printf '%s' "$vals" | sed -n 3p)"
  member="$(printf '%s' "$vals" | sed -n 4p)"
  [ -n "$url$token$org" ] || return 0
  (
    umask 077
    {
      printf '# session-tracker configuration\n'
      printf '# Converted from solidtime.conf; the original is kept beside this file.\n\n'
      printf 'solidtime:\n'
      [ -n "$url" ]    && _st_yaml_line url    "$url"
      [ -n "$token" ]  && _st_yaml_line token  "$token"
      [ -n "$org" ]    && _st_yaml_line org_id "$org"
      [ -n "$member" ] && _st_yaml_line member_id "$member"
      true
    } > "$new"
  ) 2>/dev/null || return 0
  chmod 600 "$new" 2>/dev/null || true
  # Archive the original only once all three required values actually came
  # through. Sourcing is best-effort by nature -- an unquoted Sanctum token
  # (`SOLIDTIME_TOKEN=1|abc` is a pipeline, so the assignment never sticks)
  # reads back empty -- and renaming it away would leave the only copy of that
  # credential under a name nothing looks at.
  if [ -n "$url" ] && [ -n "$token" ] && [ -n "$org" ]; then
    mv "$legacy" "$legacy.migrated" 2>/dev/null || true
  fi
}


st_has_sqlite() { command -v sqlite3 >/dev/null 2>&1; }

# Double single quotes so a value is safe inside a single-quoted SQL literal.
st_sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# Create the DB and apply the (idempotent) schema. Returns non-zero if sqlite3
# or the schema file is missing.
st_db_init() {
  st_has_sqlite || return 1
  local db dir schema
  db="$(st_db_path)"; dir="$(dirname "$db")"
  schema="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/schema.sql"
  [ -f "$schema" ] || return 1
  mkdir -p "$dir"
  sqlite3 "$db" < "$schema" >/dev/null 2>&1
}

# Canonical project root for a cwd, immune to the worktree path config:
# dirname(git-common-dir). Falls back to the cwd for non-git directories.
st_project_root() {
  local cwd="$1" common
  command -v git >/dev/null 2>&1 || { printf '%s' "$cwd"; return; }
  common="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || common="$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)"
  case "$common" in
    '') printf '%s' "$cwd" ;;
    /*) (cd "$(dirname "$common")" 2>/dev/null && pwd) || printf '%s' "$cwd" ;;
    *)  (cd "$cwd/$(dirname "$common")" 2>/dev/null && pwd) || printf '%s' "$cwd" ;;
  esac
}

# st_upsert_session sid root dir branch issue start end dur active idle reason now
# Upserts projects (by project_root) and sessions (by session_id, max-end_ts wins).
st_upsert_session() {
  st_has_sqlite || return 1
  local sid="$1" root="$2" dir="$3" branch="$4" issue="$5"
  local start="$(( 10#${6:-0} ))" end="$(( 10#${7:-0} ))" dur="$(( 10#${8:-0} ))"
  local active="$(( 10#${9:-0} ))" idle="$(( 10#${10:-0} ))" reason="${11}" now="$(( 10#${12:-0} ))"
  local name; name="$(basename "$root")"
  local e_sid e_root e_dir e_name e_reason
  e_sid="$(st_sql_escape "$sid")";     e_root="$(st_sql_escape "$root")"
  e_dir="$(st_sql_escape "$dir")";     e_name="$(st_sql_escape "$name")"
  e_reason="$(st_sql_escape "$reason")"
  # branch / issue_key: emit SQL NULL when empty, else an escaped quoted literal
  local branch_sql issue_sql
  if [ -n "$branch" ]; then branch_sql="'$(st_sql_escape "$branch")'"; else branch_sql="NULL"; fi
  if [ -n "$issue" ];  then issue_sql="'$(st_sql_escape "$issue")'";  else issue_sql="NULL";  fi
  # Same rule for the project: an unknown one is NULL, never a projects row keyed
  # on the empty string and named "". reap-sessions.sh reaches this whenever it
  # finalizes a session with no persisted cwd (every session dir predating the
  # cwd file), and one junk row would collect all of them under a blank name.
  local proj_insert="" proj_id_sql="NULL"
  if [ -n "$root" ]; then
    proj_insert="INSERT INTO projects(project_root,name,first_seen_ts,last_seen_ts)
  VALUES('$e_root','$e_name',$now,$now)
  ON CONFLICT(project_root) DO UPDATE SET last_seen_ts=$now;"
    proj_id_sql="(SELECT id FROM projects WHERE project_root='$e_root')"
  fi
  sqlite3 "$(st_db_path)" <<SQL 2>/dev/null
BEGIN;
$proj_insert
INSERT INTO sessions(session_id,project_id,project_dir,branch,issue_key,
                     start_ts,end_ts,duration_seconds,active_seconds,idle_seconds,reason,updated_at)
  VALUES('$e_sid',$proj_id_sql,'$e_dir',$branch_sql,$issue_sql,
         $start,$end,$dur,$active,$idle,'$e_reason',$now)
  ON CONFLICT(session_id) DO UPDATE SET
    end_ts=excluded.end_ts, duration_seconds=excluded.duration_seconds,
    active_seconds=excluded.active_seconds, idle_seconds=excluded.idle_seconds,
    reason=excluded.reason, branch=excluded.branch, issue_key=excluded.issue_key,
    project_id=excluded.project_id, project_dir=excluded.project_dir, updated_at=excluded.updated_at
  WHERE excluded.end_ts >= sessions.end_ts;
COMMIT;
SQL
}

# st_backfill_worktrees — one-time cleanup for DBs migrated before worktree
# collapsing existed: regroup already-imported sessions whose project_dir is a
# default-layout Claude Code worktree (<repo>/.claude/worktrees/<name>) under the
# canonical repo root, then drop the orphaned per-worktree project rows. Idempotent
# and guarded by a meta flag so it runs at most once. Only the exact, Claude-Code-
# owned `/.claude/worktrees/` marker triggers it — custom worktree paths are left
# untouched, matching the migration's own heuristic.
st_backfill_worktrees() {
  st_has_sqlite || return 1
  local db; db="$(st_db_path)"
  [ -f "$db" ] || return 0
  [ -n "$(sqlite3 "$db" "SELECT value FROM meta WHERE key='worktrees_backfilled';" 2>/dev/null)" ] && return 0
  local now; now="$(date +%s)"
  # Distinct collapsed repo roots among worktree sessions (basename computed in
  # bash — SQLite has no basename()).
  local roots; roots="$(sqlite3 "$db" "SELECT DISTINCT substr(project_dir,1,instr(project_dir,'/.claude/worktrees/')-1) FROM sessions WHERE project_dir LIKE '%/.claude/worktrees/%';" 2>/dev/null)"
  {
    printf 'BEGIN;\n'
    local root name e_root e_name
    while IFS= read -r root; do
      [ -z "$root" ] && continue
      name="${root##*/}"
      e_root="$(st_sql_escape "$root")"; e_name="$(st_sql_escape "$name")"
      printf "INSERT INTO projects(project_root,name,first_seen_ts,last_seen_ts) VALUES('%s','%s',%s,%s) ON CONFLICT(project_root) DO UPDATE SET last_seen_ts=%s;\n" "$e_root" "$e_name" "$now" "$now" "$now"
    done <<EOF
$roots
EOF
    # Re-link every default-layout worktree session to its collapsed repo root.
    printf "UPDATE sessions SET project_id=(SELECT id FROM projects WHERE project_root=substr(project_dir,1,instr(project_dir,'/.claude/worktrees/')-1)) WHERE project_dir LIKE '%%/.claude/worktrees/%%';\n"
    # Drop project rows left with no sessions (the old per-worktree hash names).
    printf "DELETE FROM projects WHERE id NOT IN (SELECT project_id FROM sessions WHERE project_id IS NOT NULL);\n"
    printf "INSERT INTO meta(key,value) VALUES('worktrees_backfilled','%s') ON CONFLICT(key) DO UPDATE SET value='%s';\n" "$now" "$now"
    printf 'COMMIT;\n'
  } | sqlite3 "$db" 2>/dev/null
}
