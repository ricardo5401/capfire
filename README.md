# Capfire 🔥

**A deploy orchestrator for Capistrano-based Rails apps.**
HTTP API + JWT auth + Cloudflare Load Balancer integration + Server-Sent Events streaming.

Capfire runs _on_ each deploy node and exposes a small, authenticated HTTP surface that lets CI,
chatops, or a human with `curl` trigger deploys, rollbacks, restarts and status checks — and
watch them happen, line by line, in real time.

---

## Why

Running `bundle exec cap production deploy` from a laptop works until it doesn't: the connection
drops, you don't know who ran what, the node keeps serving traffic during deploys, and there's no
audit trail. Capfire fixes that with minimal ceremony:

- **JWT tokens with scoped permissions** (`apps`, `envs`, `cmds`) per caller
- **Cloudflare LB drain** before production deploys, auto-restore after (even on failure)
- **Live SSE output** — watch `cap deploy` stream into your terminal via plain `curl -N`
- **Persistent audit log** — every deploy is a row in Postgres with full output
- **Revocable tokens** — compromised key? `bin/capfire token revoke`, done

---

## Quick start

```bash
# 1. Install deps
bundle install

# 2. Configure
cp .env.example .env
$EDITOR .env            # set CAPFIRE_JWT_SECRET, DB, Cloudflare, apps root

# 3. Database
bin/rails db:create db:migrate

# 4. Issue your first token
bin/capfire token create \
  --name=ci-main \
  --apps='*' \
  --envs=staging,production \
  --cmds=deploy,restart,rollback,status

# copy the JWT that gets printed. Capfire will never show it again.

# 5. Boot the server
bin/rails server -p 3000

# 6. Trigger a deploy
curl -N -X POST http://localhost:3000/deploys \
  -H "Authorization: Bearer $CAPFIRE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"my-app","env":"staging","branch":"main"}'
```

---

## API

All endpoints require `Authorization: Bearer <jwt>`.

### `POST /deploys`

Starts a Capistrano deploy. Response is **text/event-stream** — one SSE event per log line plus a
terminal `done` event.

**Body**

```json
{ "app": "my-app", "env": "production", "branch": "main" }
```

**Response** (`Content-Type: text/event-stream`)

```
event: info
data: {"deploy_id":42,"app":"my-app","env":"production","branch":"main","command":"deploy","message":"starting deploy my-app@main -> production"}

event: info
data: {"message":"draining node from Cloudflare LB"}

event: log
data: {"line":"00:00 deploy:starting"}

event: log
data: {"line":"00:01 deploy:updating"}

event: info
data: {"message":"node restored to Cloudflare LB"}

event: done
data: {"deploy_id":42,"exit_code":0,"status":"success"}
```

**Errors** are emitted as `event: error` followed by a `done` event with a non-zero `exit_code`.

---

### `POST /commands`

Runs `restart`, `rollback` or `status`. Same SSE shape as `/deploys`.

**Body**

```json
{ "app": "my-app", "env": "production", "cmd": "rollback" }
```

Valid `cmd` values: `restart`, `rollback`, `status`.

---

### `GET /deploys/:id`

Fetch a deploy record (including full log) as JSON.

```json
{
  "id": 42,
  "app": "my-app",
  "env": "production",
  "branch": "main",
  "command": "deploy",
  "status": "success",
  "exit_code": 0,
  "triggered_by": "ci-main",
  "started_at": "2026-04-23T21:15:03Z",
  "finished_at": "2026-04-23T21:16:44Z",
  "duration_seconds": 101,
  "log": "00:00 deploy:starting\n..."
}
```

---

### `GET /healthz`

Unauthenticated liveness probe. Returns `200 ok`.

---

## Authorization

Each token carries three allowlists. A request must match **all three**:

| Claim | Meaning                          | Example                           |
|-------|----------------------------------|-----------------------------------|
| `apps` | Which apps the token can touch  | `["app-a", "app-b"]` or `["*"]`   |
| `envs` | Which environments              | `["staging"]`                     |
| `cmds` | Which commands                  | `["deploy", "restart"]`           |

`"*"` is the wildcard. It's valid only in `apps` (for multi-app admin tokens); `envs` and `cmds`
must list specific values.

Revoked tokens are rejected at decode time — both by jti lookup against the `revoked_tokens` table
and, if you set `exp`, by JWT's own expiry check.

### Token claims (full shape)

```json
{
  "sub": "ci-main",
  "jti": "a7b3c0f2-...",
  "apps": ["my-app"],
  "envs": ["staging", "production"],
  "cmds": ["deploy", "restart", "rollback", "status"],
  "iat": 1745432400,
  "exp": null
}
```

---

## CLI

The CLI runs inside the Rails environment (loads the same DB + secret as the server).

### Create a token

```bash
bin/capfire token create \
  --name=ci-staging \
  --apps=my-app,other-app \
  --envs=staging \
  --cmds=deploy,restart

# Non-expiring admin token (be careful):
bin/capfire token create --name=admin --apps='*' --envs=staging,production --cmds=deploy,restart,rollback,status

# Short-lived token:
bin/capfire token create --name=one-shot --apps=my-app --envs=staging --cmds=deploy --expires-in=24h
```

