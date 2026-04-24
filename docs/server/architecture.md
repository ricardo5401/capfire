# Architecture

## Component map

```
+----------+                +-------------------+
|  client  | -- HTTPS/JWT ->|   Rails API       |
| (go CLI) |                |                   |
+----------+                |  DeploysCtrl      |
                            |  CommandsCtrl     |
+----------+                |  LbCtrl           |
| CI curl  | -- HTTPS/JWT ->|  TokensCtrl       |
+----------+                +--------+----------+
                                     |
                                     v
                            +-------------------+     +-----------------+
                            |  DeployService    |<----|   AppConfig     |  reads capfire.yml
                            +--------+----------+     +-----------------+
                                     |                        |
              LB enabled?            v                        v
              per-app yml   +------------------+   +------------------+
                            | CloudflareLbSvc  |   |  CommandRunner   |
                            +------------------+   +--------+---------+
                                                            | PTY.spawn('sh -c "...")
                                                            v yields raw lines
                                                   +------------------+
                                                   |    SseWriter     |
                                                   +--------+---------+
                                                            v
                                                     SSE client
```

## Files at a glance

| File | Role |
|---|---|
| `app/controllers/application_controller.rb` | Auth (JWT bearer) + SSE header prep |
| `app/controllers/deploys_controller.rb` | `POST /deploys`, `GET /deploys`, `GET /deploys/:id` |
| `app/controllers/commands_controller.rb` | `POST /commands` (restart/rollback/status) |
| `app/controllers/tokens_controller.rb` | `GET /tokens/me` introspection |
| `app/controllers/lb_controller.rb` | `POST /lb/drain`, `POST /lb/restore` |
| `app/controllers/concerns/runnable.rb` | SSE + async + render_busy — shared between Deploys and Commands |
| `app/services/deploy_service.rb` | Lifecycle orchestration (create → drain → run → restore → notify) |
| `app/services/app_config.rb` | Per-app `capfire.yml` loader |
| `app/services/command_runner.rb` | Runs the deploy command under `sh -c` via PTY |
| `app/services/cloudflare_lb_service.rb` | Cloudflare LB API calls |
| `app/services/load_balancer_config.rb` | Immutable per-app LB config struct |
| `app/services/jwt_service.rb` | Token encode/decode + `authorize!` |
| `app/services/sse_writer.rb` | SSE formatting + heartbeats |
| `app/services/slack_notifier.rb` | Block Kit webhook poster |
| `app/models/deploy.rb` | Deploy lifecycle record |
| `app/models/api_token.rb` | Token metadata |
| `app/models/revoked_token.rb` | Revocation lookup |
| `lib/capfire_cli/*` | `bin/capfire` (tokens, project, service, config) |
| `client/*` | Go developer CLI (separate module) |

Keep controllers thin — they validate params, authorize, and delegate.
Business logic always lives in services.

## Service lifecycle (typical deploy)

1. `DeploysController#create` validates params and token claims.
2. Builds a `DeployService` and calls `#call` with a block (streaming) or
   `#enqueue` then a background thread (async).
3. `DeployService#enqueue` creates the `deploys` row (unique index on
   `app + active-status` rejects concurrent attempts with `Busy`).
4. If `AppConfig#load_balancer_for(env)` returns a config, the service
   calls `CloudflareLbService#drain!`.
5. `CommandRunner.run` spawns the resolved command in the app's working
   directory, emitting raw log lines through the block.
6. The service always restores the LB (even on failure), marks the row
   finished, and emits the terminal `done` event.
7. `SlackNotifier` posts if the app has `slack.enabled: true` and it was
   a `deploy` command.

## Concurrency

Capfire runs **1 Puma worker, many threads**. Rationale:

- SSE streams live in process memory (no forking across workers).
- Deploy threads must not be killed mid-run; long worker timeouts are
  easier to reason about with a single worker.
- The `deploys` table has a unique partial index on `app` for statuses
  `(pending, running)`. A second concurrent POST for the same app hits a
  PG unique violation → translated to HTTP 409.

The worker timeout is 1 hour (`worker_timeout 3600` in `config/puma.rb`).
Deploys that take longer will be killed; tune it up if your build is
slower.

## Orphan deploy reclamation

On boot, `config/initializers/orphan_deploys.rb` looks for any row in
`pending/running` state. Because Capfire runs as a single worker, any
"active" row at boot time is definitely an orphan (its Thread is gone).
Orphans are marked `failed` with exit_code 1, a note is appended to their
log, and the unique index is released so new deploys can proceed.

This is safe **only because Puma runs one worker**. If you ever switch
to multiple workers, this initializer would sabotage deploys owned by
the other worker — rethink it first.

## Database

Three tables, all in Postgres:

| Table | Purpose |
|---|---|
| `deploys` | One row per run: app, env, branch, status, exit_code, full log |
| `api_tokens` | Metadata of every issued token (apps, envs, cmds, expiry) |
| `revoked_tokens` | Fast `jti` lookup during decode |

Logs live in `deploys.log` (TEXT). If it grows unbounded, move old logs
to object storage — `Deploy#append_log!` is the only write site.

## Operational notes

- **SSE + nginx**: `proxy_buffering off;` in the Capfire location block.
  Capfire sends `X-Accel-Buffering: no` but some configs ignore it.
- **Log retention**: no automatic rotation. Add a cron to purge old
  `deploys` rows if disk pressure.
- **Concurrent deploys**: Capfire blocks a second deploy for the same
  **app** (across all envs) — the cockpit is one git checkout per app
  and a concurrent `git checkout <branch>` would corrupt the other run.
  Different apps deploy freely in parallel.
- **Client reconnect mid-deploy**: if the SSE client drops, the deploy
  keeps running. Final state lands in the `deploys` row — poll
  `GET /deploys/:id` (or `capfire status ID`).
- **Multiple nodes behind a Cloudflare LB**: each node has its own
  `load_balancer.origin` in the app's `capfire.yml` pointing at its own
  IP. Capfire only touches its own entry in the pool.
