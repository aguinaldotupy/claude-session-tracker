#!/usr/bin/env bash
# config.yml parsing + the one-time conversion from the legacy solidtime.conf.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$DIR/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
unset SESSION_TRACKER_HOME
. "$ROOT/hooks/lib/db.sh"

CONF="$TMP/.session-tracker/config.yml"
mkdir -p "$TMP/.session-tracker"

assert_eq "config file sits in the store home" "$CONF" "$(st_config_file)"

cat > "$CONF" <<'YAML'
# session-tracker configuration

solidtime:
  url: https://time.example.com
  token: '1|abc#def'
  org_id: "org-1"
  member_id:

log_level: debug
YAML

parsed="$(st_config_parse "$CONF")"
get() { printf '%s\n' "$parsed" | awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}'; }

assert_eq "section key maps to SECTION_KEY" "https://time.example.com" "$(get SOLIDTIME_URL)"
assert_eq "single quotes stripped, payload untouched" '1|abc#def' "$(get SOLIDTIME_TOKEN)"
assert_eq "double quotes stripped" "org-1" "$(get SOLIDTIME_ORG_ID)"
assert_eq "empty value stays empty" "" "$(get SOLIDTIME_MEMBER_ID)"
assert_eq "top-level scalar maps to KEY" "debug" "$(get LOG_LEVEL)"
assert_eq "comments and blanks produce no entries" "5" "$(printf '%s\n' "$parsed" | grep -c .)"

# --- junk is dropped, never executed ---
cat > "$CONF" <<'YAML'
solidtime:
  url: https://ok.test
  $(touch /tmp/st-pwned): boom
  - not a mapping
nonsense without a colon
YAML
parsed="$(st_config_parse "$CONF")"
assert_eq "only the well-formed key survives" "SOLIDTIME_URL=https://ok.test" "$parsed"
assert_eq "nothing was executed" "no" "$([ -e /tmp/st-pwned ] && echo yes || echo no)"

# --- st_config_load exports into the environment ---
cat > "$CONF" <<'YAML'
solidtime:
  url: https://loaded.test
  token: tok-9
YAML
out="$(st_config_load >/dev/null 2>&1; printf '%s|%s' "${SOLIDTIME_URL:-}" "${SOLIDTIME_TOKEN:-}")"
assert_eq "load exports the values" "https://loaded.test|tok-9" "$out"

# --- one-time conversion from the legacy solidtime.conf ---
H2="$TMP/h2"; SE2="$H2/.session-tracker"; mkdir -p "$SE2"
cat > "$SE2/solidtime.conf" <<'EOF'
SOLIDTIME_URL=https://legacy.test
SOLIDTIME_TOKEN='9|tok|en'
SOLIDTIME_ORG_ID=org-legacy
EOF
chmod 600 "$SE2/solidtime.conf"
HOME="$H2" st_migrate_config

assert_eq "config.yml written" "yes" "$([ -f "$SE2/config.yml" ] && echo yes || echo no)"
parsed="$(st_config_parse "$SE2/config.yml")"
assert_eq "url carried over" "https://legacy.test" "$(get SOLIDTIME_URL)"
assert_eq "token with pipes carried over" '9|tok|en' "$(get SOLIDTIME_TOKEN)"
assert_eq "org carried over" "org-legacy" "$(get SOLIDTIME_ORG_ID)"
assert_eq "config.yml is chmod 600" "600" "$(ls -l "$SE2/config.yml" | awk '{print substr($1,2,9)}' | sed 's/rw-------/600/')"
assert_eq "legacy conf archived, not left live" "no" "$([ -f "$SE2/solidtime.conf" ] && echo yes || echo no)"
assert_eq "legacy conf kept as .migrated" "yes" "$([ -f "$SE2/solidtime.conf.migrated" ] && echo yes || echo no)"

# --- idempotent, and never overwrites an existing config.yml ---
HOME="$H2" st_migrate_config
assert_eq "second conversion is a no-op" "yes" "$([ -f "$SE2/config.yml" ] && echo yes || echo no)"

H3="$TMP/h3"; SE3="$H3/.session-tracker"; mkdir -p "$SE3"
printf 'SOLIDTIME_URL=https://old.test\n' > "$SE3/solidtime.conf"
printf 'solidtime:\n  url: https://mine.test\n' > "$SE3/config.yml"
HOME="$H3" st_migrate_config
parsed="$(st_config_parse "$SE3/config.yml")"
assert_eq "existing config.yml is never overwritten" "https://mine.test" "$(get SOLIDTIME_URL)"

# --- st_config_set: writes one key without disturbing the rest of the file ---
H4="$TMP/h4"; SE4="$H4/.session-tracker"; mkdir -p "$SE4"
export HOME="$H4"

st_config_set solidtime url https://fresh.test
assert_eq "creates the file when absent" "SOLIDTIME_URL=https://fresh.test" "$(st_config_parse "$SE4/config.yml")"
assert_eq "new file is chmod 600" "rw-------" "$(ls -l "$SE4/config.yml" | awk '{print substr($1,2,9)}')"

st_config_set solidtime token '1|tok#en'
st_config_set solidtime org_id org-7
parsed="$(st_config_parse "$SE4/config.yml")"
assert_eq "appended key readable" '1|tok#en' "$(get SOLIDTIME_TOKEN)"
assert_eq "sibling key untouched" "https://fresh.test" "$(get SOLIDTIME_URL)"
assert_eq "third key readable" "org-7" "$(get SOLIDTIME_ORG_ID)"

st_config_set solidtime token rotated-token
parsed="$(st_config_parse "$SE4/config.yml")"
assert_eq "existing key is replaced, not duplicated" "rotated-token" "$(get SOLIDTIME_TOKEN)"
assert_eq "replace leaves one entry per key" "3" "$(printf '%s\n' "$parsed" | grep -c .)"
assert_eq "replace keeps siblings" "org-7" "$(get SOLIDTIME_ORG_ID)"

# a second section must survive a write to the first
printf 'reporting:\n  format: csv\n' >> "$SE4/config.yml"
st_config_set solidtime url https://moved.test
parsed="$(st_config_parse "$SE4/config.yml")"
assert_eq "unrelated section survives" "csv" "$(get REPORTING_FORMAT)"
assert_eq "target key still updated" "https://moved.test" "$(get SOLIDTIME_URL)"
st_config_set reporting format tsv
parsed="$(st_config_parse "$SE4/config.yml")"
assert_eq "writing into the second section updates it" "tsv" "$(get REPORTING_FORMAT)"
assert_eq "writing into the second section leaves the first" "https://moved.test" "$(get SOLIDTIME_URL)"

# --- no trailing whitespace on empty values (config files get linted/stripped) ---
st_config_set solidtime member_id ""
assert_eq "empty value writes no trailing space" "0" \
  "$(grep -c ' $' "$SE4/config.yml")"
assert_eq "empty value still parses as empty" "SOLIDTIME_MEMBER_ID=" \
  "$(st_config_parse "$SE4/config.yml" | grep '^SOLIDTIME_MEMBER_ID=')"

H5="$TMP/h5"; SE5="$H5/.session-tracker"; mkdir -p "$SE5"
printf "SOLIDTIME_URL=https://x.test\nSOLIDTIME_TOKEN=t\nSOLIDTIME_ORG_ID=o\n" > "$SE5/solidtime.conf"
HOME="$H5" st_migrate_config
assert_eq "conversion writes no trailing space" "0" "$(grep -c ' $' "$SE5/config.yml")"

finish
