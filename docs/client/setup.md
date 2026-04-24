# Client setup

The Capfire client is a single static binary written in Go. It runs on
your laptop (or a CI runner) and talks HTTP to a Capfire server.

## What you need

- A Unix-like OS (Linux, macOS, WSL).
- A Capfire server URL and a bearer token (ask your admin, or create one
  with `capfire tokens create` on the server).
- Go 1.22+ **only while we build releases**. Once there are GitHub
  releases the installer will download a pre-built binary — no Go
  required.

## Install

Clone the repo (or download the tarball) and run:

```bash
git clone git@github.com:uDocz/capfire.git
cd capfire

# System-wide install (requires sudo for /usr/local/bin).
sudo ./scripts/install-client.sh

# Or user-scoped install (no sudo; make sure $HOME/.local/bin is on PATH).
./scripts/install-client.sh --prefix=$HOME/.local
```

The installer:

1. Builds the Go binary from `client/`, injecting the output of
   `git describe` as the version string.
2. Installs it to `$PREFIX/bin/capfire` with mode 0755 via atomic
   `install -m 0755` — no half-written binaries if the build fails.
3. Offers to run `capfire config` for you at the end.

Flags:

| Flag | Default | Purpose |
|---|---|---|
| `--prefix DIR` | `/usr/local` | Install prefix |
| `--version VER` | git describe | Override embedded version string |
| `--no-config` | off | Skip the "run config now?" prompt |

Verify:

```bash
capfire --version
capfire --help
```

## First run

```bash
capfire config
```

Interactive prompts for:

- **Host** — e.g. `https://capfire.internal.udocz.com`. Must include scheme.
- **Token** — the JWT your admin emitted (input is masked).

The config lands at `$XDG_CONFIG_HOME/capfire/config.yml` (or
`~/.config/capfire/config.yml` when XDG is unset). Mode 0600.

Non-interactive usage works too:

```bash
capfire config --host=https://capfire.internal.udocz.com --token=eyJ...
```

Then verify the token was accepted:

```bash
capfire permission
```

## Installing on a clean machine (no repo checkout)

Until we publish GitHub releases, you have two shortcuts:

```bash
# 1. If you have Go locally:
go install github.com/uDocz/capfire/client@latest

# 2. One-liner from a clone:
git clone --depth=1 git@github.com:uDocz/capfire.git /tmp/capfire
sudo /tmp/capfire/scripts/install-client.sh
```

## Updating

```bash
cd capfire
git pull
sudo ./scripts/install-client.sh
```

## Uninstalling

```bash
sudo rm /usr/local/bin/capfire            # or $HOME/.local/bin/capfire
rm ~/.config/capfire/config.yml
```

## Troubleshooting

**`capfire: command not found`** — your `$PREFIX/bin` is not on `PATH`.
For `~/.local/bin`, add:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

**`not configured — run capfire config first`** — you installed the
binary but haven't saved a config yet. Run `capfire config`.

**`Your token was rejected`** — token expired or revoked. Verify with
`capfire permission`; ask your admin for a new one.
