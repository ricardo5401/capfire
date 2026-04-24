# Server configuration

Two levels of configuration:

1. **Server-wide**: `/etc/capfire/env`, loaded by systemd. Controls the
   server process itself (DB, JWT secret, default paths).
2. **Per-app**: `capfire.yml` at the root of each app under
   `$CAPFIRE_APPS_ROOT/<app>`. Controls what "deploy" means for that app.

## Server-wide (`/etc/capfire/env`)

Rendered by `scripts/install-server.sh` from
[`scripts/templates/env.example`](../../scripts/templates/env.example).

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `RAILS_ENV` | yes | — | Always `production` on deploy hosts |
| `CAPFIRE_JWT_SECRET` | yes | — | HMAC secret used to sign every token |
| `DATABASE_URL` | yes | — | Postgres connection string |
| `CAPFIRE_APPS_ROOT` | no | `/srv/apps` | Where `project add` drops apps |
| `CAPFIRE_ALLOWED_APPS` | no | empty | Comma-separated allowlist; empty means any |
| `CAPFIRE_PUBLIC_URL` | no | `request.base_url` | Used in async deploy track URLs |
| `CF_API_TOKEN` | no | — | Cloudflare API token for LB operations |
| `SLACK_WEBHOOK_URL` | no | — | Default Slack webhook (override per app) |
| `RAILS_MAX_THREADS` | no | `16` | Puma max threads |
| `PORT` | no | `3000` | Listen port |

Rotating `CAPFIRE_JWT_SECRET` invalidates **every** token emitted with the
old secret. Prefer `capfire tokens revoke` for individual tokens.

Inspect current state with `capfire config` (secrets masked).

## Per-app (`capfire.yml`)

Every app under `$CAPFIRE_APPS_ROOT/<name>` *may* contain a `capfire.yml` at
its root. Every section is optional — an empty file (or no file at all)
keeps the Capistrano defaults.

### Full example

```yaml
# /srv/apps/myapp/capfire.yml

# Global command overrides. Placeholders: %{app}, %{env}, %{branch}.
commands:
  deploy:   "bundle exec cap %{env} deploy BRANCH=%{branch}"
  restart:  "bundle exec cap %{env} puma:restart"
  rollback: "bundle exec cap %{env} deploy:rollback"
  status:   "bundle exec cap %{env} deploy:check"

# Per-environment settings.
environments:
  production:
    commands:                              # optional per-env command overrides
      restart: "bundle exec cap production puma:phased_restart"
    load_balancer:
      pool_id:    "3c9c314b8ddf22a48c1d80496242777c"
      account_id: "7fd8c19b6d672b6c7e11b83e5f48096d"   # optional, account-scoped pools
      origin:     "35.185.55.232"                       # IP of THIS node in the pool
    link: "https://app.example.com"                       # shown as "Open" button in Slack
  staging:
    load_balancer:
      enabled: false                                    # also the default when block absent
    link: "https://staging.example.com"

# Opt out of the auto git fetch+checkout+reset before every deploy.
# Default: true — applies only to the `deploy` command.
# git_sync: false

# Shell commands to run BEFORE the deploy command (after git sync).
pre_deploy:
  - "bundle install --jobs 4 --retry 2"
  - "yarn install --frozen-lockfile"

# Slack notifications on deploy completion (success or failure).
slack:
  enabled: true
  # webhook_env: SLACK_WEBHOOK_MYAPP                # override default env var
```

### Defaults (when `capfire.yml` is absent or a key is missing)

```
deploy   -> bundle exec cap %{env} deploy BRANCH=%{branch}
restart  -> bundle exec cap %{env} deploy:restart
rollback -> bundle exec cap %{env} deploy:rollback
status   -> bundle exec cap %{env} deploy:check
```

Restart/rollback/status always skip both git sync and pre-deploy hooks.

### Placeholders

Valid inside any command string:

| Placeholder | Value |
|---|---|
| `%{app}` | app slug passed to the endpoint |
| `%{env}` | env name (`production`, `staging`, …) |
| `%{branch}` | branch from the deploy request |

### Git sync (deploy-only)

