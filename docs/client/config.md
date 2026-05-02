# Client configuration

Capfire's client stores a single tiny YAML file with your server URL and
bearer token. Everything else is command-line flags or server-side.

## File location

Resolved in this order (first match wins):

1. `$CAPFIRE_CONFIG` — absolute path override.
2. `$XDG_CONFIG_HOME/capfire/config.yml`
3. `$HOME/.config/capfire/config.yml`

Check your resolved path with `capfire config --show`.

## Format

```yaml
# ~/.config/capfire/config.yml
host: https://capfire.internal.example.com
token: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhZG1pbiIsImp0aSI6...

# Optional. When false, skip the "is there a new release?" notice that
# normally appears at the end of every command. Defaults to true.
update_check: true
```

The `host` and `token` fields are required. `update_check` is optional
and defaults to enabled. The file is written with mode `0600` because
it contains a bearer token — keep it that way.

## Environment variables

| Variable | Purpose |
|---|---|
| `CAPFIRE_CONFIG` | Override the resolved config path (highest precedence) |
| `XDG_CONFIG_HOME` | Base dir per XDG spec; defaults to `~/.config` |
| `XDG_CACHE_HOME` | Base dir for the version-check cache; defaults to `~/.cache` |
| `CAPFIRE_CACHE_DIR` | Override the version-check cache directory directly |
| `CAPFIRE_DISABLE_UPDATE_CHECK` | When `1`/`true`/`yes`/`on`, disables the version check entirely (overrides config) |

## Update check

After every command, capfire prints a one-line notice on stderr if a
newer release is available on GitHub. The check is cached on disk for
24 hours and runs in the background — the first invocation may add up
to ~1s at exit while it fetches; subsequent calls are essentially free.

Opt out three ways:

1. Per-config:
   ```yaml
   update_check: false
   ```
2. Per-shell:
   ```bash
   export CAPFIRE_DISABLE_UPDATE_CHECK=1
   ```
3. Dev builds (binaries built from source without `-ldflags`) skip the
   check automatically — no contributor sees "update available" while
   hacking on the client.

Force a synchronous check (bypass the 24h cache):

```bash
capfire version --check
```

The cache lives at `~/.cache/capfire/version-check.json`. Delete it to
force the next run to refresh.

## Multiple servers

Common case: you deploy to a staging node and a production node that are
separate Capfire instances (different DBs, different tokens). Keep one
config per server and switch via `CAPFIRE_CONFIG`.

```bash
# ~/.bashrc (or shell equivalent)
capfire-staging()    { CAPFIRE_CONFIG=~/.config/capfire/staging.yml    capfire "$@"; }
capfire-production() { CAPFIRE_CONFIG=~/.config/capfire/production.yml capfire "$@"; }
```

Setup once:

```bash
CAPFIRE_CONFIG=~/.config/capfire/staging.yml \
  capfire config --host=https://staging-capfire.example.com --token=<staging-jwt>

CAPFIRE_CONFIG=~/.config/capfire/production.yml \
  capfire config --host=https://prod-capfire.example.com --token=<prod-jwt>
```

Then:

```bash
capfire-staging deploy myapp staging master
capfire-production deploy myapp production master
```

## Using the client in CI without a file

Drop the file step, pipe the token in from a secret:

```yaml
# .github/workflows/deploy.yml
- name: Deploy
  env:
    CAPFIRE_HOST: ${{ secrets.CAPFIRE_HOST }}
    CAPFIRE_TOKEN: ${{ secrets.CAPFIRE_TOKEN }}
  run: |
    mkdir -p "$HOME/.config/capfire"
    cat > "$HOME/.config/capfire/config.yml" <<EOF
    host: $CAPFIRE_HOST
    token: $CAPFIRE_TOKEN
    EOF
    chmod 0600 "$HOME/.config/capfire/config.yml"
    capfire deploy myapp staging "$GITHUB_REF_NAME"
```

Or skip the file entirely and pass flags inline through a wrapper (we
don't yet support `--host`/`--token` global flags; if you need this, use
the bare HTTP API from [server API reference](../server/api.md)).

## Security notes

- Treat `~/.config/capfire/config.yml` like `~/.ssh/id_rsa`. Losing it =
  losing your deploy credentials.
- The token is a JWT — anyone who holds it can deploy whatever its
  claims allow until it expires or is revoked.
- Ask your admin for short-lived tokens (`--expires-in=24h`) when you
  work off a laptop you don't fully trust.
- `capfire permission` tells you exactly what your token can do — run
  it before asking "why can't I deploy to production?".