Supported `--expires-in` units: `s`, `m`, `h`, `d`.

### List tokens

```bash
bin/capfire token list
```

Prints id, name, jti, claims and state (`active` / `REVOKED`).

### Revoke a token

```bash
bin/capfire token revoke 3                      # by id
bin/capfire token revoke a7b3c0f2-...-...       # by jti
bin/capfire token revoke 3 --reason="leaked in slack"
```

Revocation is two-sided: flips `api_tokens.revoked_at` and inserts into `revoked_tokens` so the
next decode fails cleanly.

---

## Cloudflare Load Balancer

When `env` is `production` (or `prod`) and Cloudflare is configured, Capfire:

1. **Before** the deploy: sets this node's origin `enabled=false` in the pool.
2. **After** the deploy (success _or_ failure): sets `enabled=true`.

Configure via `.env`:

```
CF_API_TOKEN=...               # scoped: Zone:Load Balancers:Edit + Account:Load Balancers:Edit
CF_ACCOUNT_ID=...              # optional — required for account-scoped pools
CF_POOL_ID=...
CF_NODE_ORIGIN=10.0.0.10       # must match the `address` field of this node's origin in the pool
CF_DISABLE=false               # set true to skip all CF calls (handy in staging)
```

Capfire **mutates the existing origin entry** (flipping `enabled`) instead of deleting/recreating
it, so weights, health checks and virtual network attachments are preserved.

If you operate multiple Capfire nodes behind one pool, give each node its own `CF_NODE_ORIGIN`
pointing at the matching origin address — Capfire will only touch its own entry.

---

## App layout expectations

Capfire executes:

```bash
cd $CAPFIRE_APPS_ROOT/<app>
bundle exec cap <env> deploy BRANCH=<branch>
```

So for every app you deploy from this node you need:

- A working directory at `$CAPFIRE_APPS_ROOT/<app>` (default `/srv/apps/<app>`)
- A Capistrano setup inside it (`Capfile`, `config/deploy.rb`, `config/deploy/<env>.rb`)
- Capistrano's `BRANCH` variable wired into `set :branch, ENV['BRANCH'] || 'main'`

You can override a single app's path with:

```
CAPFIRE_APP_DIR_MY_APP=/opt/custom/path
```

(env var name is the app slug upper-cased, non-alphanumeric replaced with `_`).

---

## Architecture

```
POST /deploys         ┌──────────────────┐
  (JWT auth) ───────► │ DeploysController│
                      └─────────┬────────┘
                                │
                                ▼
                      ┌──────────────────┐     ┌──────────────────────┐
                      │  DeployService   │────►│ CloudflareLbService  │  (drain)
                      └─────────┬────────┘     └──────────────────────┘
                                │
                                ▼
                      ┌──────────────────┐
                      │ CapistranoRunner │  ── PTY.spawn('bundle exec cap ...')
                      └─────────┬────────┘
                                │ yields lines
                                ▼
                      ┌──────────────────┐
                      │    SseWriter     │  ── writes to response.stream
                      └──────────────────┘
                                │
                                ▼
                       Client (curl -N)
```

- **`DeploysController` / `CommandsController`** — thin, auth + param validation only
- **`DeployService`** — owns the lifecycle (DB record + LB drain/restore + runner + terminal event)
- **`CapistranoRunner`** — PTY spawn with Open3 fallback; yields raw log lines
- **`CloudflareLbService`** — Faraday + retries; fetches pool, flips `enabled`, puts it back
- **`JwtService`** — encode/decode + claim-based `authorize!`
- **`SseWriter`** — shields the controller from SSE formatting and closed-stream errors

Puma runs in **1 worker, many threads** — a deploy's in-memory stream lives inside one process,
so we don't want forks splitting connections. Worker timeout is bumped to 1h because real-world
deploys run long.

---

## Database

Three tables, all Postgres:

| Table            | Purpose                                                        |
|------------------|----------------------------------------------------------------|
| `deploys`        | One row per run. Holds app/env/branch, status, exit code, full log |
| `api_tokens`     | Metadata for every token Capfire has ever issued              |
| `revoked_tokens` | Fast lookup of revoked `jti`s during token decode             |

Logs live in `deploys.log` (TEXT). If that becomes too much, move to object storage — the
`append_log!` method is the only place that writes to it.

---

## Operational notes

- **SSE + nginx**: set `proxy_buffering off;` for Capfire's location block. Capfire already sends
  `X-Accel-Buffering: no` but some setups ignore it.
- **Log retention**: no built-in rotation. Add a cron to prune `deploys` older than N days if needed.
- **Concurrent deploys**: Capfire doesn't lock — two deploys of the same app/env will both run.
  Add a `before_action` lock in `DeploysController` if your Capistrano setup can't handle that.
- **Restarts mid-deploy**: an in-flight deploy that loses its controller (client disconnect) keeps
  running. It finishes in the background and the `deploys` row reflects the final state — fetch
  it with `GET /deploys/:id`.

---

## Development

```bash
bundle install
bin/rails db:create db:migrate RAILS_ENV=development
bin/rails server
```

Tests (once added) run with:

```bash
bundle exec rspec
```

---

## License

Proprietary — uDocz internal tooling.
