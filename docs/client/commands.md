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
| `capfire run APP ENV TASK` | Run a custom task (sync, reindex, backfill, …) |
| `capfire status [DEPLOY_ID]` | Show active deploys, or detail one |
| `capfire task [TASK_RUN_ID]` | Show active tasks, or detail one |
| `capfire deployments` | List recent deploys (yours by default; `--all` for the team's) |
| `capfire abort deploy ID` | Cancel a running deploy |
| `capfire abort task ID` | Cancel a running task |

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
Host:     https://capfire.internal.example.com
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
capfire deploy myapp production master
capfire deploy myapp staging feature-branch
capfire deploy myapp production master --skip-lb
```

Async mode (`--async`): queues the deploy and returns immediately with a
deploy id and next-step hints.

```bash
$ capfire deploy myapp production master --async
✓ Deploy queued: #137 (accepted)
  app:    myapp
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
capfire restart myapp production
capfire restart myapp staging --async
```

Rollback and status aren't exposed as top-level commands in the client
yet — use `capfire status DEPLOY_ID` to inspect, and the server admin
CLI for rollbacks if needed.

---

## `capfire run`

Triggers a **task** on the server. Tasks are user-defined commands declared
under `tasks:` in the app's `capfire.yml`, plus the reserved built-in
`sync` (git fetch + reset --hard origin/&lt;branch&gt;, then optional
`tasks.sync.after:` hooks).

```
capfire run APP ENV TASK [--branch X] [--arg key=value]... [--async] [--wait]
```

Streaming mode (default): SSE connection to `/tasks`, exit code matches the
task's exit code. Async mode: 202 + track URL, polling left to the caller.

```bash
# Pull fresh code + run `uv sync` (whatever the app declares under sync.after)
capfire run pyworker production sync --branch master

# Reindex with no params
capfire run pyworker production reindex

# Backfill with required params
capfire run pyworker production backfill --arg since=2024-01-01

# Multiple params + async
capfire run pyworker production recompute_kpis \
  --arg month=2024-04 --arg tenant=acme --async

# Wait for the per-app lock to free instead of failing on 409
capfire run pyworker production reindex --wait --wait-timeout 30m
```

Flags:

| Flag | Default | Purpose |
|---|---|---|
| `--branch X` | `main` | Branch used by `sync` and any `%{branch}` placeholder |
| `--arg key=value` | — | Repeatable. Maps to a `params:` key declared in yaml |
| `--async` | `false` | Return 202 immediately instead of streaming logs |
| `--wait` | `false` | On 409 Conflict, poll the lock and retry until free |
| `--wait-timeout 30m` | `30m` | Maximum wait when `--wait` is set (`0` = forever) |
| `--wait-interval 30s` | server hint | Override the polling interval |

Concurrency model:

- At most one task runs per app at a time. A second concurrent request
  returns `409 Conflict` with the in-flight task's metadata.
- The reserved `sync` task additionally returns `409 Conflict` if a deploy
  is currently running on the same app — both rewrite the working dir and
  cannot coexist.
- Non-sync tasks **can** run alongside a deploy of the same app. This is
  intentional: a long backfill must not block a hotfix.

When the server returns 409 with `--wait`, the CLI prints what's blocking
and the next retry interval, then sleeps and retries. Ctrl+C aborts.

```
$ capfire run pyworker production reindex --wait
⚠ Task #87 (backfill by ana, started 12m ago) is in progress — waiting 60s
⚠ Task #87 (backfill by ana, started 13m ago) is in progress — waiting 60s
ℹ Running task=reindex on pyworker/production …
[task output streaming here]
✓ Task finished successfully
```

A token needs `cmd: "task:<name>"` (or the `tasks:` shorthand on the
grant) to be allowed. See [server config → tasks](../server/config.md#tasks)
for the yaml schema and [HTTP API → Tasks](../server/api.md#tasks) for the
full request/response shapes.

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
137  ● running   myapp  production  master  deploy   12s ago 12s
```

**With a deploy id:** fetches the full deploy detail.

```
$ capfire status 137
Deploy:   #137
Status:   ✓ success
App:      myapp
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

Lists deploys associated with your token. Aliases: `capfire deploys`,
`capfire list`.

By default, shows **only what you triggered** (matched on the JWT `sub`
claim). With `--all`, expands the scope to **every deploy on apps you
have any permission on** — that's the right flag for "what is my
teammate deploying right now". The same visibility rule extends to
`capfire status ID` and `capfire abort deploy ID`: anything you can see
in this list, you can also inspect or abort (subject to the abort
permission rules).

When you run without `--all`, the server includes a hint reminding you
the flag exists. The hint is silenced once you opt in.

```bash
# Yours
capfire deployments
capfire deployments --app=myapp --limit=50
capfire deployments --env=production --status=failed

# The team's
capfire deployments --all
capfire deployments --all --app=udoczcom --status=running
```

Flags:

| Flag | Purpose |
|---|---|
| `--all` | Show deploys from every app you have access to |
| `--app NAME` | Only deploys for this app |
| `--env NAME` | Only deploys for this env |
| `--status X` | `pending` / `running` / `success` / `failed` / `canceled` |
| `--limit N` | Rows to return (default 20, server caps at 100) |

---

## `capfire abort`

Cancels a running deploy or task. Picks the right kind explicitly because
deploy IDs and task-run IDs share a numeric space — `capfire abort 42`
would be ambiguous.

```bash
capfire abort deploy 137
capfire abort task 87
capfire abort deploy 137 --reason "wrong branch"
```

The server signals the run's process group with SIGTERM, waits 10
seconds, then escalates to SIGKILL if the process is still alive. The
record transitions to `canceled` regardless of whether a process was
actually running (orphan locks from a Puma restart are cleared the same
way).

Output reflects what happened on the OS side:

```
$ capfire abort deploy 137
✓ Deploy #137 canceled (myapp/production deploy)
  exit code: 143 (SIGTERM — process exited cleanly within grace period)

$ capfire abort task 87
✓ Task #87 canceled (pyworker/production reindex)
  exit code: 137 (SIGKILL — had to force-kill after grace period)

$ capfire abort deploy 138        # already finished
⚠ Deploy #138 was already success — nothing to abort

$ capfire abort task 90           # orphan lock
✓ Task #90 canceled (pyworker/production backfill)
  exit code: -1 (no live process — orphan lock cleared)
```

Permissions:

- You can ALWAYS abort runs you triggered yourself, no special grant
  needed.
- To abort someone else's run, your token needs `cmd: "abort"` on the
  run's app+env (or the global `*` wildcard).
- If the JWT auth itself is the problem, the server admin can abort
  locally via `bin/capfire abort deploy ID` (bypasses JWT entirely).

Flags:

| Flag | Purpose |
|---|---|
| `--reason TEXT` | Optional. Appended to the run's audit log line |

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
