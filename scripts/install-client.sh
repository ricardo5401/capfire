#!/usr/bin/env bash
#
# Capfire client installer (from a checkout of the repo).
#
# Two modes:
#
#   --from-source  (default)  Build the Go CLI from client/ and install it.
#                             Requires Go 1.22+.
#   --from-release            Download the latest GitHub Release binary for
#                             this OS/arch (no Go required). Forwards the
#                             call to scripts/download-client.sh.
#
# For a one-liner install on a fresh machine without cloning the repo,
# use scripts/download-client.sh directly via `curl | bash`.
#
# Usage:
#   ./scripts/install-client.sh                        # build from source
#   ./scripts/install-client.sh --from-release         # download + install
#   ./scripts/install-client.sh --prefix=$HOME/.local  # user-scoped
#
# Options:
#   --from-release     Download pre-built binary instead of building
#   --prefix DIR       Install prefix (default: /usr/local)
#   --version VER      Embed / pin a version string
#                        - source build: injected via -ldflags
#                        - release mode: which release tag to fetch (e.g. v0.1.0)
#   --no-config        Skip the "run capfire config now?" prompt at the end
#   -h, --help         Show this help
#
# Requirements for --from-source: Go 1.22+ (download: https://go.dev/doc/install)
# Requirements for --from-release: curl, tar, shasum

set -euo pipefail

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi

info() { printf '%s›%s %s\n' "$C_CYAN"  "$C_RESET" "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail() { printf '%s✗%s %s\n' "$C_RED"   "$C_RESET" "$*" >&2; exit 1; }

PREFIX="/usr/local"
VERSION=""
SKIP_CONFIG=false
FROM_RELEASE=false

usage() { sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-release) FROM_RELEASE=true; shift ;;
    --prefix)       PREFIX="$2"; shift 2 ;;
    --prefix=*)     PREFIX="${1#*=}"; shift ;;
    --version)      VERSION="$2"; shift 2 ;;
    --version=*)    VERSION="${1#*=}"; shift ;;
    --no-config)    SKIP_CONFIG=true; shift ;;
    -h|--help)      usage ;;
    *) fail "unknown argument: $1 (see --help)" ;;
  esac
done

# -----------------------------------------------------------------------------
# Release mode: delegate to scripts/download-client.sh
# -----------------------------------------------------------------------------
if [[ "$FROM_RELEASE" == true ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  DOWNLOADER="$SCRIPT_DIR/download-client.sh"
  [[ -x "$DOWNLOADER" ]] || fail "expected $DOWNLOADER to exist"
  env PREFIX="$PREFIX" VERSION="${VERSION:-latest}" "$DOWNLOADER"
  exit $?
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT_DIR="$SRC_DIR/client"
[[ -f "$CLIENT_DIR/go.mod" ]] || fail "Run this script from the capfire repo (client/go.mod not found)."

command -v go >/dev/null 2>&1 || fail "Go is required. Install from https://go.dev/doc/install and retry."
GO_VERSION="$(go env GOVERSION)"
info "Using ${GO_VERSION} from $(command -v go)"

# Version string — prefer a passed flag, then git describe, then "dev".
if [[ -z "$VERSION" ]]; then
  if command -v git >/dev/null 2>&1 && git -C "$SRC_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    VERSION="$(git -C "$SRC_DIR" describe --tags --always --dirty 2>/dev/null || echo dev)"
  else
    VERSION="dev"
  fi
fi
info "Building capfire ${C_BOLD}${VERSION}${C_RESET}"

BIN_DIR="$PREFIX/bin"
TARGET="$BIN_DIR/capfire"

# Detect whether we need sudo to write into $PREFIX/bin.
SUDO=""
mkdir -p "$BIN_DIR" 2>/dev/null || true
if [[ ! -w "$BIN_DIR" ]]; then
  command -v sudo >/dev/null 2>&1 || fail "$BIN_DIR is not writable and sudo is not available."
  SUDO="sudo"
  info "Will use ${C_BOLD}sudo${C_RESET} to install into $BIN_DIR"
fi

# Build into a temp file and move atomically — avoids half-written binaries
# if the build fails after writing some bytes.
TMP_BIN="$(mktemp)"
trap 'rm -f "$TMP_BIN"' EXIT

pushd "$CLIENT_DIR" >/dev/null
CGO_ENABLED=0 go build \
  -trimpath \
  -ldflags "-s -w -X github.com/ricardo5401/capfire/client/cmd.Version=${VERSION}" \
  -o "$TMP_BIN" \
  .
popd >/dev/null

$SUDO install -m 0755 "$TMP_BIN" "$TARGET"
ok "installed $TARGET"

# Smoke test.
info "Version check: $("$TARGET" --version 2>&1 | head -1)"

cat <<EOF

${C_BOLD}Capfire client installed.${C_RESET}

Next steps:
  1. Configure your host and token:
       ${C_CYAN}capfire config${C_RESET}

  2. Verify your permissions:
       ${C_CYAN}capfire permission${C_RESET}

  3. Deploy:
       ${C_CYAN}capfire deploy myapp production master${C_RESET}

EOF

if [[ "$SKIP_CONFIG" != true ]] && [[ -t 0 ]]; then
  read -r -p "Run 'capfire config' now? [y/N] " answer
  if [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]; then
    "$TARGET" config
  fi
fi
