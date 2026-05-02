// Package version implements the "is there a new release available?"
// notice that runs alongside every command.
//
// Design choices, in case future-you wonders:
//
//  1. Source of truth: GitHub Releases API. The Homebrew tap follows
//     GitHub Releases on every cut, so checking GitHub directly avoids the
//     brief window where the tap is one tag behind the source.
//
//  2. When to check: at most once per TTL (default 24h), cached on disk.
//     The check runs in a BACKGROUND goroutine so `capfire deploy` never
//     pays the latency cost. The notice is printed at the end of the
//     command from whatever cache state exists at that moment — typically
//     the result the previous invocation populated.
//
//  3. Failure mode: every network/parse/IO error is silent. A user
//     trying to deploy doesn't care that GitHub is unreachable; they care
//     that their deploy works. The check is a nice-to-have, never a
//     blocker.
//
//  4. Opt-out: CAPFIRE_DISABLE_UPDATE_CHECK=1 env var, plus an
//     `update_check: false` field in the YAML config. Either disables
//     the feature entirely.
//
//  5. Dev builds: when Version == "dev", we skip the whole pipeline.
//     A contributor compiling from source doesn't need to be told their
//     binary is "behind" the latest release — that's the point.
package version

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// LatestReleaseURL is the GitHub Releases API endpoint for the most
// recent release. Public repo, no auth needed (60 req/h per IP, plenty
// for a check that's gated by a 24h cache).
const LatestReleaseURL = "https://api.github.com/repos/ricardo5401/capfire/releases/latest"

// DefaultTTL is how long a cached check is considered fresh. 24h
// matches the cadence of `gh`, `kubectl`, `helm`, etc. — long enough
// that nobody pays for it more than once a day, short enough that
// users see new releases the day after they ship.
const DefaultTTL = 24 * time.Hour

// fetchTimeout caps how long we'll wait for GitHub to respond before
// giving up. The check runs in the background, but we still bound it
// so a flaky network doesn't leave goroutines hanging around forever
// (they'd eventually be reaped at process exit, but explicit is better).
const fetchTimeout = 5 * time.Second

// DisabledEnv is the env var users set to skip the check entirely.
const DisabledEnv = "CAPFIRE_DISABLE_UPDATE_CHECK"

// DevVersion is the placeholder Version takes when the binary was built
// without -ldflags. Comparing "dev" against a real semver is meaningless,
// so we short-circuit on this string.
const DevVersion = "dev"

// githubReleaseResponse is the trimmed shape of the JSON the API returns.
// We only care about `tag_name`; ignoring everything else keeps the
// dependency on GitHub's payload schema as small as possible.
type githubReleaseResponse struct {
	TagName string `json:"tag_name"`
}

// IsDisabled reports whether the user has opted out of update checks
// via the env var. The config-file flag is checked separately at the
// caller boundary because it requires loading the config (and the
// notifier is designed to NOT depend on the config package — keeping
// the import graph clean).
func IsDisabled() bool {
	v := os.Getenv(DisabledEnv)
	if v == "" {
		return false
	}
	// Accept the usual truthy values. Anything else (including "0" and
	// "false") means "not disabled". Mirrors how shell tools usually
	// interpret env-var booleans.
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}

// IsDevBuild reports whether `current` is the placeholder set when no
// version was injected at build time. Used to skip the entire update
// pipeline for contributors building from source.
func IsDevBuild(current string) bool {
	return current == "" || current == DevVersion
}

// FetchLatest hits the GitHub Releases API and returns the latest tag
// name (e.g. "v0.4.0"). Bounded by fetchTimeout. Errors are returned
// verbatim — the caller decides whether to swallow them.
//
// The default http.Client doesn't apply a timeout, so we build a scoped
// context here. We do NOT reuse a global client because the rest of the
// CLI talks to its own server and tweaks its own timeouts; sharing
// would couple two unrelated concerns.
func FetchLatest(ctx context.Context) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, fetchTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, LatestReleaseURL, nil)
	if err != nil {
		return "", err
	}
	// GitHub's API returns smaller payloads with this Accept header.
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "capfire-cli")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		// Repo has no releases yet. Not an error worth surfacing —
		// just means there's nothing to upgrade to.
		return "", nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("github releases api: HTTP %d", resp.StatusCode)
	}

	var body githubReleaseResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return "", fmt.Errorf("decode github response: %w", err)
	}
	return body.TagName, nil
}

// IsNewer reports whether `latest` is strictly greater than `current`.
// Returns false on any parse error so a malformed version string never
// triggers a false-positive "update available" notice.
//
// Both values may carry a leading "v"; it's stripped before parsing.
// We implement our own SemVer comparator here instead of pulling a
// dependency: the format is fully under our control (the release
// workflow only emits `vMAJOR.MINOR.PATCH` tags) and a 30-line parser
// is cheaper than a transitive dep tree.
func IsNewer(latest, current string) bool {
	l, ok := parseSemVer(latest)
	if !ok {
		return false
	}
	c, ok := parseSemVer(current)
	if !ok {
		return false
	}
	return l.greaterThan(c)
}

type semver struct {
	major, minor, patch int
}

func (a semver) greaterThan(b semver) bool {
	switch {
	case a.major != b.major:
		return a.major > b.major
	case a.minor != b.minor:
		return a.minor > b.minor
	default:
		return a.patch > b.patch
	}
}

// parseSemVer accepts "v0.4.0", "0.4.0", or any prefix-stripped variant.
// Returns (semver{}, false) on anything that doesn't fit MAJOR.MINOR.PATCH
// — including pre-release suffixes like "v0.4.0-rc1" which the release
// workflow doesn't currently produce. If we ever ship pre-releases, we
// extend this; until then, rejecting them is the right behavior because
// they'd otherwise silently compare as equal-but-different.
func parseSemVer(s string) (semver, bool) {
	s = strings.TrimSpace(s)
	s = strings.TrimPrefix(s, "v")
	parts := strings.Split(s, ".")
	if len(parts) != 3 {
		return semver{}, false
	}
	nums := [3]int{}
	for i, p := range parts {
		// Reject anything non-numeric (handles "0.4.0-rc1" naturally
		// because the third part is "0-rc1", not a clean integer).
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 {
			return semver{}, false
		}
		nums[i] = n
	}
	return semver{major: nums[0], minor: nums[1], patch: nums[2]}, true
}

// errSkipped is a sentinel returned when the check is disabled (env var,
// dev build, etc.). Used internally so the notifier can distinguish
// "we deliberately did nothing" from "we tried and failed".
var errSkipped = errors.New("update check skipped")
