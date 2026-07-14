# Emits SQLite upsert statements for the legacy history.jsonl migration.
# Run with: jq -R -r --argjson now <epoch> -f import-history.jq history.jsonl
#   -R (raw input) + `fromjson?` parses each line and SKIPS malformed ones,
#   so one jq process handles the whole file resiliently — no per-row spawn.
# Legacy defaults: branch := NULL, active := active_seconds // duration_seconds // 0.
# project_root := project_dir, EXCEPT when project_dir is a Claude Code worktree
#   in the default layout (<repo>/.claude/worktrees/<name>): then root collapses
#   to <repo> so all worktrees of a repo group under one project. The exact,
#   Claude-Code-owned `/.claude/worktrees/` marker makes this safe — a custom
#   worktree path won't match and falls back to project_dir. project_dir keeps
#   the full worktree path as session detail.
def esc: gsub("'"; "''");
def num(v): (v // 0) | floor | tostring;
fromjson?
| objects
| select((.session_id // "") != "")
| (.project_dir // "") as $dir
| ($dir | if test("/\\.claude/worktrees/") then sub("/\\.claude/worktrees/.*$"; "") else . end) as $root
| "INSERT INTO projects(project_root,name,first_seen_ts,last_seen_ts) VALUES('\($root|esc)','\(($root|split("/")|last)|esc)',\($now),\($now)) ON CONFLICT(project_root) DO UPDATE SET last_seen_ts=\($now);",
  "INSERT INTO sessions(session_id,project_id,project_dir,branch,issue_key,start_ts,end_ts,duration_seconds,active_seconds,idle_seconds,reason,updated_at) VALUES('\(.session_id|esc)',(SELECT id FROM projects WHERE project_root='\($root|esc)'),'\($dir|esc)',NULL,\(if (.issue_key // "") == "" then "NULL" else "'\(.issue_key|esc)'" end),\(num(.start_ts)),\(num(.end_ts)),\(num(.duration_seconds)),\(num(.active_seconds // .duration_seconds)),\(num(.idle_seconds)),\(if (.reason // "") == "" then "NULL" else "'\(.reason|esc)'" end),\($now)) ON CONFLICT(session_id) DO UPDATE SET end_ts=excluded.end_ts,duration_seconds=excluded.duration_seconds,active_seconds=excluded.active_seconds,idle_seconds=excluded.idle_seconds,reason=excluded.reason,branch=excluded.branch,issue_key=excluded.issue_key,project_id=excluded.project_id,project_dir=excluded.project_dir,updated_at=excluded.updated_at WHERE excluded.end_ts >= sessions.end_ts;"
