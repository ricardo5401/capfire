# HTTP API reference

Every endpoint except `/healthz` requires a valid JWT in the
`Authorization: Bearer ...` header. Authorization is additionally checked
per-action against the token's `apps`, `envs`, and `cmds` claims.

If you're a developer, prefer the [Go client](../client/commands.md) —
this reference is for automation (CI) and for understanding what the
client does under the hood.

## Endpoints at a glance

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/healthz` | Liveness probe. No auth. |
| `GET` | `/tokens/me` | Introspect the bearer token. |
| `GET` | `/deploys` | List deploys (yours by default; `?all=true` for the team's). |
| `POST` | `/deploys` | Start a deploy (SSE or async). |
| `GET` | `/deploys/:id` | Full status + log of one deploy. |
| `POST` | `/deploys/:id/abort` | Cancel a running deploy. |
| `POST` | `/commands` | Run restart / rollback / status. |
| `GET` | `/tasks` | List task runs (yours by default; `?all=true` for the team's). |
| `POST` | `/tasks` | Run a custom task (SSE or async). |
| `GET` | `/tasks/:id` | Full status + log of one task run. |
| `POST` | `/tasks/:id/abort` | Cancel a running task. |
| `POST` | `/lb/drain` | Drain this node out of the LB pool. |
| `POST` | `/lb/restore` | Re-enable this node in the LB pool. |

## `GET /healthz`

No authentication. Returns `200 OK` with body `ok` when the process is
alive. Use for load-balancer probes and container healthchecks.

## `GET /tokens/me`

Returns the claims of the bearer token, enriched with DB metadata.

```bash
curl -s -H "Authorization: Bearer $TOKEN" https://capfire.example.com/tokens/me
```

```json
{
  "name": "juan",
  "jti": "6f3a08a7-...",
  "grants": [
    { "app": "myapp-api", "envs": ["staging", "production"], "cmds": ["deploy", "restart"] },
    { "app": "myapp",     "envs": ["staging"],               "cmds": ["deploy", "restart"] }
  ],
  "issued_at": "2026-04-24T15:10:30Z",
  "expires_at": null,
  "revoked": false,
  "revoked_at": null,
  "known_locally": true
}
```

`known_locally=false` means the signature is valid but the `jti` is not in
the local `api_tokens` table — unusual; typically happens during DB restores.

## `GET /deploys`

By default lists deploys triggered by the current token holder (matched
via `sub` claim → `triggered_by` column). With `?all=true`, lists every
deploy on apps the token has any grant on — that's how a teammate sees
your in-flight deploy without being the original triggerer.

```bash
# Default: just yours
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://capfire.example.com/deploys?active=true&app=myapp&limit=50"

# Team scope: anyone's deploys on apps you have access to
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://capfire.example.com/deploys?all=true&active=true"
```

Query parameters (all optional):

| Param | Values | Default |
|---|---|---|
| `all` | `true` / `false` — switch from "mine" to "anything I can see" | `false` |
| `active` | `true` / `false` | `false` |
| `app` | app name (validated against visible apps in `?all=true` mode) | any |
| `env` | env name | any |
| `status` | `pending` / `running` / `success` / `failed` / `canceled` | any |
| `page` | 1-based page number; out-of-range returns an empty list | `1` |
| `per_page` | rows per page, 1–100 | `20` |
| `limit` | **deprecated alias for `per_page`** — honored when `per_page` is missing | — |

Response:

```json
{
  "deploys": [
    {
      "id": 42,
      "app": "myapp",
      "env": "production",
      "branch": "master",
      "command": "deploy",
      "status": "success",
      "exit_code": 0,
      "pid": null,
      "triggered_by": "admin",
      "started_at": "2026-04-24T15:11:00Z",
      "finished_at": "2026-04-24T15:13:42Z",
      "duration_seconds": 162
    }
  ],
  "scope": "mine",
  "hint": "showing only your deploys; pass `all=true` to see every deploy on apps you have access to",
  "pagination": {
    "page": 1,
    "per_page": 20,
    "total_count": 247,
    "total_pages": 13
  }
}
```

`hint` is only present when `?all=true` is NOT set — it's the
discoverability mechanism for the team-visibility feature. `scope` is
always `"mine"` or `"all"` so clients can branch on it without parsing
the hint string.

`pagination` is always present, even on empty results. `total_pages`
is `1` (not `0`) when `total_count` is zero so client UIs never have to
special-case the empty footer. The pagination metadata reflects the
**filtered** scope — applying `?status=running` shrinks `total_count`
to only the running rows, which is what a "page X of Y" footer over a
filtered listing has to mean.

`per_page` values above 100 are silently clamped to 100. Out-of-range
`page` values (e.g. `?page=999` against 5 rows) return an empty
`deploys` array with `pagination.page=999` echoed back — never a 4xx.
That keeps "next page is empty → hide the next button" trivial in
client code.

## `POST /deploys`

Triggers a deploy. Two modes:

**Streaming (default).** Returns `text/event-stream` and emits events
until the deploy finishes. Connection stays open.

```bash
curl -N -X POST https://capfire.example.com/deploys \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"myapp","env":"production","branch":"master"}'
```

**Async.** Returns `202 Accepted` immediately. The deploy runs in a
background thread; Slack notifies on completion (if enabled) and the
caller polls `GET /deploys/:id`.

```bash
curl -X POST https://capfire.example.com/deploys \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"myapp","env":"production","branch":"master","async":true}'
```

Request body:

```json
{
  "app":     "myapp",
  "env":     "production",
  "branch":  "master",           // optional, defaults to "main"
  "skip_lb": false,              // optional, bypass LB drain/restore
  "async":   false               // optional
}
```

### SSE event stream

Four event names, one JSON payload each:

| Event | Payload | Meaning |
|---|---|---|
| `info` | `{message}` | Lifecycle update (drain start, etc.) |
| `log` | `{line}` | One raw stdout/stderr line from the deploy command |
| `error` | `{message}` | Something went wrong — deploy likely failed |
| `done` | `{deploy_id, exit_code, status}` | Final event, stream closes |

Example stream:

```
event: info
data: {"message":"draining origin=35.185.55.232 from Cloudflare LB"}