Before every `deploy` command, Capfire runs inside the app's working directory:

```
git fetch --prune origin
git checkout <branch>
git reset --hard origin/<branch>
```

This guarantees the cockpit sits on the exact commit you asked for —
critical when the app precompiles assets locally from the cockpit (e.g.
`myapp`). Restart/rollback/status skip the sync.

Opt out per app with `git_sync: false` — useful when:

- The app is not a git repo.
- You deploy from tags and need manual checkout inside the `deploy` command.
- Your deploy tool already handles the checkout.

> Note: `git reset --hard origin/<ref>` assumes `<ref>` is a branch. For
> tag deploys, disable `git_sync` and check out the tag yourself inside
> the `deploy` command.

### Pre-deploy hooks

After git sync and before the deploy command, the `pre_deploy` list runs
in order, chained with `&&`. Any failure aborts the deploy.

Typical uses:

- Refresh gems when `Gemfile.lock` changed: `bundle install`
- Refresh `node_modules` when lockfiles changed: `yarn install`
- Generate lockfiles, warm caches, run data migrations.

Pre-deploy hooks apply **only to the `deploy` command** — not to restart,
rollback, or status.

### Slack notifications

When `slack.enabled: true`, Capfire posts to a Slack webhook after every
deploy (success or failure). Setup:

1. Put `SLACK_WEBHOOK_URL=https://hooks.slack.com/...` in `/etc/capfire/env`.
2. Enable it per app that should notify:
   ```yaml
   slack:
     enabled: true
   environments:
     production:
       link: "https://app.example.com"
     staging:
       link: "https://staging.example.com"
   ```

The `link` per env is optional — when set it shows up as an "Open app"
primary button in the message.

Message format uses Slack Block Kit with `attachments` so you get a colored
bar (green / red), a header with emoji, a 2-column grid with
App/Env/Branch/Author, and the "Open" button. Failures add a code block
with the reason.

The author line comes from the JWT's `sub` claim (the `--name` you gave
the token). Slack notifications run only for `deploy` — not for
restart/rollback/status — and they fail silently (a Slack outage never
aborts a deploy).

For per-app routing into different channels, create multiple webhooks and
differentiate with `webhook_env`:

```yaml
# /srv/apps/myapp/capfire.yml
slack:
  enabled: true
  webhook_env: SLACK_WEBHOOK_MYAPP

# /srv/apps/myapp-api/capfire.yml
slack:
  enabled: true
  webhook_env: SLACK_WEBHOOK_MYAPP_API
```

And in `/etc/capfire/env`:

```
SLACK_WEBHOOK_MYAPP=https://hooks.slack.com/services/.../a
SLACK_WEBHOOK_MYAPP_API=https://hooks.slack.com/services/.../b
```

### Load balancer (Cloudflare)

Capfire can drain this node out of a Cloudflare LB pool before the deploy
and restore it afterwards. Add per env:

```yaml
environments:
  production:
    load_balancer:
      pool_id:    "<pool-uuid>"
      account_id: "<account-uuid>"   # optional, for account-scoped pools
      origin:     "<this-node-ip>"   # must match the origin entry in the pool
```

Rules:

- Only Cloudflare LBs are supported.
- Drain happens on `deploy` only — never on restart/rollback/status.
- `CF_API_TOKEN` in `/etc/capfire/env` is the only Cloudflare global.
- `pool_id`, `account_id`, `origin` live per-app in `capfire.yml` so a single
  Capfire node can serve multiple apps with different LB topologies.
- Missing `load_balancer` block or `enabled: false` means no LB interaction.

See also:
- [Non-Ruby apps](non-ruby-apps.md)
- [HTTP API](api.md)

### Override cockpit location (advanced)

By default, Capfire resolves an app's working directory to
`$CAPFIRE_APPS_ROOT/<app>`. Override for one app with an env var:

```
# /etc/capfire/env
CAPFIRE_APP_DIR_MYAPP=/opt/custom/path/myapp
```

The var name is `CAPFIRE_APP_DIR_<APP>` with the app name upcased and
non-alphanumeric chars replaced by `_`. Useful when a host manages apps
from multiple disk pools.
