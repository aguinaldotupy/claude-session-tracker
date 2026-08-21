# Solidtime API contract — verified notes

**Date:** 2026-08-21
**Purpose:** Ground-truth for `hooks/lib/solidtime-sync.sh` (Task 4 of the
solidtime-sync plan). Corrects/confirms the research-derived assumptions in
`docs/superpowers/specs/2026-08-21-solidtime-sync-design.md`.

## Sources

- Hosted API docs (`docs.solidtime.io/api-reference`) render a Scalar viewer
  that loads its spec client-side from a separate host — the page itself has
  no static content to read via curl/WebFetch.
- The spec URL is declared in the docs site's build config:
  `docusaurus.config.ts` → `@scalar/docusaurus` plugin →
  `configuration.spec.url = 'https://api-docs.solidtime.io/api-docs.json'`.
  https://github.com/solidtime-io/docs/blob/main/docusaurus.config.ts
- **Primary source used for this document:** the live, generated OpenAPI 3.1
  spec fetched directly: https://api-docs.solidtime.io/api-docs.json
  (fetched 2026-08-21; `info.title: "solidtime"`, 30 paths). This is what
  `docs.solidtime.io/api-reference` actually renders — it is deployed by the
  repo's `.github/workflows/generate-api-docs.yml` CI job on every push to
  `main` via `php artisan scramble:export` + Fastfront, so it tracks
  production.
- The `openapi.json` file checked into the `solidtime-io/solidtime` repo root
  (referenced by the task brief as a fallback) is **stale and incomplete** —
  last touched 2025-04-13 by an unrelated refactor commit, and contains only
  4 paths (projects, time-entries — no tags, no users, no members). It should
  **not** be used as a source; this note documents that so nobody reaches for
  it again. https://github.com/solidtime-io/solidtime/blob/main/openapi.json
- Laravel source (`solidtime-io/solidtime` repo, `main` branch, fetched
  2026-08-21) used to confirm validation rules and behavior the OpenAPI
  schema doesn't fully capture (required-ness beyond types, overlap checks,
  rate-limit defaults):
  - `app/Http/Requests/V1/TimeEntry/TimeEntryStoreRequest.php`
  - `app/Http/Controllers/Api/V1/TimeEntryController.php`
  - `app/Providers/RouteServiceProvider.php`, `app/Http/Kernel.php`,
    `config/app.php`
- `docs.solidtime.io/user-guide/access-api` (rendered Markdown, fetched via
  `gh api` on `solidtime-io/docs`) for the auth-header convention.
  https://github.com/solidtime-io/docs/blob/main/docs/user-guide/access-api.md

All paths below are relative to the server base URL. The spec's declared
production server is `https://app.solidtime.io/api`
(`servers[0].url` in api-docs.json) — i.e. the API lives under an `/api`
prefix on the instance host, confirming the existing `_SL_API_*` constants'
`api/v1/...` shape (`SOLIDTIME_URL` + `/` + `api/v1/...`).

## Auth

`Authorization: Bearer <api-token>` — a personal API token created in
profile settings, sent as a Sanctum/Passport bearer token (docs describe it
as "a JWT token" but the client-facing contract is just the standard Bearer
header). Source: `docs/user-guide/access-api.md` (link above).

The spec's `security` block declares an OAuth2 `authorizationCode` flow —
that's the scheme used by first-party web/desktop clients, not personal API
tokens. Personal tokens (what this plugin uses) are documented only in the
user guide, not modeled in the OpenAPI security scheme. No change to our
auth header logic needed either way — it was already `Bearer $SOLIDTIME_TOKEN`.

## Create time entry

**`POST /v1/organizations/{organization}/time-entries`**
→ full path `api/v1/organizations/%s/time-entries` — matches
`_SL_API_ENTRIES` already in `solidtime-sync.sh`. No change.

Request body (`TimeEntryStoreRequest`):

