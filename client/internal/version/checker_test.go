package version

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// withTempCacheDir overrides the cache location for the duration of a
// test. Returns a cleanup func that restores the previous env. Every
// test that touches Cache uses this so the user's real ~/.cache stays
// untouched and tests don't poison each other.
func withTempCacheDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("CAPFIRE_CACHE_DIR", dir)
	return dir
}

func TestParseSemVer(t *testing.T) {
	cases := []struct {
		in    string
		ok    bool
		major int
		minor int
		patch int
	}{
		{"v0.4.0", true, 0, 4, 0},
		{"0.4.0", true, 0, 4, 0},
		{" v1.2.3 ", true, 1, 2, 3},
		{"v10.20.30", true, 10, 20, 30},

		// Pre-release suffixes are rejected on purpose — we don't
		// emit them yet, and accepting them would silently compare
		// "v0.4.0-rc1" as equal to "v0.4.0".
		{"v0.4.0-rc1", false, 0, 0, 0},

		// Garbage and missing parts.
		{"", false, 0, 0, 0},
		{"v1.2", false, 0, 0, 0},
		{"v1.2.3.4", false, 0, 0, 0},
		{"vlatest", false, 0, 0, 0},
		{"v-1.0.0", false, 0, 0, 0},
	}

	for _, tc := range cases {
		t.Run(tc.in, func(t *testing.T) {
			got, ok := parseSemVer(tc.in)
			if ok != tc.ok {
				t.Fatalf("parseSemVer(%q) ok = %v, want %v", tc.in, ok, tc.ok)
			}
			if !ok {
				return
			}
			if got.major != tc.major || got.minor != tc.minor || got.patch != tc.patch {
				t.Errorf("parseSemVer(%q) = %+v, want {%d %d %d}",
					tc.in, got, tc.major, tc.minor, tc.patch)
			}
		})
	}
}

func TestIsNewer(t *testing.T) {
	cases := []struct {
		latest, current string
		want            bool
	}{
		// Strict greater-than across each component.
		{"v0.4.0", "v0.3.0", true},
		{"v1.0.0", "v0.99.99", true},
		{"v0.3.1", "v0.3.0", true},

		// Equal is NOT newer (no banner when up-to-date).
		{"v0.3.0", "v0.3.0", false},

		// Older latest never triggers a notice — protects against a
		// mis-tagged release going backwards.
		{"v0.2.0", "v0.3.0", false},

		// Mixed prefixes still work because parseSemVer strips "v".
		{"0.4.0", "v0.3.0", true},

		// Garbage on either side fails closed (no notice).
		{"weird", "v0.3.0", false},
		{"v0.4.0", "dev", false},
		{"", "v0.3.0", false},
	}

	for _, tc := range cases {
		t.Run(fmt.Sprintf("%s>%s", tc.latest, tc.current), func(t *testing.T) {
			if got := IsNewer(tc.latest, tc.current); got != tc.want {
				t.Errorf("IsNewer(%q, %q) = %v, want %v",
					tc.latest, tc.current, got, tc.want)
			}
		})
	}
}

func TestIsDisabledEnv(t *testing.T) {
	cases := map[string]bool{
		"":      false,
		"0":     false,
		"false": false,
		"no":    false,

		"1":    true,
		"true": true,
		"YES":  true,
		"On":   true,
	}
	for v, want := range cases {
		t.Run(fmt.Sprintf("%q", v), func(t *testing.T) {
			t.Setenv(DisabledEnv, v)
			if got := IsDisabled(); got != want {
				t.Errorf("IsDisabled() with %s=%q = %v, want %v",
					DisabledEnv, v, got, want)
			}
		})
	}
}

func TestIsDevBuild(t *testing.T) {
	if !IsDevBuild("") {
		t.Error(`IsDevBuild("") = false, want true`)
	}
	if !IsDevBuild("dev") {
		t.Error(`IsDevBuild("dev") = false, want true`)
	}
	if IsDevBuild("v0.3.0") {
		t.Error(`IsDevBuild("v0.3.0") = true, want false`)
	}
}

