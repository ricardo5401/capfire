package version

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Cache is the on-disk record of the latest update check. It lives under
// XDG_CACHE_HOME (or ~/.cache as fallback) so the version-check footprint
// stays separate from the user's config — wiping ~/.cache shouldn't lose
// your token and re-running the check shouldn't be confused with a config
// change.
//
// The file is a JSON object on a single line. Format is intentionally
// boring (no schema migrations) — if we ever change the shape, we just
// invalidate and re-fetch on the next run.
type Cache struct {
	// CheckedAt is when we last hit the GitHub Releases API. The TTL
	// (ShouldRefresh) is computed against this.
	CheckedAt time.Time `json:"checked_at"`

	// LatestVersion is the most recent tag we observed (e.g. "v0.4.0").
	// Always stored with the leading "v" because that's what GitHub
	// returns and what users see on the release page.
	LatestVersion string `json:"latest_version"`

	// CurrentVersionWhenChecked is the binary's own Version at the time
	// of the check. We track it so a user upgrading from an old binary
	// doesn't see a stale "update available" notice from a previous
	// install — when current != current_when_checked, we re-decide.
	CurrentVersionWhenChecked string `json:"current_version_when_checked"`
}

// CachePath returns the absolute path for the cache file. Honors
// XDG_CACHE_HOME, falls back to $HOME/.cache. Does not touch disk.
//
// We use a separate function (instead of inlining in Read/Write) so the
// `capfire version` command can show users where the cache lives — useful
// when debugging "why am I still being told there's an update".
func CachePath() (string, error) {
	if override := os.Getenv("CAPFIRE_CACHE_DIR"); override != "" {
		return filepath.Join(override, "version-check.json"), nil
	}
	if xdg := os.Getenv("XDG_CACHE_HOME"); xdg != "" {
		return filepath.Join(xdg, "capfire", "version-check.json"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home dir: %w", err)
	}
	return filepath.Join(home, ".cache", "capfire", "version-check.json"), nil
}

// ReadCache loads the cache from disk. Returns (nil, nil) when the file
// doesn't exist yet — that's the "fresh install" case, not an error. Any
// other read or parse error returns (nil, err); the caller decides whether
// to surface it or silently re-fetch.
func ReadCache() (*Cache, error) {
	path, err := CachePath()
	if err != nil {
		return nil, err
	}

	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read version cache %s: %w", path, err)
	}

	var c Cache
	if err := json.Unmarshal(data, &c); err != nil {
		// Corrupt cache: treat as if it didn't exist. Caller will
		// re-fetch and overwrite. We don't surface the error because
		// the user couldn't act on it anyway.
		return nil, nil
	}
	return &c, nil
}

// WriteCache persists the cache atomically. Atomic = write to a temp file
// in the same dir then rename — avoids a half-written file when two
// `capfire` invocations race (both finished a fetch around the same time).
//
// Errors are returned to the caller but the version checker treats them
// as non-fatal: failing to update the cache means we'll re-fetch sooner
// than ideal, which is acceptable.
func WriteCache(c *Cache) error {
	path, err := CachePath()
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create cache dir: %w", err)
	}

	data, err := json.Marshal(c)
	if err != nil {
		return fmt.Errorf("encode cache: %w", err)
	}

	// Append PID to the temp name so concurrent writes from two
	// `capfire` processes don't collide on the same `.tmp`.
	tmp := fmt.Sprintf("%s.%d.tmp", path, os.Getpid())
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("write temp cache: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		// Clean up the temp on rename failure so we don't leave junk
		// in the cache directory.
		_ = os.Remove(tmp)
		return fmt.Errorf("rename temp cache: %w", err)
	}
	return nil
}

// ShouldRefresh reports whether the cache is older than `ttl` and we
// should hit the network again. A nil cache always returns true — first
// run has nothing to compare against.
func (c *Cache) ShouldRefresh(ttl time.Duration, now time.Time) bool {
	if c == nil {
		return true
	}
	return now.Sub(c.CheckedAt) >= ttl
}
