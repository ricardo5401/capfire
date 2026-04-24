# Client setup

The Capfire client is a single static binary written in Go. It runs on
your laptop (or a CI runner) and talks HTTP to a Capfire server.

Pick whichever install method matches how you got to this machine. All of
them land the same `capfire` binary on your `PATH`.

## Prerequisites

- A Unix-like OS (Linux, macOS, WSL).
- A Capfire server URL and a bearer token issued by the server admin
  (`bin/capfire tokens create` on the server).

## Install method 1 — one-liner (no clone, no Go)

Fastest path for end-users once Capfire has a public release:

```bash
curl -sSL https://raw.githubusercontent.com/ricardo5401/capfire/main/scripts/download-client.sh | bash
```

Customize via env vars:

```bash
PREFIX=$HOME/.local  curl -sSL .../download-client.sh | bash      # user-local install
VERSION=v0.1.0       curl -sSL .../download-client.sh | bash      # pin a version
```

The script downloads the appropriate tarball from the latest GitHub
Release, verifies its SHA256 against `checksums.txt`, installs the
binary with mode 0755.

> The repo must be **public** for this to work — GitHub API returns 404
> on private releases without auth. While private, pass
> `GH_TOKEN=<personal-access-token>` to reach the API.

## Install method 2 — Homebrew (macOS / Linuxbrew)

Once the Homebrew tap is published:

```bash
brew tap ricardo5401/capfire
brew install capfire
```

Upgrade later with `brew upgrade capfire`.

## Install method 3 — apt (Debian / Ubuntu)

Download the `.deb` for your architecture from the
[latest release](https://github.com/ricardo5401/capfire/releases/latest)
and install with `dpkg`:

```bash
# Replace <version> and <arch> (amd64 or arm64) with the matching release.
curl -LO https://github.com/ricardo5401/capfire/releases/download/v<version>/capfire_<version>_<arch>.deb
sudo dpkg -i capfire_<version>_<arch>.deb
```

The package ships a single file: `/usr/local/bin/capfire`.

## Install method 4 — from a repo checkout

If you already cloned the repo (typical for contributors):

```bash
git clone git@github.com:ricardo5401/capfire.git
cd capfire

# Build from source (requires Go 1.22+).
sudo ./scripts/install-client.sh

# Or download pre-built from the latest release (no Go required).
sudo ./scripts/install-client.sh --from-release

# User-scoped install (no sudo; add $HOME/.local/bin to PATH).
./scripts/install-client.sh --prefix=$HOME/.local
```

Flags:

| Flag | Default | Purpose |
|---|---|---|
| `--from-release` | off | Download from GitHub Release instead of building |
| `--prefix DIR` | `/usr/local` | Install prefix |
| `--version VER` | git describe | Source mode: embed in binary. Release mode: which tag to fetch |
| `--no-config` | off | Skip the "run config now?" prompt |

## Install method 5 — `go install`

If you have Go installed and the repo is public:

```bash
go install github.com/ricardo5401/capfire/client@latest
```

The binary lands in `$(go env GOPATH)/bin/capfire`.

## Verify

```bash
capfire --version
capfire --help
```

## First run

```bash
capfire config
```

Interactive prompts for:

- **Host** — e.g. `https://capfire.internal.example.com`. Must include scheme.
- **Token** — the JWT your admin emitted (input is masked).

The config lands at `$XDG_CONFIG_HOME/capfire/config.yml` (or
`~/.config/capfire/config.yml` when XDG is unset). Mode 0600.

Non-interactive usage works too:

```bash
capfire config --host=https://capfire.internal.example.com --token=eyJ...
```

Then verify the token was accepted:

```bash
capfire permission
```

## Updating

Re-run whichever method you used to install. A few examples:

```bash
# one-liner:  curl -sSL .../download-client.sh | bash
# brew:       brew upgrade capfire
# apt:        sudo dpkg -i capfire_<new-version>_<arch>.deb
# from repo:  cd capfire && git pull && sudo ./scripts/install-client.sh --from-release
```

## Uninstalling

```bash
# Manual install:
sudo rm /usr/local/bin/capfire            # or $HOME/.local/bin/capfire
rm ~/.config/capfire/config.yml

# Homebrew:
brew uninstall capfire
brew untap ricardo5401/capfire

# Debian/Ubuntu:
sudo dpkg -r capfire
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