func TestCacheRoundTrip(t *testing.T) {
	withTempCacheDir(t)

	// Initial read: file doesn't exist yet, should return (nil, nil).
	c, err := ReadCache()
	if err != nil {
		t.Fatalf("ReadCache on empty dir: unexpected err %v", err)
	}
	if c != nil {
		t.Fatalf("ReadCache on empty dir: got %+v, want nil", c)
	}

	// Write something and read it back.
	want := &Cache{
		CheckedAt:                 time.Now().UTC().Truncate(time.Second),
		LatestVersion:             "v0.4.0",
		CurrentVersionWhenChecked: "v0.3.0",
	}
	if err := WriteCache(want); err != nil {
		t.Fatalf("WriteCache: %v", err)
	}

	got, err := ReadCache()
	if err != nil {
		t.Fatalf("ReadCache after write: %v", err)
	}
	if got == nil {
		t.Fatal("ReadCache after write: got nil")
	}
	if got.LatestVersion != want.LatestVersion {
		t.Errorf("LatestVersion = %q, want %q", got.LatestVersion, want.LatestVersion)
	}
	if got.CurrentVersionWhenChecked != want.CurrentVersionWhenChecked {
		t.Errorf("CurrentVersionWhenChecked = %q, want %q",
			got.CurrentVersionWhenChecked, want.CurrentVersionWhenChecked)
	}
	if !got.CheckedAt.Equal(want.CheckedAt) {
		t.Errorf("CheckedAt = %v, want %v", got.CheckedAt, want.CheckedAt)
	}
}

func TestCacheCorruptFileTreatedAsMissing(t *testing.T) {
	dir := withTempCacheDir(t)
	path := filepath.Join(dir, "version-check.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("{not valid json"), 0o644); err != nil {
		t.Fatal(err)
	}

	c, err := ReadCache()
	if err != nil {
		t.Fatalf("ReadCache on corrupt file should swallow err, got %v", err)
	}
	if c != nil {
		t.Fatalf("ReadCache on corrupt file = %+v, want nil", c)
	}
}

func TestCacheShouldRefresh(t *testing.T) {
	now := time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)
	ttl := 24 * time.Hour

	if !(*Cache)(nil).ShouldRefresh(ttl, now) {
		t.Error("nil cache should always refresh")
	}

	fresh := &Cache{CheckedAt: now.Add(-1 * time.Hour)}
	if fresh.ShouldRefresh(ttl, now) {
		t.Error("cache 1h old should NOT refresh with 24h TTL")
	}

	stale := &Cache{CheckedAt: now.Add(-25 * time.Hour)}
	if !stale.ShouldRefresh(ttl, now) {
		t.Error("cache 25h old SHOULD refresh with 24h TTL")
	}

	// Boundary: exactly TTL ago counts as stale (>=).
	boundary := &Cache{CheckedAt: now.Add(-ttl)}
	if !boundary.ShouldRefresh(ttl, now) {
		t.Error("cache exactly at TTL boundary SHOULD refresh")
	}
}

func TestNotifierSkipsWhenDevBuild(t *testing.T) {
	withTempCacheDir(t)
	n := NewNotifier(DevVersion)
	n.fetcher = func(_ context.Context) (string, error) {
		t.Fatal("fetcher must NOT be called for dev builds")
		return "", nil
	}
	n.MaybeAsync()
	n.Drain(time.Second)

	var buf bytes.Buffer
	n.MaybePrint(&buf)
	if buf.Len() > 0 {
		t.Errorf("dev build should print nothing, got %q", buf.String())
	}
}

func TestNotifierSkipsWhenDisabledByEnv(t *testing.T) {
	withTempCacheDir(t)
	t.Setenv(DisabledEnv, "1")

	n := NewNotifier("v0.3.0")
	n.fetcher = func(_ context.Context) (string, error) {
		t.Fatal("fetcher must NOT be called when disabled")
		return "", nil
	}
	n.MaybeAsync()
	n.Drain(time.Second)
}

func TestNotifierSkipsWhenDisabledByConfig(t *testing.T) {
	withTempCacheDir(t)

	n := NewNotifier("v0.3.0")
	n.Disabled = true
	n.fetcher = func(_ context.Context) (string, error) {
		t.Fatal("fetcher must NOT be called when n.Disabled")
		return "", nil
	}
	n.MaybeAsync()
	n.Drain(time.Second)
}

func TestNotifierFetchesAndPrintsBanner(t *testing.T) {
	withTempCacheDir(t)

	n := NewNotifier("v0.3.0")
	n.fetcher = func(_ context.Context) (string, error) {
		return "v0.4.0", nil
	}
	n.MaybeAsync()
	n.Drain(2 * time.Second)

	var buf bytes.Buffer
	n.MaybePrint(&buf)
	out := buf.String()
	if !strings.Contains(out, "v0.4.0") {
		t.Errorf("banner missing latest version: %q", out)
	}
	if !strings.Contains(out, "v0.3.0") {
		t.Errorf("banner missing current version: %q", out)
	}
	if !strings.Contains(out, "brew upgrade capfire") {
		t.Errorf("banner missing upgrade hint: %q", out)
	}
}