| Field | Type | Required | Notes |
|---|---|---|---|
| `member_id` | string (UUID) | **yes** | ID of the *organization membership* the entry belongs to — see "member_id" section below. |
| `start` | string | **yes** | Format `Y-m-d\TH:i:s\Z` (Laravel `date_format`), e.g. `2000-02-22T14:58:59Z`. UTC only, literal `Z`, no fractional seconds, no offset form. |
| `billable` | boolean | **yes** | |
| `project_id` | string\|null | no | `required_with:task_id`; must belong to the org. |
| `task_id` | string\|null | no | Must belong to `project_id`. |
| `end` | string\|null | no | Same format as `start`; validated `after_or_equal:start`. Omitting it (null) starts a *running* timer — creation fails with a "still running" error if the member already has an open entry. |
| `tags` | array of string (UUID) | no | **Field name is `tags`, not `tag_ids`.** Array of tag IDs. |
| `description` | string\|null | no | max 5000 chars. |
| `type` | string enum (`work`\|`break`) | no | Not in the design's mapping; safe to omit (defaults to a normal work entry). `break` is rejected unless the org has breaks enabled, and prohibits `project_id`/`task_id`/`tags`/`billable`. |

Response `200`: `{"data": <TimeEntryResource>}`, `id` at `data.id`.
`TimeEntryResource` fields: `id, start, end, duration, description, task_id,
project_id, organization_id, user_id, tags, billable` — note there is no
`member_id` in the *response*, only `user_id`.

**Retroactive start/end:** accepted with no lower-bound date check. The
validator only enforces the string format and `end >= start`; no
`before:now` / minimum-date rule exists in
`TimeEntryStoreRequest::rules()`. Confirmed in source, not just inferred
from the schema.

**Overlap constraint (undocumented in the OpenAPI schema, found in source):**
`TimeEntryController::store()` calls `assertNoOverlap($organization,
$member, $start, $end)` before saving — two time entries for the *same
member* may not overlap in time. Sequential, non-overlapping brackets (as
`active-time.awk -v mode=brackets` produces) satisfy this by construction;
flagging it because a future change to the bracket algorithm that allows
overlap would start failing time-entry creation with a 4xx, not something
visible from the field list alone.

Example request:

```json
POST /api/v1/organizations/f47ac10b-58cc-4372-a567-0e02b2c3d479/time-entries
Authorization: Bearer <token>
Content-Type: application/json

{
  "member_id": "9c858901-8a57-4791-81fe-4c455b099bc9",
  "project_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
  "tags": ["b3f9c2a0-1111-4c2a-9c2a-abcde1234567"],
  "start": "2026-08-21T09:00:00Z",
  "end": "2026-08-21T09:45:00Z",
  "billable": false,
  "description": "myhost · a1b2c3d4:0"
}
```

Example response:

```json
{
  "data": {
    "id": "e2f1a3b4-5678-4abc-9def-0123456789ab",
    "start": "2026-08-21T09:00:00Z",
    "end": "2026-08-21T09:45:00Z",
    "duration": 2700,
    "description": "myhost · a1b2c3d4:0",
    "task_id": null,
    "project_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "organization_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "user_id": "0c1d2e3f-...",
    "tags": ["b3f9c2a0-1111-4c2a-9c2a-abcde1234567"],
    "billable": false
  }
}
```

## member_id — required, and how to discover it

**`member_id` is required on every time-entry create call**, not optional
as the design/Task 5 draft treats it (`${SOLIDTIME_MEMBER_ID:-}` included
only when set). It identifies the caller's **organization membership**, a
different id than the user id, and a different id than the org id.

`TimeEntryController::store()`: the `member_id` in the request must resolve
to a `Member` row; if it's the caller's own membership, the token needs
permission `time-entries:create:own`; if it names someone else's
membership, it needs `time-entries:create:all`. For this plugin's use case
(a user syncing their own time), it's always their own membership id.

