# AGENTS.md — Capfire

Instructions for AI agents working on this repo.

## What this is

Capfire is a **Rails 7.1 API-only** deploy orchestrator. Each node runs one instance. Calls are
authenticated JWTs. Deploys stream output via SSE.

## Non-negotiable rules

1. **No direct pushes to `master`.** Always branch + PR.
2. **No secrets in code.** Everything via `ENV` (loaded by `dotenv-rails`).
3. **Controllers stay thin.** Auth + param check + delegate to a service. No business logic.
4. **Services own lifecycle.** `DeployService` orchestrates; `CommandRunner`, `CloudflareLbService`,
   `AppConfig`, `JwtService` each handle one concern.
5. **SSE is the only streaming transport.** Don't add WebSockets.
6. **Run RuboCop before commit.** Omakase config (`rubocop-rails-omakase`).
7. **Deploy commands are per-app.** What a deploy/restart/rollback actually runs is resolved by
   `AppConfig` from the app's `capfire.yml`. Don't hardcode stacks or frameworks into Capfire.

## Where to add things

| You want to...                               | Edit                                                      |
|----------------------------------------------|-----------------------------------------------------------|
| Add a new command (beyond restart/rollback…) | `AppConfig::DEFAULT_COMMANDS` + `CommandsController::ALLOWED` |
| Change JWT claim shape                       | `JwtService` (encode + authorize!) + `tokens_command.rb`  |
| Change LB behavior                           | `CloudflareLbService`                                     |
| Change per-app config schema                 | `AppConfig` + document in `README.md`                     |
| Add a new endpoint                           | `config/routes.rb` + a new thin controller                |
| Add a CLI subcommand                         | `lib/capfire_cli/` + register in `Main`                   |

## Per-app config (`capfire.yml`)

Each app's working directory may contain a `capfire.yml` that overrides defaults. All sections
are optional:

```yaml
commands:
  deploy:   "bundle exec cap %{env} deploy BRANCH=%{branch}"
  restart:  "bundle exec cap %{env} puma:restart"

environments:
  production:
    load_balancer:
      pool_id: "..."
      account_id: "..."      # optional
      origin: "35.185.55.232"
  staging:
    load_balancer:
      enabled: false

git_sync: false              # opt out of auto git sync (default: true)
```

Placeholders in command strings: `%{app}`, `%{env}`, `%{branch}`.

If a key is missing, the default from `AppConfig::DEFAULT_COMMANDS` applies. Apps without a
`capfire.yml` keep behaving exactly like a vanilla Capistrano deploy — no migration required.

### Auto git sync

Before running a `deploy` command, `CommandRunner` prepends:

```
git fetch --prune origin && git checkout <branch> && git reset --hard origin/<branch>
```

This ensures the cockpit is on the exact commit being deployed (matters for apps that do
local asset precompile from the cockpit). Skipped for `restart`, `rollback`, `status`. Opt out
per-app via `git_sync: false` in `capfire.yml`.

## Style

- Single quotes for strings unless interpolation needed.
- Keyword args for services (`DeployService.new(app:, env:, ...)`).
- Frozen hashes for static config (see `AppConfig::DEFAULT_COMMANDS`).
- Log via `Rails.logger` — one tag per subsystem (`[deploy]`, `[cloudflare]`, `[runner]`, `[lb#...]`).
- Don't rescue `Exception`. Rescue `StandardError` or a specific class.

## Testing approach (when adding tests)

- Unit: mock `Faraday::Connection` for `CloudflareLbService`, stub `CommandRunner` in
  `DeployService` specs. For `AppConfig`, write to `tmp/capfire_yml` fixtures.
- Controller: request specs hit `/deploys` or `/lb/drain` with a signed token via
  `JwtService.encode`.
- Full stack: don't — integration against a real Capistrano app belongs in the app's CI, not here.
