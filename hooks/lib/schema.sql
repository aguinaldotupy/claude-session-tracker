PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 2000;

CREATE TABLE IF NOT EXISTS projects (
  id            INTEGER PRIMARY KEY,
  project_root  TEXT NOT NULL UNIQUE,
  name          TEXT NOT NULL,
  first_seen_ts INTEGER NOT NULL,
  last_seen_ts  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  session_id       TEXT PRIMARY KEY,
  project_id       INTEGER REFERENCES projects(id),
  project_dir      TEXT,
  branch           TEXT,
  issue_key        TEXT,
  start_ts         INTEGER NOT NULL,
  end_ts           INTEGER NOT NULL,
  duration_seconds INTEGER NOT NULL,
  active_seconds   INTEGER NOT NULL,
  idle_seconds     INTEGER NOT NULL,
  reason           TEXT,
  updated_at       INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project_id);
CREATE INDEX IF NOT EXISTS idx_sessions_start   ON sessions(start_ts);

CREATE TABLE IF NOT EXISTS events (
  id         INTEGER PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(session_id),
  ts         INTEGER NOT NULL,
  kind       TEXT NOT NULL,
  tool       TEXT
);
CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id, ts);

CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT
);
