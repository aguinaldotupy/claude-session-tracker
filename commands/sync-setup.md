---
description: Configure Solidtime sync (URL, API token, organization)
disable-model-invocation: true
---

# Sync Setup

Walks through configuring the plugin's optional Solidtime sync: writes `~/.claude/session-env/solidtime.conf` and verifies it against the real instance. Solidtime sync posts each session's active-time brackets to a [Solidtime](https://github.com/solidtime-io/solidtime) instance for a unified, multi-machine dashboard — see `docs/superpowers/specs/2026-08-21-solidtime-sync-design.md` for the full design.

## Arguments

None — this command is interactive. It asks the user for each value in the conversation.

## Behavior

1. If `~/.claude/session-env/solidtime-sync.sh` does not exist, tell the user the session-tracker hooks haven't deployed the sync client yet (it ships on the next `SessionStart` — start a new session and retry) and stop.
2. Explain briefly where to get each value:
   - **API token** — in the Solidtime web UI, under the user's profile → API tokens; create a new token there.
   - **Organization id** — visible in the instance's URL/settings when viewing the organization (org switcher or Settings → Organization page).
   - **Instance URL** — the base URL of the Solidtime instance (self-hosted, or `https://app.solidtime.io`), no trailing slash.
3. Ask the user for the three values (accept them all at once if given up front):
   - `SOLIDTIME_URL`
   - the API token
   - `SOLIDTIME_ORG_ID`
   Do not ask for a member id — the sync client resolves and caches it automatically from the memberships API on first run.
4. Write `~/.claude/session-env/solidtime.conf` with the three `KEY=VALUE` lines and `chmod 600` it. **Single-quote every value** (`SOLIDTIME_TOKEN='...'`) — the file is `source`d, and Solidtime issues Laravel Sanctum tokens shaped `<id>|<random>`, so an unquoted value would run the half after the `|` as a command and leave the token empty. Overwrite any existing file — this command is also how a user rotates a token, or re-points sync at a different instance or organization (the client detects the change and discards its cached project/member ids automatically).
5. Verify with one real API call — `--check` makes a single `GET /users/me/memberships` against the instance instead of a normal sync run (which, with zero ended sessions queued, would make no HTTP call at all and could "verify" a wrong token or org by doing nothing) — and confirms the configured organization id is actually among the token's memberships, not just that the token is valid for *some* org:
   ```bash
   bash ~/.claude/session-env/solidtime-sync.sh --check --verbose
   ```
   Its output is exactly one line: `credentials OK` (URL and token reachable, and the org id was found among the token's memberships), `credentials FAILED: org not found` (token valid but not a member of the configured org), or `credentials FAILED: HTTP <code>`.
6. **Never echo the token back in full.** When confirming what was saved, show only the first 6 characters followed by `...` (e.g. `abc123...`).
7. Interpret the result:
   - `credentials OK` → configured and verified.
   - `credentials FAILED: org not found` → org id is wrong (or the token's user isn't a member of it); re-confirm the org id.
   - `credentials FAILED: HTTP 401` → token invalid; ask for a fresh token and rewrite the config.
   - `credentials FAILED: HTTP 404` → URL is wrong; re-confirm it.
   - any other failure (timeout, connection error, other status) → show the raw output and suggest checking the URL is reachable from this machine.
   For more on what an error means, see `/session-tracker:sync` and the `sync` skill.

## Implementation hint

```bash
mkdir -p "$HOME/.claude/session-env"
cat > "$HOME/.claude/session-env/solidtime.conf" <<EOF
SOLIDTIME_URL='$SOLIDTIME_URL'
SOLIDTIME_TOKEN='$SOLIDTIME_TOKEN'
SOLIDTIME_ORG_ID='$SOLIDTIME_ORG_ID'
EOF
chmod 600 "$HOME/.claude/session-env/solidtime.conf"
bash "$HOME/.claude/session-env/solidtime-sync.sh" --check --verbose
```

Display the `credentials OK` / `credentials FAILED: HTTP <code>` result to the user, and confirm the token was saved showing only its first 6 characters (never the full value).