**Discovery:** `GET /v1/users/me/memberships` (no org path param — "This
endpoint is independent of organization"). Response:
`{"data": [PersonalMembershipResource, ...]}`, one entry per organization
the user belongs to:

```json
{
  "data": [
    {
      "id": "9c858901-8a57-4791-81fe-4c455b099bc9",
      "organization": {
        "id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "name": "Acme Inc",
        "currency": "EUR"
      },
      "role": "employee"
    }
  ]
}
```

To get the member_id for `SOLIDTIME_ORG_ID`: fetch this list and pick the
entry whose `organization.id` equals `SOLIDTIME_ORG_ID`; that entry's `id`
is the value to store as `SOLIDTIME_MEMBER_ID`. This also happens to be a
valid way to confirm the configured org id is real and the token can see
it — worth doing once during `/session-tracker:sync-setup` (Task 9) rather
than resolved by the sync script on every run.

`GET /v1/users/me` (`{"data": UserResource}` — `id, name, email,
profile_photo_url, timezone, week_start`) is the plain "who am I" endpoint;
not needed for member_id but confirms the token is valid.

## List / create project

**`GET /v1/organizations/{organization}/projects`** — query params: `page`
(int), `archived` (`true`|`false`|`all`, default excludes archived). No
name filter — the resolver must list-and-scan.
Response: `{"data": [ProjectResource, ...], "links": {...}, "meta": {...}}`
(paginated). **Default page size is 15**
(`config('app.pagination_per_page_default')`, default `15`, source
`config/app.php`). An org with more than 15 projects will not have all of
them returned by a single unpaged GET — a risk for Task 6's
list-then-find-by-name resolver (it can create a duplicate project if the
existing one is on page 2+). Flagged under Deltas below; not fixed here
(field-name/path scope only).

**`POST /v1/organizations/{organization}/projects`** — full path
`api/v1/organizations/%s/projects`, matches `_SL_API_PROJECTS`. No change.

Request body (`ProjectStoreRequest`), **required fields differ from the
design's assumption**:

| Field | Type | Required |
|---|---|---|
| `name` | string (1–255 chars) | **yes** |
| `color` | string (≤255 chars) | **yes** |
| `is_billable` | boolean | **yes** |
| `client_id` | string\|null | no |
| `billable_rate` | integer\|null (cents/hour) | no |
| `estimated_time` | integer\|null (seconds) | no |
| `is_public` | boolean | no |

The task-6 draft resolver posts `{"name": $n}` only — that will 422 (missing
`color`, `is_billable`). Task 6 needs to send a `color` (any valid CSS-ish
color string works — Solidtime's own UI generates a random hex) and
`is_billable` (e.g. `false`) alongside `name`.

Response `200`: `{"data": <ProjectResource>}`, `id` at `data.id`.
`ProjectResource` fields: `id, name, color, client_id, is_archived,
billable_rate, is_billable, estimated_time, spent_time, is_public`.

Example create request/response:

```json
POST /api/v1/organizations/f47ac10b.../projects
{ "name": "session-tracker", "color": "#4287f5", "is_billable": false }
```
```json
{
  "data": {
    "id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "name": "session-tracker",
    "color": "#4287f5",
    "client_id": null,
    "is_archived": false,
    "billable_rate": null,
    "is_billable": false,
    "estimated_time": null,
    "spent_time": 0,
    "is_public": false
  }
}
```

## List / create tag

**`GET /v1/organizations/{organization}/tags`** — query param: `page`. No
name filter (same pagination caveat as projects, default 15/page).
Response: `{"data": [TagResource, ...], "links": {...}, "meta": {...}}`.

**`POST /v1/organizations/{organization}/tags`** — full path
`api/v1/organizations/%s/tags`, matches `_SL_API_TAGS`. No change.

Request body (`TagStoreRequest`): `name` (string, 1–255 chars) — **only
required field.** Matches the design's assumption exactly, no delta.

Response `200`: `{"data": <TagResource>}`. `TagResource`: `id, name,
created_at, updated_at`.

```json
POST /api/v1/organizations/f47ac10b.../tags
{ "name": "A-7" }
```
```json
{
  "data": {
    "id": "b3f9c2a0-1111-4c2a-9c2a-abcde1234567",
    "name": "A-7",
    "created_at": "2026-08-21T09:00:00.000000Z",
    "updated_at": "2026-08-21T09:00:00.000000Z"
  }
}
```

## Rate limits

Source: `app/Providers/RouteServiceProvider.php` (`RateLimiter::for('api',
...)`) + `app/Http/Kernel.php` (`'api' => [ThrottleRequests::class.':api',
...]`, applied to the whole `routes/api.php` group, so every endpoint above
is covered) + `config/app.php`.

- Authenticated requests: `Limit::perMinute(config('app.api_rate_limit_authenticated_per_minute'))`,
  keyed by user id. Default **200 req/min**, overridable via the
  self-hosted `API_RATE_LIMIT_AUTH_PER_MINUTE` env var.
- Unauthenticated: 60/min by default (`API_RATE_LIMIT_GUEST_PER_MINUTE`) —
  not relevant here since every call carries a bearer token.
- **No limit at all when `app.isProduction()` is false** — i.e. local/dev
  instances are unthrottled; only matters for anyone testing against a
  non-production self-hosted instance.
- This is the self-hosted default; solidtime.io Cloud's actual configured
  value isn't published anywhere I could find (not in the docs site, not
  in response headers I have visibility into without a live token) — 200/min
  is the code default and a reasonable assumption, but if Cloud overrides
  `API_RATE_LIMIT_AUTH_PER_MINUTE` lower, our per-session batch of a few
  dozen entries could hit a 429. `_sl_post_entry`'s existing
  `curl --retry 2 --retry-delay 2` plus the ledger-based resume-on-failure
  design already tolerate a transient 429 as just another non-2xx: the
  bracket stays unposted and the next sync trigger retries it. No code
  change needed for this task; noting it so nobody assumes the number is
  verified against the live Cloud service.

## Deltas vs design spec

1. **`member_id` is required, not optional** (design/Task-5-draft treat it
   as an optional field only sent when `SOLIDTIME_MEMBER_ID` happens to be
   set). Every time-entry create call needs it. Task 9's `sync-setup`
   command currently only collects `SOLIDTIME_URL`/token/org id — it needs
   to also resolve and store `SOLIDTIME_MEMBER_ID` via `GET
   /v1/users/me/memberships` (documented above) or entry creation will 422
   on every session once member_id stops being optional in the payload
   builder.
2. **Tag field name on time-entry create is `tags` (array), not
   `tag_ids`.** Task 5's draft payload builds
   `{tag_ids:[$t]}` — must be `{tags:[$t]}`.
3. **Project creation requires `color` and `is_billable`, not just
   `name`.** Task 6's draft resolver POSTs `{"name": $n}` only; needs
   `color` + `is_billable` added or the create call 422s.
4. **Path/constant strings themselves were correct.** `_SL_API_ENTRIES`,
   `_SL_API_PROJECTS`, `_SL_API_TAGS`, `_SL_API_ME` in
   `hooks/lib/solidtime-sync.sh` already match the confirmed paths exactly
   (`api/v1/organizations/%s/...`, `api/v1/users/me`) — no changes needed
   to those four. Added one new constant, `_SL_API_MEMBERSHIPS`, for the
   member_id discovery call needed by delta #1 (see below).
5. Pagination default (15/page) on project/tag list endpoints, and the
   overlap constraint on time entries, weren't mentioned in the design at
   all — both are real API behavior, documented above as risks/constraints
   for Tasks 6 (pagination) and unaffected-but-worth-knowing for Task 5
   (overlap).
6. Everything else in the design's data-mapping table (`start`/`end` as
   bracket timestamps, `project_id`, ISO 8601 UTC timestamp format,
   `Authorization: Bearer` header, response envelope `{"data": ...}` with
   `id` at the top level) is confirmed correct as designed.

## Constants change

Added `_SL_API_MEMBERSHIPS="api/v1/users/me/memberships"` to the
`_SL_API_*` block in `hooks/lib/solidtime-sync.sh` for delta #1's
member_id discovery. The four existing constants are unchanged (confirmed
correct per source #4 above).
