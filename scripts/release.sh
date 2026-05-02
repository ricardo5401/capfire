#!/usr/bin/env bash
#
# Capfire release helper.
#
# What this script does (in order):
#   1. Validates the version argument is a clean MAJOR.MINOR.PATCH that's
#      strictly greater than the current Homebrew formula version.
#   2. Verifies the working tree is clean and synced with origin/master —
#      no uncommitted changes, no missing pulls, on the right branch.
#   3. Bumps `version "X.Y.Z"` in packaging/homebrew/capfire.rb (kept as a
#      documentary copy that mirrors what ends up in the homebrew-capfire
#      tap once the workflow finishes).
#   4. Commits the bump as `release: bump to vX.Y.Z` and creates an
#      annotated tag `vX.Y.Z`.
#   5. Pushes commit + tag. The push of the tag triggers
#      .github/workflows/release.yml on GitHub, which (a) cross-compiles
#      and publishes the GitHub Release and (b) updates Formula/capfire.rb
#      in homebrew-capfire automatically (via the update-tap job, which
#      uses the HOMEBREW_TAP_TOKEN secret).
#
# Why bump the local capfire.rb at all (it's not the file users install):
#   The `Formula/capfire.rb` that `brew install` actually consumes lives
#   in homebrew-capfire and is rewritten by the release workflow. Keeping
#   the in-repo template in sync is purely documentary — it lets a new
#   contributor open the file and see "this is the shape and version
#   currently published", with no manual editing needed.
#
# Usage:
#   ./scripts/release.sh 0.4.0           # cuts vTAG and pushes
#   ./scripts/release.sh 0.4.0 --dry-run # validates + prints plan, no writes
#
# Exit codes:
#   0 — success (or dry-run that passed all checks)
#   1 — validation/state error (the script never half-applies a release)
#   2 — git operation failed mid-flight
#
# Requirements:
#   - bash 4+, git, awk, sed
#   - origin remote pointing at the capfire repo
#   - HOMEBREW_TAP_TOKEN secret already configured in GitHub Actions for
#     the cross-repo push to homebrew-capfire (a one-time setup; see
#     docs/release.md)

set -euo pipefail

# ----- Constants ------------------------------------------------------------

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly FORMULA="${REPO_ROOT}/packaging/homebrew/capfire.rb"
readonly RELEASE_BRANCH="master"

# Pretty output. Honour NO_COLOR (https://no-color.org) and downgrade to
# plain text when stdout is not a TTY (CI, file redirects).
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RESET=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BOLD=''; C_DIM=''; C_RESET=''
fi

# ----- Logging helpers ------------------------------------------------------