event: log
data: {"line":"bundle exec cap production deploy"}

event: log
data: {"line":"00:00 deploy:starting"}

event: done
data: {"deploy_id":137,"exit_code":0,"status":"success"}
```

The stream also emits SSE comments `: keep-alive` every 15s so proxies
don't drop the connection during quiet phases.

### Async acknowledgement (202)

```json
{
  "status":    "accepted",
  "deploy_id": 137,
  "app":       "myapp",
  "env":       "production",
  "branch":    "master",
  "track_url": "https://capfire.example.com/deploys/137",
  "message":   "Deploy queued. Slack will notify on completion if enabled; poll the track_url for status."
}
```

`track_url` is a GET-with-auth URL. To poll it from a browser you would
need the bearer token — in that case use `capfire status ID` from the Go
client instead.

### Conflict (409)

Only one active deploy per **app** (across all envs). A second concurrent
request returns:

```json
{
  "error": "conflict",
  "message": "another deploy is already in progress for myapp:production",
  "active_deploy": {
    "id": 137,
    "command": "deploy",
    "branch": "master",
    "status": "running",
    "triggered_by": "admin",
    "started_at": "2026-04-24T15:11:00Z"
  },
  "retry_after_seconds": 600
}
```

## `GET /deploys/:id`

Full detail of a single deploy, including the complete log.

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  https://capfire.example.com/deploys/137
```

Visible to:

- the original triggerer (always), or
- any caller whose token has at least one grant on the deploy's app
  (same rule as `?all=true` on the index).

Returns 403 when the token has no grant on the app, 404 when the deploy
doesn't exist.

Same JSON shape as the items in `GET /deploys`, plus a `log` key with the
raw captured output.

## `POST /deploys/:id/abort`

Cancels a running deploy. Signals the deploy's process group with
SIGTERM, waits 10 seconds, then escalates to SIGKILL if the process
hasn't exited. Idempotent: aborting an already-finished deploy returns
200 with `abort_status="already_finished"`.

```bash
curl -X POST https://capfire.example.com/deploys/137/abort \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"reason":"wrong branch"}'
```

Request body (all optional):

| Field | Notes |
|---|---|
| `reason` | Human-readable note appended to the deploy's audit log line |

Authorization: the deploy's original triggerer can always abort. Anyone
else needs `cmd: "abort"` on the deploy's app+env (or the global `*`
wildcard).

Response (200):

```json
{
  "id": 137,
  "app": "myapp",
  "env": "production",
  "branch": "master",
  "command": "deploy",
  "status": "canceled",
  "exit_code": 143,
  "pid": 25842,
  "triggered_by": "admin",
  "started_at": "2026-04-24T15:11:00Z",
  "finished_at": "2026-04-24T15:11:42Z",
  "duration_seconds": 42,
  "abort_status": "canceled",
  "abort_exit_code": 143
}
```

The `abort_exit_code` field reveals what happened on the OS side:

| Code | Meaning |
|---|---|
| `143` | Process exited cleanly within the 10s grace period (SIGTERM, 128+15) |
| `137` | Had to escalate to SIGKILL after the grace period (128+9) |
| `-1` | No live process — the row was an orphan lock (Puma restart, or aborted before the spawn). DB transition still applied. |

When the deploy is already terminal:

```json
{
  "id": 137,
  "status": "success",
  "abort_status": "already_finished"
}
```

