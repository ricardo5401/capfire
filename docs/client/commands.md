# Client commands

The developer CLI is `capfire`. Every command reads host + token from
`~/.config/capfire/config.yml` and talks HTTP to the server. SSE events
are rendered in real time with colors; async flows return a deploy id
you can track with `capfire status`.

All commands exit 0 on success, non-zero on failure — safe to wire into
shell scripts and CI.

| Command | Purpose |
|---|---|
| `capfire config` | Set or show your server + token |
| `capfire permission` | Inspect what your token is allowed to do |
| `capfire deploy APP ENV [BRANCH]` | Deploy an app (streaming by default) |
| `capfire restart APP ENV` | Restart an app |
| `capfire status [DEPLOY_ID]` | Show active deploys, or detail one |
| `capfire deployments` | List your recent deploys (filterable) |

Run `capfire <cmd> --help` for full flag reference.

---

## `capfire config`

Interactive prompts for host + token, saved to
`$XDG_CONFIG_HOME/capfire/config.yml` (mode 0600).

```bash
capfire config

# Non-interactive (CI / automation):
capfire config --host=https://capfire.example.com --token=eyJ...

# Where does the config live?
capfire config --show

# Custom location (useful for multiple Capfire servers):
CAPFIRE_CONFIG=~/.config/capfire/staging.yml capfire config
```

See [config file reference](config.md) for multi-server setups.

---

## `capfire permission`

Queries `GET /tokens/me` and prints the claims of your current token.

```bash
$ capfire permission
Host:     https://capfire.internal.udocz.com
Token:    admin
JTI:      6f3a08a7-2c34-4f8c-9b1e-1f2b6d1f11a0
Apps:     *
Envs:     production, staging
Cmds:     deploy, restart, rollback, status, drain, restore
Issued:   2026-04-24T15:10:30Z
Expires:  never
```

Aliases: `capfire whoami`, `capfire permissions`.

If the token is revoked, the command flags it loud and red — re-run
`capfire config` with a fresh token.

---

## `capfire deploy`

```
capfire deploy APP ENV [BRANCH] [--async] [--skip-lb]
```

Streaming mode (default): opens an SSE connection to `/deploys` and
renders each event live. Exit code matches the deploy's exit code.

```bash
capfire deploy udoczcom production master
capfire deploy udoczcom staging feature-branch
capfire deploy udoczcom production master --skip-lb
```

Async mode (`--async`): queues the deploy and returns immediately with a
deploy id and next-step hints.

```bash
$ capfire deploy udoczcom production master --async
✓ Deploy queued: #137 (accepted)
  app:    udoczcom
  env:    production
  branch: master

Track progress with:  capfire status 137
Tail the log with:    capfire status 137 --log
```

Flags:

| Flag | Purpose |
|---|---|
| `--async` | Return immediately, let Slack + `status` do the rest |
| `--skip-lb` | Don't drain the Cloudflare LB for this deploy |

Branch defaults to `main`.

### What gets executed server-side

The server resolves the deploy command from the app's `capfire.yml`
(falls back to `bundle exec cap %{env} deploy BRANCH=%{branch}`). Before
running, Capfire:

1. Drains the LB origin if configured.
2. `git fetch + checkout + reset --hard origin/<branch>` unless
   `git_sync: false`.
3. Runs `pre_deploy:` hooks in order.
4. Runs the deploy command, streaming stdout/stderr.
5. Restores the LB.
6. Posts to Slack (if enabled in `capfire.yml`).

See [per-app config](../server/config.md) for the full picture.

---

## `capfire restart`

```
capfire restart APP ENV [--async]
```

Runs the `restart` command for the app/env (whatever `capfire.yml`
resolves — typically `cap ENV deploy:restart`). No git sync, no
pre-deploy hooks, no LB drain.

```bash
capfire restart udoczcom production
capfire restart udoczcom staging --async
```

Rollback and status aren't exposed as top-level commands in the client
yet — use `capfire status DEPLOY_ID` to inspect, and the server admin
CLI for rollbacks if needed.

---

## `capfire status`

```
capfire status                         # list active deploys (yours)
capfire status DEPLOY_ID               # detail of one
capfire status DEPLOY_ID --log         # also print the log
capfire status DEPLOY_ID --log --tail=500
```

**Without arguments:** lists deploys you triggered that are `pending` or
`running`. Empty list is a friendly "No active deploys" message.

```
$ capfire status
ID   STATUS      APP       ENV         BRANCH  CMD      AGE     TOOK
137  ● running   udoczcom  production  master  deploy   12s ago 12s
```

**With a deploy id:** fetches the full deploy detail.

```
$ capfire status 137
Deploy:   #137
Status:   ✓ success
App:      udoczcom
Env:      production
Branch:   master
Command:  deploy
By:       admin
Started:  2026-04-24T15:11:00Z
Finish:   2026-04-24T15:13:42Z
Took:     2m42s
Exit:     0
```

Flags:

| Flag | Purpose |
|---|---|
| `--log` | Also print the captured log |
| `--tail N` | Only the last N lines (default 100; `0` prints all) |

---

## `capfire deployments`

Lists your recent deploys. Aliases: `capfire deploys`, `capfire list`.

```bash
capfire deployments
capfire deployments --app=udoczcom --limit=50
capfire deployments --env=production --status=failed
```

Flags:

| Flag | Purpose |
|---|---|
| `--app NAME` | Only deploys for this app |
| `--env NAME` | Only deploys for this env |
| `--status X` | `pending` / `running` / `success` / `failed` / `canceled` |
| `--limit N` | Rows to return (default 20, server caps at 100) |

The list is always **your own** deploys (filtered by the `sub` claim of
your token). You cannot see deploys of other users through the client.

---

## Global flags

`--help` and `--version` are available everywhere.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Any failure (deploy non-zero exit, HTTP error, config issue) |

The client does not use distinct exit codes for different failure
classes — rely on stderr output and (for async) `capfire status DEPLOY_ID`
to diagnose.
