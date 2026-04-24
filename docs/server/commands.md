# Server admin CLI

`bin/capfire` is the admin-facing CLI that ships with the server. It runs
inside the Capfire Rails environment (same DB, same JWT secret), so every
command must execute on the server, as the `capfire` user:

```bash
sudo -u capfire capfire <command>
# Equivalent to:
sudo -u capfire bash -lc 'cd /opt/capfire && RAILS_ENV=production bundle exec bin/capfire <command>'
```

The install script symlinks `/usr/local/bin/capfire → /opt/capfire/bin/capfire`
so the short form works out of the box.

> **Not the developer CLI.** The Go client (`capfire deploy`,
> `capfire restart`, …) is a separate binary installed on your laptop. See
> [client commands](../client/commands.md).

## Command summary

| Command | What it does |
|---|---|
| `capfire tokens create` | Create and sign a new API token |
| `capfire tokens list` | List tokens known to this instance |
| `capfire tokens revoke ID` | Revoke a token by numeric id or jti |
| `capfire project add URL` | Clone a git repo into `$CAPFIRE_APPS_ROOT` |
| `capfire project list` | List apps registered under the apps root |
| `capfire service restart` | `systemctl restart capfire.service` |
| `capfire service status` | `systemctl status capfire.service` |
| `capfire service logs` | `journalctl -u capfire -fn 200` |
| `capfire restart` | Alias for `service restart` |
| `capfire status` | Alias for `service status` |
| `capfire config` | Print env-var diagnostics (masked secrets) |
| `capfire server-config` | Alias for `capfire config` |
| `capfire version` | Print the Capfire version |

Run `capfire help <command>` for the built-in Thor help of any subcommand.

---

## `capfire tokens`

### `tokens create`

Signs a JWT and records its metadata in the `api_tokens` table. Prints the
token once on stdout — copy it now, Capfire does not store the JWT itself.

```bash
# Admin token — any app, any env, every command.
capfire tokens create \
  --name=admin \
  --apps='*' \
  --envs=staging,production \
  --cmds=deploy,restart,rollback,status,drain,restore

# Scoped token for GitHub Actions deploying only udoczcom staging.
capfire tokens create \
  --name=gh-actions-staging \
  --apps=udoczcom \
  --envs=staging \
  --cmds=deploy

# Short-lived token for a pipeline (hours/days supported).
capfire tokens create \
  --name=one-shot \
  --apps=udoczcom \
  --envs=staging \
  --cmds=deploy \
  --expires-in=24h
```

`--expires-in` accepts suffixes `s`, `m`, `h`, `d`. Omit it for
non-expiring tokens (recommended only for human admin tokens).

### `tokens list`

```bash
capfire tokens list
```

Shows id, name, apps/envs/cmds, issued/expires, and whether the token is
revoked. Does not reveal secrets.

### `tokens revoke`

```bash
capfire tokens revoke 12
capfire tokens revoke d9ae2c5a-3d28-4e29-a5c0-5f7c3e4e9a23   # by jti
```

Revocation is immediate: the `jti` is written to `revoked_tokens` and every
subsequent decode rejects it. Prefer revocation over rotating the global
JWT secret — rotating invalidates *every* outstanding token.

---

## `capfire project`

### `project add URL`

Clones a repo into `$CAPFIRE_APPS_ROOT/<name>` so this node can deploy it.
Only runs `git clone` — no `bundle install`, no `capistrano setup`. The app
owns its own deploy scripts; Capfire just orchestrates.

```bash
capfire project add git@github.com:uDocz/udoczcom.git
capfire project add https://github.com/uDocz/udoczcom.git --name=udocz
capfire project add git@github.com:uDocz/udoczcom.git --branch=production
```

The name is derived from the URL (`udoczcom` from
`git@github.com:uDocz/udoczcom.git`) unless `--name` overrides it. If the
target directory already exists, the command aborts instead of re-cloning.

### `project list`

Lists every app under `$CAPFIRE_APPS_ROOT`, with a column showing whether
each has a `capfire.yml` at its root.

---

## `capfire service`

Thin wrappers around `systemctl` for the `capfire.service` unit. Run them
from any shell on the box — they invoke `sudo` internally.

```bash
capfire service restart           # sudo systemctl restart capfire
capfire service status            # sudo systemctl status capfire
capfire service logs              # journalctl -u capfire -f -n 200
capfire service logs --lines=500  # bigger tail window
capfire service logs --no-follow  # one-shot
capfire service restart --unit=capfire-staging.service   # different unit
```

`capfire restart` and `capfire status` (without subcommand) are shortcuts
for `capfire service restart` / `capfire service status`.

---

## `capfire config`

Prints a diagnostic of every environment variable Capfire consumes. Values
marked `[set]` are secrets that are present but intentionally not printed;
`[--]` means unset.

```
$ capfire config
Capfire server configuration
  apps_root: /srv/apps
  vars:
    CAPFIRE_JWT_SECRET       [OK]  [set]
                             └─ HMAC secret used to sign API tokens
    CAPFIRE_APPS_ROOT        [OK]  /srv/apps
                             └─ Directory where app checkouts live
    CF_API_TOKEN             [--]  (unset)
                             └─ Cloudflare API token for LB drain/restore
    ...
```

Required-in-prod variables (`CAPFIRE_JWT_SECRET`, `DATABASE_URL`) are
called out in a "Missing required vars" block if blank. Edit
`/etc/capfire/env` to change them — the CLI does not rewrite the file.

---

## JWT claim shape

Every token carries the same claim set:

```json
{
  "sub":  "admin",
  "jti":  "6f3a08a7-2c34-4f8c-9b1e-1f2b6d1f11a0",
  "apps": ["*"],
  "envs": ["production", "staging"],
  "cmds": ["deploy", "restart", "rollback", "status"],
  "iat":  1712500000,
  "exp":  1715092000
}
```

The wildcard `*` in `apps`, `envs` or `cmds` grants access to every value.
Keep wildcards for admin and human tokens only — CI and automation tokens
should enumerate exactly what they can touch.