## `POST /commands`

Runs restart / rollback / status. Uses the same SSE + async contract as
`/deploys`, minus git-sync and pre-deploy hooks (those apply only to
deploy).

```bash
# Restart
curl -N -X POST https://capfire.example.com/commands \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"myapp","env":"production","cmd":"restart"}'

# Rollback (async)
curl -X POST https://capfire.example.com/commands \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"myapp","env":"production","cmd":"rollback","async":true}'

# Status
curl -N -X POST https://capfire.example.com/commands \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"myapp","env":"production","cmd":"status"}'
```

`cmd` must be one of: `restart`, `rollback`, `status`. Unknown values
return `400 Bad Request`.

## Tasks

Tasks are user-defined commands declared per-app in `capfire.yml`, plus the
reserved built-in `sync`. They're fully separate from `/commands` (which
only handles the canonical lifecycle commands).

See [Configuration → Tasks](config.md#tasks) for the yaml shape, the
concurrency model, and the `sync` built-in semantics. This section covers
the HTTP surface only.

### `GET /tasks`

Same scoping and pagination rules as `GET /deploys`: defaults to
"yours only", flips to "every task run on apps you can see" with
`?all=true`, slices via `?page` and `?per_page` (legacy `?limit` still
honored as an alias).

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://capfire.example.com/tasks?all=true&active=true&app=pyworker&per_page=50"
```

Query parameters (all optional):

| Param | Values | Default |
|---|---|---|
| `all` | `true` / `false` | `false` |
| `active` | `true` / `false` | `false` |
| `app` | app name (validated against visible apps in `?all=true` mode) | any |
| `env` | env name | any |
| `task` | task name | any |
| `status` | `pending` / `running` / `success` / `failed` / `canceled` | any |
| `page` | 1-based page number; out-of-range returns an empty list | `1` |
| `per_page` | rows per page, 1–100 | `20` |
| `limit` | **deprecated alias for `per_page`** | — |

Response:

```json
{
  "task_runs": [
    {
      "id": 87,
      "app": "pyworker",
      "env": "production",
      "task": "backfill",
      "branch": "master",
      "args": { "since": "2024-01-01" },
      "status": "running",
      "exit_code": null,
      "triggered_by": "ana",
      "started_at": "2026-04-24T14:32:11Z",
      "finished_at": null,
      "duration_seconds": null
    }
  ],
  "scope": "mine",
  "pagination": {
    "page": 1,
    "per_page": 20,
    "total_count": 1,
    "total_pages": 1
  }
}
```

The `pagination` block is identical in shape to the one returned by
`GET /deploys` — same fields, same edge cases (clamp to 100, tolerate
out-of-range pages, reflect the filtered scope). See the deploys
section above for the full semantics.

### `POST /tasks`

Triggers a task. Same two modes as `/deploys`:

**Streaming (default).** Returns `text/event-stream`:

```bash
curl -N -X POST https://capfire.example.com/tasks \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
        "app":   "pyworker",
        "env":   "production",
        "task":  "backfill",
        "branch":"master",
        "args":  { "since": "2024-01-01" }
      }'
```

**Async.** Returns `202 Accepted` with `task_run_id` and `track_url`:

```bash
curl -X POST https://capfire.example.com/tasks \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
        "app":   "pyworker",
        "env":   "production",
        "task":  "sync",
        "branch":"master",
        "async": true
      }'
```

Response (202):

```json
{
  "status":      "accepted",
  "task_run_id": 87,
  "track_url":   "https://capfire.example.com/tasks/87",
  "app":         "pyworker",
  "env":         "production",
  "task":        "sync",
  "branch":      "master",
  "args":        {},
  "message":     "task=sync queued. Poll the track_url for status."
}
```

Body fields:

| Field | Required | Notes |
|---|---|---|
| `app` | yes | Must match `[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}` |
| `env` | yes | Must match `[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}` |
| `task` | yes | A key under `tasks:` in the app's yaml, or `sync` |
| `branch` | no | Defaults to `main`. Used by `sync` and any `%{branch}` placeholder |
| `args` | no | Object of string values. Server validates against the task's `params:` |
| `async` | no | When `true`, returns `202` instead of streaming |

Authorization claim needed: `cmd: "task:<name>"` (or the `tasks: [...]`
shorthand on the grant).

#### 409 Conflict shapes

`/tasks` can return 409 in two distinct scenarios. The body shape changes
slightly so the caller can disambiguate:

**Another task is already running on the same app:**

```json
{
  "error":   "conflict",
  "message": "another task is already in progress for app=pyworker",
  "active": {
    "task_run_id": 87,
    "task":        "backfill",
    "env":         "production",
    "branch":      "master",
    "status":      "running",
    "triggered_by":"ana",
    "started_at":  "2026-04-24T14:32:11Z"
  },
  "retry_after_seconds": 60
}
```

**`sync` requested while a deploy is running on the same app:**

```json
{
  "error":   "conflict",
  "message": "cannot run sync while a deploy is in progress for app=pyworker",
  "active_deploy": {
    "id":          42,
    "command":     "deploy",
    "branch":      "master",
    "status":      "running",
    "triggered_by":"ana",
    "started_at":  "2026-04-24T14:30:00Z"
  },
  "retry_after_seconds": 120
}
```

The Go CLI's `--wait` flag turns either case into a polling loop.

### `GET /tasks/:id`

Full detail of a single task run, including the complete log. Same JSON
shape as the items in `GET /tasks`, plus a `log` key with the raw output.

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  https://capfire.example.com/tasks/87
```

