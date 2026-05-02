# Cutting a Capfire release

This document is for the Capfire maintainer. End users don't need any of
this — they just `brew upgrade capfire` and move on.

The release pipeline ships a new `vX.Y.Z` to GitHub Releases and to the
`homebrew-capfire` tap in one motion. A maintainer cuts a release with a
single command:

```bash
./scripts/release.sh 0.4.0
```

Everything else — cross-compilation, .deb packaging, GitHub Release
creation, Homebrew tap update — happens in CI.

---

## TL;DR for "I just want to ship 0.4.0"

```bash
git checkout master
git pull
./scripts/release.sh 0.4.0
# coffee break (~5 min for the workflow to finish)
```

That's it. When the workflow's `update-tap` job goes green, anyone
running `brew upgrade capfire` gets `0.4.0`.

---

## What `scripts/release.sh` does

Read the comment block at the top of the script for the canonical list,
but in short:

1. **Validates the version**. Must be `MAJOR.MINOR.PATCH` (no `v`
   prefix, no `-rc` suffix), and strictly greater than the current
   version recorded in `packaging/homebrew/capfire.rb`.
2. **Validates the working tree**. Must be on `master`, no uncommitted
   changes, in sync with `origin/master`. The tag `vX.Y.Z` must not
   already exist locally or on origin.
3. **Bumps the in-repo formula**. `packaging/homebrew/capfire.rb` is
   updated to the new version. This file is *documentary* — the file
   `brew install` actually consumes lives in the
   [`homebrew-capfire`](https://github.com/ricardo5401/homebrew-capfire)
   tap and is rewritten by the workflow. Keeping the in-repo template in
   sync makes the diff in PRs easy to review.
4. **Commits + tags + pushes**. Annotated tag, branch push first then
   tag push so a flaky push leaves the repo in a recoverable state.

There's a `--dry-run` flag that runs all the validations and prints the
plan without writing anything. Use it the first time you forget the
exact version number convention.

```bash
./scripts/release.sh 0.4.0 --dry-run
```

---

## What the GitHub Actions workflow does

`.github/workflows/release.yml` triggers on every `v*` tag push. Four
jobs:

| Job | Purpose |
|---|---|
| `build` | Cross-compiles the Go client for `linux/darwin × amd64/arm64`. |
| `package-deb` | Builds `.deb` packages for Linux amd64/arm64 via `nfpm`. |
| `release` | Aggregates artifacts, generates `checksums.txt`, publishes the GitHub Release. |
| `update-tap` | Pulls `checksums.txt` from the release, regenerates `Formula/capfire.rb` in `homebrew-capfire`, commits + pushes. **Idempotent** — re-running it when the formula is already up to date is a no-op. |

The `update-tap` job is the only one that touches the second repo. It
authenticates via the `HOMEBREW_TAP_TOKEN` secret (see below for setup).

---

## One-time setup

You only do this once per fresh clone of the project, or when rotating
credentials. After this, every release is just `./scripts/release.sh
X.Y.Z`.

### 1. Create the tap repository

The Homebrew tap lives at
`https://github.com/ricardo5401/homebrew-capfire`. Create it as a
**public** GitHub repo (Homebrew taps must be public) with whatever
default branch you prefer — the workflow pushes to `main`.

Seed it with the current formula so `brew tap` doesn't complain about
an empty repo:

```bash
git clone git@github.com:ricardo5401/homebrew-capfire.git
cd homebrew-capfire
mkdir -p Formula
cp ../capfire/packaging/homebrew/capfire.rb Formula/capfire.rb
git add Formula/capfire.rb
git commit -m "Initial formula"
git push origin main
```

The first `./scripts/release.sh` run will overwrite `Formula/capfire.rb`
with the auto-generated version. The seed only matters so users running
`brew tap ricardo5401/capfire` before the first release see a working
formula.

### 2. Create a fine-grained Personal Access Token

The release workflow needs to push to `homebrew-capfire` from inside the
`capfire` repo. That's a cross-repo write that `GITHUB_TOKEN` doesn't
grant by default, so we use a fine-grained PAT scoped to the absolute
minimum.

Go to <https://github.com/settings/personal-access-tokens> → **Generate
new token (fine-grained)**:

```
Token name:           capfire-tap-sync
Description:          Used by capfire's release workflow to push formula
                      updates to homebrew-capfire
Expiration:           1 year (max — diary an entry to renew)
Repository access:    Only select repositories
                      → ricardo5401/homebrew-capfire
Repository permissions:
  Contents:           Read and write
  Metadata:           Read-only (forced when any other permission is set)
  (everything else:   No access)
Account permissions:
  (everything:        No access)
```

> ⚠️ Do NOT use a classic PAT. They grant write to ALL your repos.
> Fine-grained scopes the token to a single repo and forbids account-wide
> operations.

Copy the token value — GitHub shows it once.

### 3. Save the token as a repository secret

In `https://github.com/ricardo5401/capfire/settings/secrets/actions` →
**New repository secret**:

```
Name:   HOMEBREW_TAP_TOKEN
Value:  github_pat_11AAAA...   ← the token from step 2
```

The secret name is referenced by the `update-tap` job. Don't rename it
without updating `.github/workflows/release.yml`.

### 4. Verify the wiring

Cut a tiny throwaway version (a patch bump that you'll abandon) using
`--dry-run`, then for real:

```bash
./scripts/release.sh 0.3.1 --dry-run   # confirms validations + plan
./scripts/release.sh 0.3.1             # actually pushes
```

Watch the workflow:

- <https://github.com/ricardo5401/capfire/actions/workflows/release.yml>

When `update-tap` finishes green, check the tap repo and confirm
`Formula/capfire.rb` shows `version "0.3.1"` with the four real
checksums.

---

## Renewing the PAT

Fine-grained PATs expire. GitHub emails you ~7 days before expiry.

1. Generate a new PAT with the same scopes (step 2 above).
2. Update the `HOMEBREW_TAP_TOKEN` secret in capfire (step 3 above) —
   click the secret, then **Update**, paste the new value.
3. Done. No code change needed.

If you missed the expiry email and a release fails because of it, the
`update-tap` job will fail with a 403 from `git push`. The GitHub
Release itself still publishes — you just need to renew the PAT and
re-run the failed job from the Actions UI.

---

## Failure recovery

| What failed | What to do |
|---|---|
| `release.sh` errored before pushing the tag | Nothing — script is fail-safe pre-push. Fix the issue, re-run. |
| Tag pushed, `build` or `package-deb` failed | Delete the tag and re-cut: `git push --delete origin vX.Y.Z && git tag -d vX.Y.Z`. The version bump commit on master can stay or be reverted depending on whether you want to retry with the same number. |
| Release published, `update-tap` failed | Re-run the `update-tap` job from the Actions UI. It's idempotent — if the formula is already correct, it'll exit cleanly without pushing. |
| `update-tap` keeps failing with 403 | Likely an expired or revoked PAT. Renew it (see above) and re-run the job. |

---

## What's intentionally NOT automated

- **CHANGELOG.md generation**. The release workflow's
  `generate_release_notes: true` produces release notes from PR titles,
  which is the only changelog we care about. Every PR title is the
  changelog entry — keep them clean.
- **Pre-release tags** (`v0.4.0-rc1`). Both the version checker and
  this script reject them on purpose. If we ever ship pre-releases,
  we'll extend `parseSemVer` in `client/internal/version/checker.go`,
  the script's regex, and the workflow's tap-update template at the
  same time.
- **Multi-architecture testing**. The `test do` block in the formula
  exercises `--version` only. Anything more would require a Capfire
  server reachable from CI, which we don't want to operate.