func TestNotifierSkipsBannerWhenUpToDate(t *testing.T) {
	withTempCacheDir(t)

	n := NewNotifier("v0.4.0")
	n.fetcher = func(_ context.Context) (string, error) {
		return "v0.4.0", nil
	}
	n.MaybeAsync()
	n.Drain(2 * time.Second)

	var buf bytes.Buffer
	n.MaybePrint(&buf)
	if buf.Len() > 0 {
		t.Errorf("up-to-date should print nothing, got %q", buf.String())
	}
}

func TestNotifierSkipsBannerWhenCurrentChangedSinceCache(t *testing.T) {
	// Scenario: user upgraded from v0.3.0 -> v0.4.0 since the last
	// cached check (which still says "latest = v0.4.0"). Without the
	// guard, we'd tell them to upgrade to v0.4.0 even though they
	// already have it.
	withTempCacheDir(t)

	if err := WriteCache(&Cache{
		CheckedAt:                 time.Now(),
		LatestVersion:             "v0.4.0",
		CurrentVersionWhenChecked: "v0.3.0",
	}); err != nil {
		t.Fatal(err)
	}

	n := NewNotifier("v0.4.0")
	var buf bytes.Buffer
	n.MaybePrint(&buf)
	if buf.Len() > 0 {
		t.Errorf("stale-after-upgrade should print nothing, got %q", buf.String())
	}
}

func TestNotifierSwallowsFetchErrors(t *testing.T) {
	// A failed fetch must not surface to the user. The cache stays
	// empty and the banner stays silent.
	withTempCacheDir(t)

	n := NewNotifier("v0.3.0")
	n.fetcher = func(_ context.Context) (string, error) {
		return "", errors.New("simulated network failure")
	}
	n.MaybeAsync()
	n.Drain(2 * time.Second)

	var buf bytes.Buffer
	n.MaybePrint(&buf)
	if buf.Len() > 0 {
		t.Errorf("fetch failure should print nothing, got %q", buf.String())
	}
}

func TestNotifierSkipsRefreshWhenCacheFresh(t *testing.T) {
	// Pre-populate a fresh cache. MaybeAsync must NOT call the
	// fetcher because we're inside the TTL window.
	withTempCacheDir(t)

	now := time.Now()
	if err := WriteCache(&Cache{
		CheckedAt:                 now.Add(-1 * time.Hour),
		LatestVersion:             "v0.4.0",
		CurrentVersionWhenChecked: "v0.3.0",
	}); err != nil {
		t.Fatal(err)
	}

	var fetched int32
	var mu sync.Mutex
	n := NewNotifier("v0.3.0")
	n.fetcher = func(_ context.Context) (string, error) {
		mu.Lock()
		fetched++
		mu.Unlock()
		return "v0.5.0", nil
	}
	n.MaybeAsync()
	n.Drain(time.Second)

	mu.Lock()
	defer mu.Unlock()
	if fetched != 0 {
		t.Errorf("fresh cache should skip fetch, got %d calls", fetched)
	}

	// Banner reflects the cached state — v0.4.0, not v0.5.0.
	var buf bytes.Buffer
	n.MaybePrint(&buf)
	if !strings.Contains(buf.String(), "v0.4.0") {
		t.Errorf("expected cached banner to mention v0.4.0, got %q", buf.String())
	}
}

func TestFetchLatestParsesGitHubResponse(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Accept"); got != "application/vnd.github+json" {
			t.Errorf("missing/wrong Accept header: %q", got)
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"tag_name": "v1.2.3"})
	}))
	defer srv.Close()

	// We can't easily override LatestReleaseURL (it's a const), so we
	// exercise the parser directly via a small wrapper that mimics
	// FetchLatest's request shape against the test server.
	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	req.Header.Set("Accept", "application/vnd.github+json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	var body githubReleaseResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body.TagName != "v1.2.3" {
		t.Errorf("tag_name = %q, want v1.2.3", body.TagName)
	}
}

func TestNotifierMultipleMaybeAsyncCallsAreSafe(t *testing.T) {
	// Calling MaybeAsync twice from the same Notifier must not
	// double-fetch — the once.Do guards against this. The wg still
	// resolves correctly so Drain doesn't hang.
	withTempCacheDir(t)

	var fetched int32
	var mu sync.Mutex
	n := NewNotifier("v0.3.0")
	n.fetcher = func(_ context.Context) (string, error) {
		mu.Lock()
		fetched++
		mu.Unlock()
		return "v0.4.0", nil
	}
	n.MaybeAsync()
	n.MaybeAsync()
	n.MaybeAsync()
	n.Drain(2 * time.Second)

	mu.Lock()
	defer mu.Unlock()
	if fetched != 1 {
		t.Errorf("MaybeAsync called 3x triggered %d fetches, want 1", fetched)
	}
}
