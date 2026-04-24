# Contributing

Thanks for looking. Capfire is intentionally small and opinionated — the
easiest contribution is filing an issue with a clear reproduction before
writing code.

## Before opening a PR

1. Open an issue describing the problem or feature, unless it's a trivial
   fix (typo, dead link, doc clarification).
2. For larger changes, wait for a thumbs-up on the issue before investing
   time in a PR. We will close unrelated refactors.

## Local setup

See [docs/server/setup.md](docs/server/setup.md) for the server side and
[docs/client/setup.md](docs/client/setup.md) for the Go client. The
["Local development"](README.md#local-development) section of the README
covers the fastest path.

## Style

**Ruby (server):**

- `bundle exec rubocop --parallel` must pass (Omakase config + single
  quotes + frozen_string_literal — configured in `.rubocop.yml`).
- Controllers stay thin: auth + param validation + delegate to a service.
- Services own lifecycle. No business logic in controllers or models.
- One service, one concern. If you're tempted to name it
  `FooAndBarService`, split it.
- `AGENTS.md` documents the per-subsystem invariants.

**Go (client):**

- `go vet ./...` and `gofmt -l .` must both be clean.
- Keep external dependencies minimal. The current set (cobra, yaml.v3,
  fatih/color, x/term) is deliberate — justify each addition.
- Prefer stdlib when the job allows it (e.g. `text/tabwriter` beats
  any third-party table library for CLI output).

## Commits

Conventional Commits format: `feat: ...`, `fix: ...`, `chore: ...`,
`docs: ...`, `refactor: ...`. One concern per commit.

Do NOT add `Co-Authored-By` tags or AI attribution.

## Tests

We have minimal test coverage today. If you are adding a feature, adding
tests for it is appreciated. RSpec stubs are in the Gemfile; Go tests live
next to the code.

## Security

See [SECURITY.md](SECURITY.md) for responsible disclosure. Never open a
public issue for a vulnerability.
