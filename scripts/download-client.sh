#!/usr/bin/env bash
#
# Capfire client one-liner installer.
#
# Downloads the latest Capfire CLI binary from GitHub Releases, verifies its
# SHA256 checksum, and installs it as `$PREFIX/bin/capfire`. Does NOT require
# a checkout of the repo or a Go toolchain.
#
# Usage — paste into any terminal:
#
#   curl -sSL https://raw.githubusercontent.com/ricardo5401/capfire/main/scripts/download-client.sh | bash
#
# Customize via env vars:
#
#   PREFIX=$HOME/.local  curl -sSL ... | bash        # user install, no sudo
#   VERSION=v0.1.0       curl -sSL ... | bash        # pin a specific version
#   REPO=ricardo5401/capfire                         # override the repo
#
# Note: while the repo is private this script cannot be used — GitHub
# Releases for private repos require authentication. Make the repo public
# (or provide `GITHUB_TOKEN` via `GH_TOKEN` env var) to use this installer.

set -euo pipefail

REPO="${REPO:-ricardo5401/capfire}"
PREFIX="${PREFIX:-/usr/local}"
VERSION="${VERSION:-latest}"
GH_TOKEN="${GH_TOKEN:-}"

# ---------------------------------------------------------------------------
# Styling
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Detect OS / arch
# ---------------------------------------------------------------------------
case "$(uname -s)" in
  Linux)  OS=linux ;;
  Darwin) OS=darwin ;;
  *) fail "unsupported OS: $(uname -s)" ;;
esac

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) fail "unsupported arch: $(uname -m)" ;;
esac

info "Target: ${C_BOLD}${OS}/${ARCH}${C_RESET}"

# ---------------------------------------------------------------------------
# Required commands
# ---------------------------------------------------------------------------
for cmd in curl tar shasum; do
  command -v "$cmd" >/dev/null 2>&1 || fail "missing required command: $cmd"
done

# ---------------------------------------------------------------------------
# Resolve version
# ---------------------------------------------------------------------------
curl_auth=()
[[ -n "$GH_TOKEN" ]] && curl_auth=(-H "Authorization: Bearer $GH_TOKEN")

if [[ "$VERSION" == "latest" ]]; then
  info "Resolving latest release from github.com/${REPO}"
  api_resp=$(curl -sf "${curl_auth[@]}" "https://api.github.com/repos/${REPO}/releases/latest" || true)
  VERSION=$(printf '%s\n' "$api_resp" | grep -m1 '"tag_name"' | cut -d'"' -f4 || true)
  [[ -n "$VERSION" ]] || fail "could not resolve latest release (is the repo private? set GH_TOKEN, or pin VERSION=v0.1.0)"
fi

info "Version: ${C_BOLD}${VERSION}${C_RESET}"

# ---------------------------------------------------------------------------
# Download + verify
# ---------------------------------------------------------------------------
ARCHIVE="capfire-${VERSION}-${OS}-${ARCH}.tar.gz"
URL_BASE="https://github.com/${REPO}/releases/download/${VERSION}"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

info "Downloading ${URL_BASE}/${ARCHIVE}"
curl -sfL "${curl_auth[@]}" "${URL_BASE}/${ARCHIVE}" -o "$TMPDIR/$ARCHIVE" \
  || fail "failed to download $ARCHIVE — check the release exists and the repo is accessible"

info "Fetching checksums.txt"
if curl -sfL "${curl_auth[@]}" "${URL_BASE}/checksums.txt" -o "$TMPDIR/checksums.txt"; then
  expected=$(grep " $ARCHIVE\$" "$TMPDIR/checksums.txt" | awk '{print $1}' || true)
  if [[ -z "$expected" ]]; then
    warn "checksum line for $ARCHIVE not found — proceeding without verification"
  else
    actual=$(shasum -a 256 "$TMPDIR/$ARCHIVE" | awk '{print $1}')
    [[ "$expected" == "$actual" ]] || fail "SHA256 mismatch! expected=$expected got=$actual"
    ok "SHA256 verified"
  fi
else
  warn "checksums.txt not found in release — skipping verification"
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
tar -xzf "$TMPDIR/$ARCHIVE" -C "$TMPDIR"
[[ -x "$TMPDIR/capfire" ]] || fail "archive did not contain a 'capfire' binary"

BIN_DIR="$PREFIX/bin"
mkdir -p "$BIN_DIR" 2>/dev/null || true

SUDO=""
if [[ ! -w "$BIN_DIR" ]]; then
  command -v sudo >/dev/null 2>&1 || fail "$BIN_DIR is not writable and sudo is not available"
  SUDO="sudo"
  info "Using sudo to install into $BIN_DIR"
fi

$SUDO install -m 0755 "$TMPDIR/capfire" "$BIN_DIR/capfire"
ok "Installed $BIN_DIR/capfire"

info "Version check: $("$BIN_DIR/capfire" --version 2>&1 | head -1)"

cat <<EOF

${C_BOLD}Capfire client installed.${C_RESET}

Next steps:
  1. ${C_CYAN}capfire config${C_RESET}       Configure host + token
  2. ${C_CYAN}capfire permission${C_RESET}   Verify what your token can do
  3. ${C_CYAN}capfire deploy APP ENV${C_RESET}   (e.g. capfire deploy myapp staging master)

EOF
