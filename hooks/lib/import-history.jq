# Emits SQLite upsert statements for the legacy history.jsonl migration.
# Run with: jq -R -r --argjson now <epoch> -f import-history.jq history.jsonl
#   -R (raw input) + `fromjson?` parses each line and SKIPS malformed ones,
#   so one jq process handles the whole file resiliently — no per-row spawn.
# Legacy defaults: project_root := project_dir, branch := NULL,
#   active := active_seconds // duration_seconds // 0.
def esc: gsub("'"; "''");
def num(v): (v // 0) | floor | tostring;
fromjson?
| objects
| select((.session_id // "") != "")
| (.project_dir // "") as $root
| "INSERT INTO projects(project_root,name,first_seen_ts,last_seen_ts) VALUES('\($root|esc)','\(($root|split("/")|last)|esc)',\($now),\($now)) ON CONFLICT(project_root) DO UPDATE SET last_seen_ts=\($now);",
  "INSERT INTO sessions(session_id,project_id,project_dir,branch,issue_key,start_ts,end_ts,duration_seconds,active_seconds,idle_seconds,reason,updated_at) VALUES('\(.session_id|esc)',(SELECT id FROM projects WHERE project_root='\($root|esc)'),'\($root|esc)',NULL,\(if (.issue_key // "") == "" then "NULL" else "'\(.issue_key|esc)'" end),\(num(.start_ts)),\(num(.end_ts)),\(num(.duration_seconds)),\(num(.active_seconds // .duration_seconds)),\(num(.idle_seconds)),\(if (.reason // "") == "" then "NULL" else "'\(.reason|esc)'" end),\($now)) ON CONFLICT(session_id) DO UPDATE SET end_ts=excluded.end_ts,duration_seconds=excluded.duration_seconds,active_seconds=excluded.active_seconds,idle_seconds=excluded.idle_seconds,reason=excluded.reason,branch=excluded.branch,issue_key=excluded.issue_key,project_id=excluded.project_id,project_dir=excluded.project_dir,updated_at=excluded.updated_at WHERE excluded.end_ts >= sessions.end_ts;"
