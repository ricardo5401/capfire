# AGENTS.md — Capfire

Instructions for AI agents working on this repo.

## What this is

Capfire is a **Rails 7.1 API-only** deploy orchestrator. Each node runs one instance. Calls are
authenticated JWTs. Deploys stream output via SSE.

## Non-negotiable rules

1. **No direct pushes to `master`.** Always branch + PR.
2. **No secrets in code.** Everything via `ENV` (loaded by `dotenv-rails`).
3. **Controllers stay thin.** Auth + param check + delegate to a service. No business logic.
4. **Services own lifecycle.** `DeployService` orchestrates; `CapistranoRunner`, `CloudflareLbService`,
   `JwtService` each handle one concern.
5. **SSE is the only streaming transport.** Don't add WebSockets.
6. **Run RuboCop before commit.** Omakase config (`rubocop-rails-omakase`).

## Where to add things

| You want to...                               | Edit                                                      |
|----------------------------------------------|-----------------------------------------------------------|
| Add a new command (beyond restart/rollback…) | `CapistranoRunner::COMMAND_TEMPLATES` + `CommandsController::ALLOWED` |
| Change JWT claim shape                       | `JwtService` (encode + authorize!) + `tokens_command.rb`  |
| Change LB behavior                           | `CloudflareLbService`                                     |
| Add a new endpoint                           | `config/routes.rb` + a new thin controller                |
| Add a CLI subcommand                         | `lib/capfire_cli/` + register in `Main`                   |

## Style

- Single quotes for strings unless interpolation needed.
- Keyword args for services (`DeployService.new(app:, env:, ...)`).
- Frozen hashes for static config (see `CapistranoRunner::COMMAND_TEMPLATES`).
- Log via `Rails.logger` — one tag per subsystem (`[deploy]`, `[cloudflare]`, `[capistrano]`).
- Don't rescue `Exception`. Rescue `StandardError` or a specific class.

## Testing approach (when adding tests)

- Unit: mock `Faraday::Connection` for `CloudflareLbService`, stub `CapistranoRunner` in
  `DeployService` specs.
- Controller: request specs hit `/deploys` with a signed token via `JwtService.encode`.
- Full stack: don't — integration against a real Capistrano app belongs in the app's CI, not here.