Same visibility rule as `GET /deploys/:id`: triggerer always, otherwise
any token with a grant on the task's app.

### `POST /tasks/:id/abort`

Cancels a running task. Same kill protocol, same auth rules, same
response shape as `POST /deploys/:id/abort`.

```bash
curl -X POST https://capfire.example.com/tasks/87/abort \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"reason":"wrong since= argument"}'
```

See the deploys-abort section above for the full body, auth, and
`abort_exit_code` semantics.

## `POST /lb/drain` and `POST /lb/restore`

Standalone load-balancer operations without a deploy attached. Useful for
orchestrators (GitHub Actions, custom CI) that want to coordinate
drain/restore across multiple nodes while running the actual deploy steps
elsewhere.

```bash
# Drain this node from the pool
curl -X POST https://capfire.example.com/lb/drain \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"myapp","env":"production"}'

# ... do your external deploy work ...

curl -X POST https://capfire.example.com/lb/restore \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"myapp","env":"production"}'
```

Token claim needed: `cmds: ["drain"]` / `cmds: ["restore"]`.

Returns:

```json
{
  "status":  "drained",
  "app":     "myapp",
  "env":     "production",
  "pool_id": "3c9c314b8ddf22a48c1d80496242777c",
  "origin":  "35.185.55.232"
}
```

## Error shapes

Every error response is JSON with a stable `error` code:

| HTTP | `error` | When |
|---|---|---|
| 400 | `bad_request` | Missing/invalid params (including unknown `cmd`) |
| 401 | `unauthorized` | Missing/malformed token |
| 403 | `forbidden` | Token doesn't allow this app/env/cmd |
| 404 | `not_found` | Deploy id doesn't exist |
| 409 | `conflict` | Another active deploy for this app |
| 422 | `not_configured` | Load balancer block missing/incomplete |
| 502 | `cloudflare_error` | Cloudflare API returned an error |

## Using the API from GitHub Actions

Full example wiring `/deploys` into a workflow:

```yaml
# .github/workflows/deploy.yml
name: Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      environment:
        description: 'Target environment'
        required: true
        default: staging
        type: choice
        options: [staging, production]

jobs:
  deploy:
    name: Deploy to ${{ inputs.environment || 'staging' }}
    runs-on: ubuntu-latest
    environment: ${{ inputs.environment || 'staging' }}
    concurrency:
      group: deploy-${{ inputs.environment || 'staging' }}
      cancel-in-progress: false

    steps:
      - name: Trigger deploy via Capfire
        env:
          CAPFIRE_TOKEN: ${{ secrets.CAPFIRE_TOKEN }}
          CAPFIRE_HOST:  ${{ secrets.CAPFIRE_HOST }}
          TARGET_ENV:    ${{ inputs.environment || 'staging' }}
        run: |
          set -euo pipefail
          curl -N --fail-with-body -X POST "${CAPFIRE_HOST}/deploys" \
            -H "Authorization: Bearer ${CAPFIRE_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"app\":\"myapp\",\"env\":\"${TARGET_ENV}\",\"branch\":\"${GITHUB_REF_NAME}\"}" \
          | tee /tmp/capfire_output.txt

          EXIT_CODE=$(grep '^data:' /tmp/capfire_output.txt \
            | tail -1 \
            | python3 -c "import json,sys; print(json.load(sys.stdin)['exit_code'])" 2>/dev/null || echo 1)
          exit "${EXIT_CODE}"
```

Required secrets:

| Secret | Value |
|---|---|
| `CAPFIRE_TOKEN` | JWT issued with `capfire tokens create` |
| `CAPFIRE_HOST` | `https://deploy-node-1.internal.example.com` |

Token recommendation for Actions:

```bash
# Scoped to staging only
capfire tokens create \
  --name=gh-actions-staging \
  --grant='myapp:staging:deploy'

# Production — separate token with narrower cmds and Environment protection rules
capfire tokens create \
  --name=gh-actions-production \
  --grant='myapp:production:deploy,rollback'
```