# Each helper writes to stderr so the script's stdout stays clean for any
# future callers that want to pipe (`./release.sh 0.4.0 | tee log.txt`).
info()    { printf '%s%s%s %s\n' "$C_BOLD" "›" "$C_RESET" "$*" >&2; }
success() { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn()    { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail()    { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# Used in dry-run mode to highlight commands that WOULD have run.
plan() { printf '%s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2; }

# ----- Argument parsing -----------------------------------------------------

DRY_RUN=0
NEW_VERSION=""

usage() {
  cat <<EOF >&2
Usage: $(basename "$0") VERSION [--dry-run]

Cuts a Capfire release: bumps the in-repo Homebrew formula, commits, tags,
and pushes. The GitHub Actions workflow takes it from there.

Arguments:
  VERSION       Target version, no \`v\` prefix (e.g. 0.4.0).
                Must be MAJOR.MINOR.PATCH and strictly greater than the
                current formula version.

Options:
  --dry-run     Run all validations and print the plan; do not write,
                commit, tag or push anything.
  -h, --help    Print this help.

Examples:
  $(basename "$0") 0.4.0
  $(basename "$0") 0.4.0 --dry-run

See docs/release.md for the one-time setup of the HOMEBREW_TAP_TOKEN
secret and the homebrew-capfire repo.
EOF
}

while (( $# )); do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      fail "unknown option: $1 (try --help)"
      ;;
    *)
      if [[ -n "$NEW_VERSION" ]]; then
        fail "unexpected extra argument: $1"
      fi
      NEW_VERSION="$1"
      shift
      ;;
  esac
done

[[ -n "$NEW_VERSION" ]] || { usage; exit 1; }

# ----- Validation: version format ------------------------------------------

# We deliberately reject pre-release suffixes (v0.4.0-rc1) because the
# version-checker on the client side rejects them too — keeping the two
# pieces honest about what we ship. If we ever want pre-releases, we
# extend both at the same time.
if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "invalid version: '${NEW_VERSION}' — must be MAJOR.MINOR.PATCH (no v prefix, no -rc suffix)"
fi

readonly TAG="v${NEW_VERSION}"

# ----- Validation: working tree --------------------------------------------

cd "$REPO_ROOT"

# Branch check FIRST so we don't yell about uncommitted state when the
# real issue is "you're on the wrong branch".
current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
if [[ "$current_branch" != "$RELEASE_BRANCH" ]]; then
  fail "must be on '${RELEASE_BRANCH}' branch (currently on '${current_branch:-detached HEAD}')"
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  fail "working tree has uncommitted changes — commit or stash first"
fi

# Untracked files are usually fine, but a stale build artifact named like
# the formula could cause confusion. Warn loudly and let the user decide.
if [[ -n "$(git status --porcelain | grep '^??' || true)" ]]; then
  warn "untracked files present — they will NOT be included in the release"
fi

info "fetching origin to check sync state"
git fetch origin --tags --quiet

local_sha="$(git rev-parse HEAD)"
remote_sha="$(git rev-parse "origin/${RELEASE_BRANCH}")"
if [[ "$local_sha" != "$remote_sha" ]]; then
  fail "local '${RELEASE_BRANCH}' diverges from origin — pull or push first"
fi

# ----- Validation: tag does not already exist ------------------------------

if git rev-parse --verify --quiet "refs/tags/${TAG}" >/dev/null; then
  fail "tag '${TAG}' already exists locally — pick a different version or delete the tag"
fi

if git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1; then
  fail "tag '${TAG}' already exists on origin — pick a different version"
fi

# ----- Validation: version is strictly greater than current ----------------

# Extract the current version from the formula. The line we match is
# canonically `  version "0.3.0"` — flexible-ish so a future stylistic
# change (single quotes, extra spacing) still parses.
if [[ ! -f "$FORMULA" ]]; then
  fail "formula not found at ${FORMULA}"
fi

current_version="$(awk '/^  version "/ { match($0, /"[^"]+"/); print substr($0, RSTART+1, RLENGTH-2); exit }' "$FORMULA")"
if [[ -z "$current_version" ]]; then
  fail "could not detect current version from ${FORMULA}"
fi

# Split MAJOR.MINOR.PATCH into integers and compare numerically. Doing
# this in pure bash avoids depending on `sort -V` (BSD vs GNU
# differences) or pulling in `python -c`.
version_gt() {
  # Returns 0 (true) when $1 > $2.
  local a="$1" b="$2"
  IFS='.' read -r a1 a2 a3 <<<"$a"
  IFS='.' read -r b1 b2 b3 <<<"$b"
  if (( a1 != b1 )); then (( a1 > b1 )); return; fi
  if (( a2 != b2 )); then (( a2 > b2 )); return; fi
  (( a3 > b3 ))
}

if ! version_gt "$NEW_VERSION" "$current_version"; then
  fail "new version '${NEW_VERSION}' must be strictly greater than current '${current_version}'"
fi

# ----- Show plan and (optionally) confirm ----------------------------------

# What's between the last tag and HEAD: the user appreciates seeing the
# changelog before committing to a release. `git tag --list` sorted by
# creation gives us the previous tag without depending on semantic sort.
prev_tag="$(git tag --sort=-creatordate | head -n1 || true)"
if [[ -n "$prev_tag" ]]; then
  commit_count="$(git rev-list --count "${prev_tag}..HEAD")"
else
  commit_count="$(git rev-list --count HEAD)"
fi

cat <<EOF >&2

${C_BOLD}Release plan${C_RESET}
  ${C_DIM}from:${C_RESET}    ${prev_tag:-<initial>} (current formula version: ${current_version})
  ${C_DIM}to:${C_RESET}      ${TAG}
  ${C_DIM}commits:${C_RESET} ${commit_count}
  ${C_DIM}branch:${C_RESET}  ${RELEASE_BRANCH} @ ${local_sha:0:7}

EOF

if [[ -n "$prev_tag" ]] && (( commit_count > 0 )); then
  info "commits since ${prev_tag}:"
  git log --pretty=format:'  %h %s' "${prev_tag}..HEAD" >&2
  printf '\n\n' >&2
fi

if (( DRY_RUN )); then
  plan "would update version in ${FORMULA##*/} from ${current_version} to ${NEW_VERSION}"
  plan "would commit: 'release: bump to ${TAG}'"
  plan "would create annotated tag ${TAG}"
  plan "would push ${RELEASE_BRANCH} and ${TAG} to origin"
  success "dry-run completed — no changes written"
  exit 0
fi

# Interactive confirmation when running on a TTY. Skipped in CI / piped
# invocations so the script can still be automated upstream if needed.
if [[ -t 0 ]]; then
  printf '%s' "Proceed with release? [y/N] " >&2
  read -r reply
  if [[ ! "$reply" =~ ^[yY]([eE][sS])?$ ]]; then
    info "aborted by user"
    exit 0
  fi
fi

# ----- Bump the formula ----------------------------------------------------

info "bumping version in ${FORMULA##*/}"

# In-place edit. We anchor on the exact `  version "..."` shape we
# detected above so we don't accidentally rewrite a `version` reference
# inside an url string later in the file.
#
# Portable sed: macOS BSD sed and GNU sed disagree on -i syntax, so we
# write to a temp file and move it. Cheap and unambiguous.
tmp="$(mktemp)"
awk -v new="$NEW_VERSION" '
  /^  version "/ && !done {
    sub(/"[^"]+"/, "\"" new "\"");
    done=1;
  }
  { print }
' "$FORMULA" > "$tmp"
mv "$tmp" "$FORMULA"

# Verify the bump landed where we expected.
verify="$(awk '/^  version "/ { match($0, /"[^"]+"/); print substr($0, RSTART+1, RLENGTH-2); exit }' "$FORMULA")"
if [[ "$verify" != "$NEW_VERSION" ]]; then
  fail "formula bump failed — expected ${NEW_VERSION}, found '${verify}'"
fi

# ----- Commit + tag + push -------------------------------------------------

info "committing bump"
git add "$FORMULA"
git commit -m "release: bump to ${TAG}" --quiet

# Annotated tag (-a) so the tag itself carries metadata visible in
# `git show ${TAG}`. The release notes on GitHub still come from
# generate_release_notes in the workflow.
info "creating annotated tag ${TAG}"
git tag -a "$TAG" -m "Capfire ${TAG}"

info "pushing ${RELEASE_BRANCH} and ${TAG} to origin"
# Push the branch FIRST: if this fails (e.g. a teammate pushed in the
# meantime), the tag is still local and we can `git tag -d ${TAG}` to
# unwind cleanly.
git push origin "$RELEASE_BRANCH"
git push origin "$TAG"

# ----- Done ----------------------------------------------------------------

# Try to derive the GitHub URL from origin so the user can click through
# without having to remember the path. Falls back to a generic message
# when the remote isn't on github.com.
origin_url="$(git remote get-url origin 2>/dev/null || true)"
if [[ "$origin_url" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
  user="${BASH_REMATCH[1]}"
  repo="${BASH_REMATCH[2]}"
  workflow_url="https://github.com/${user}/${repo}/actions/workflows/release.yml"
  release_url="https://github.com/${user}/${repo}/releases/tag/${TAG}"

  cat <<EOF >&2

${C_GREEN}${C_BOLD}Release ${TAG} is on its way.${C_RESET}

  Workflow:  ${workflow_url}
  Release:   ${release_url}  ${C_DIM}(visible once the workflow finishes)${C_RESET}

The release workflow will:
  1. Cross-compile the Go client for linux/darwin × amd64/arm64.
  2. Build .deb packages.
  3. Publish the GitHub Release with all artifacts.
  4. Push the updated formula to homebrew-capfire (using HOMEBREW_TAP_TOKEN).

Users running ${C_BOLD}brew upgrade capfire${C_RESET} will get ${TAG} once step 4 finishes.
EOF
else
  success "release ${TAG} pushed — check your CI for progress"
fi
