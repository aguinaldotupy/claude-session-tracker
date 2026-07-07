#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
. "$DIR/../hooks/lib/db.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"

# escape doubles single quotes
assert_eq "escape doubles quotes" "O''Brien" "$(st_sql_escape "O'Brien")"

# db_init creates the three core tables + meta, idempotently
st_db_init
tables=$(sqlite3 "$(st_db_path)" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" | tr '\n' ',')
assert_eq "tables created" "events,meta,projects,sessions," "$tables"

# running init again does not error and keeps the tables
st_db_init; rc=$?
assert_eq "init idempotent" "0" "$rc"

finish
