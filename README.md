# Capfire 🔥

> A small JWT-authenticated deploy orchestrator with two pieces: a Rails
> server running on each deploy host, and a tiny Go CLI developers run
> from their laptops.

## Why Capfire

Shipping a new version of a Rails app through Capistrano is simple when
one engineer SSHes into the cockpit and types `cap production deploy`.
It stops being simple when:

- Five people on the team need to deploy the same apps.
- Deploys run from GitHub Actions and must be auditable.
- The node sits behind a Cloudflare load balancer that must drain
  before each push and restore after.
- Some apps are Capistrano, some are Node/PM2, some are Go binaries
  behind systemd.

Capfire is the smallest thing that fixes that:

- **Deploy hosts** run a Rails server (`capfire.service`) exposing an
  HTTPS API. Each endpoint is authenticated with a JWT bearer token
  carrying explicit per-action claims (`apps`, `envs`, `cmds`).
- **Developers** run the `capfire` Go CLI. It streams live deploy logs
  over SSE, supports async mode with Slack notifications, and pulls
  token permissions with a single command.
- **GitHub Actions / CI** keeps using plain `curl` against the same HTTP
  API with a scoped JWT.
- Per-app `capfire.yml` files declare what "deploy" means: any shell
  command, Capistrano or not.

Opinionated in all the right places, thin everywhere else.

## Quick start

Server (on the deploy host):

```bash
git clone git@github.com:ricardo5401/capfire.git
cd capfire
sudo ./scripts/install-server.sh \
  --database-url='postgres://capfire:pass@localhost/capfire_production'
sudo -u capfire capfire tokens create --name=me --grant='*:*:*'
```

Client (on your laptop):

```bash
git clone git@github.com:ricardo5401/capfire.git
cd capfire
sudo ./scripts/install-client.sh
capfire config         # prompts for host + token
capfire permission     # confirm what you can do
capfire deploy myapp production master
```

## Documentation

### Server (deploy host)

- **[Setup](docs/server/setup.md)** — installer, Nginx SSE config, manual install, uninstall.
- **[Admin CLI](docs/server/commands.md)** — `bin/capfire tokens / project / service / config`.
- **[Configuration](docs/server/config.md)** — `/etc/capfire/env` and per-app `capfire.yml`.
- **[Non-Ruby apps](docs/server/non-ruby-apps.md)** — deploy Node/Python/Go/PHP/static sites.
- **[HTTP API](docs/server/api.md)** — every endpoint, SSE events, GitHub Actions example.
- **[Security](docs/server/security.md)** — threat model, JWT hygiene, production checklist.
- **[Architecture](docs/server/architecture.md)** — services, DB, ops notes.

### Client (developer laptop)

- **[Setup](docs/client/setup.md)** — install, update, uninstall.
- **[Commands](docs/client/commands.md)** — `capfire deploy / restart / status / deployments / permission / config`.
- **[Configuration](docs/client/config.md)** — config file, multiple servers, CI usage.

## Repository layout

```
capfire/
├── app/ config/ db/ lib/    # Rails server
├── bin/capfire              # Admin CLI (Ruby/Thor) — runs on the server
├── client/                  # Developer CLI (Go/Cobra) — separate module
├── docs/                    # Split server/client documentation
├── scripts/
│   ├── install-server.sh
│   ├── install-client.sh
│   ├── uninstall-server.sh
│   └── templates/           # systemd unit + env template
└── AGENTS.md                # Conventions for contributors (and AI agents)
```

## Local development

Set up the server locally against a disposable DB:

```bash
bundle install
cp .env.example .env                          # drop in DB + JWT secret
bin/rails db:prepare
bin/rails server -p 3000

RAILS_ENV=development bin/capfire tokens create \
  --name=local --grant='*:staging:deploy,restart,rollback,status'
```

Build and run the Go client against it:

```bash
cd client
go build -o /tmp/capfire .
CAPFIRE_CONFIG=/tmp/capfire.yml /tmp/capfire config \
  --host=http://localhost:3000 --token=<the JWT from above>
CAPFIRE_CONFIG=/tmp/capfire.yml /tmp/capfire permission
```

Tests (server):

```bash
bundle exec rspec       # once specs are added
bundle exec rubocop     # Omakase config + single_quotes + frozen_string_literal
```

Tests (client):

```bash
cd client
go vet ./...
gofmt -l .              # must print nothing
```

## License

MIT.
