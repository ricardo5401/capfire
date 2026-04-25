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
| `GET` | `/deploys` | List deploys you triggered (mine-only). |
| `POST` | `/deploys` | Start a deploy (SSE or async). |
| `GET` | `/deploys/:id` | Full status + log of one deploy. |
| `POST` | `/commands` | Run restart / rollback / status. |
| `GET` | `/tasks` | List task runs you triggered (mine-only). |
| `POST` | `/tasks` | Run a custom task (SSE or async). |
| `GET` | `/tasks/:id` | Full status + log of one task run. |
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

Lists deploys triggered by the current token holder (matched via `sub`
claim → `triggered_by` column). You never see deploys of other users.

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://capfire.example.com/deploys?active=true&app=myapp&limit=50"
```

Query parameters (all optional):

| Param | Values | Default |
|---|---|---|
| `active` | `true` / `false` | `false` |
| `app` | app name | any |
| `env` | env name | any |
| `status` | `pending` / `running` / `success` / `failed` / `canceled` | any |
| `limit` | 1–100 | 20 |

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
      "triggered_by": "admin",
      "started_at": "2026-04-24T15:11:00Z",
      "finished_at": "2026-04-24T15:13:42Z",
      "duration_seconds": 162
    }
  ]
}
```

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

Same JSON shape as the items in `GET /deploys`, plus a `log` key with the
raw captured output.

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

Lists task runs triggered by the current token holder. Same privacy
posture as `/deploys`.

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://capfire.example.com/tasks?active=true&app=pyworker&limit=50"
```

Query parameters (all optional):

| Param | Values | Default |
|---|---|---|
| `active` | `true` / `false` | `false` |
| `app` | app name | any |
| `env` | env name | any |
| `task` | task name | any |
| `status` | `pending` / `running` / `success` / `failed` / `canceled` | any |
| `limit` | 1–100 | 20 |

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
  ]
}
```

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
