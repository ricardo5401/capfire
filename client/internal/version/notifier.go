package version

import (
	"context"
	"fmt"
	"io"
	"sync"
	"time"
)

// Notifier ties together the cache, the fetcher, and the user-facing
// notice. A single instance is shared across the lifetime of a `capfire`
// invocation — Cobra's PersistentPreRun kicks off the background check,
// the command does its work, and the post-run hook prints the notice
// (if any) right before the process exits.
//
// The struct holds:
//   - the binary's current version (so we can decide if a fetched tag is
//     "newer"),
//   - a TTL so tests can shrink it,
//   - a `disabled` flag the caller sets when the user's config opts out,
//   - a once-guarded WaitGroup so MaybeAsync can be called from anywhere
//     and Drain still does the right thing if it's called twice.
//
// Why a struct and not free functions: the disabled-via-config flag is
// known only after we read the YAML, but the cache-check happens in
// PersistentPreRun before subcommands have run. Carrying the state on a
// shared instance is cleaner than threading "disabled" through every
// call site.
type Notifier struct {
	Current  string        // The binary's Version. Skipped when "dev".
	TTL      time.Duration // Cache freshness window. Defaults to DefaultTTL.
	Disabled bool          // When true, the entire pipeline becomes a no-op.

	// fetcher is the function that actually hits GitHub. It's a field
	// (not a hard call to FetchLatest) so tests can stub it without
	// patching the http stack.
	fetcher func(context.Context) (string, error)

	// now lets tests pin time. Production keeps it as time.Now.
	now func() time.Time

	// wg + once let MaybeAsync be called multiple times safely (only
	// the first call kicks off the goroutine; later ones are no-ops)
	// while Drain still blocks for the goroutine to finish.
	wg   sync.WaitGroup
	once sync.Once
}

// NewNotifier builds a notifier with sensible defaults wired up.
// Callers can mutate fields (Disabled, TTL) before invoking MaybeAsync.
func NewNotifier(current string) *Notifier {
	return &Notifier{
		Current: current,
		TTL:     DefaultTTL,
		fetcher: FetchLatest,
		now:     time.Now,
	}
}

// MaybeAsync kicks off a background refresh of the version cache when
// the cache is stale and the user hasn't opted out. The returned
// goroutine is tracked on the Notifier so Drain (called at process
// exit) can wait for it to finish before reading the cache for the
// banner.
//
// This function never blocks beyond reading the local cache file. The
// network call happens on the goroutine. If the user's machine is
// offline, the worst case is the goroutine times out after fetchTimeout
// and exits silently.
func (n *Notifier) MaybeAsync() {
	if n.shouldSkip() {
		return
	}

	cache, _ := ReadCache()
	if !cache.ShouldRefresh(n.TTL, n.now()) {
		// Cache is fresh — last check was within the TTL window. We
		// rely on whatever's already on disk for the eventual banner;
		// no network call needed.
		return
	}

	n.once.Do(func() {
		n.wg.Add(1)
		go func() {
			defer n.wg.Done()
			n.refreshCache(context.Background())
		}()
	})
}

// Drain blocks until any in-flight async refresh finishes, bounded by
// the provided timeout. Called from `Execute()` right before printing
// the banner so the notice reflects the freshest data we could
// reasonably get within the user's patience window.
//
// If the goroutine takes longer than `timeout`, Drain returns and the
// banner uses whatever was previously cached. Production timeout is
// short (250ms by default in the caller) — we'd rather show a slightly
// stale notice than make `capfire deploy` feel sluggish on shutdown.
func (n *Notifier) Drain(timeout time.Duration) {
	if timeout <= 0 {
		n.wg.Wait()
		return
	}

	done := make(chan struct{})
	go func() {
		n.wg.Wait()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(timeout):
		// Goroutine still running — let it finish in the background.
		// It'll write the cache for the NEXT invocation; this
		// invocation just won't benefit from it.
	}
}

// MaybePrint writes the "update available" banner to `w` if the cache
// indicates a newer version is out. Safe to call when the check was
// skipped or failed: it falls through silently in either case.
//
// The banner uses Stderr by convention (caller passes os.Stderr) so
// scripts that pipe Capfire's stdout — `capfire deployments | grep ...`
// — never have their pipeline contaminated by an interactive notice.
func (n *Notifier) MaybePrint(w io.Writer) {
	if n.shouldSkip() {
		return
	}

	cache, _ := ReadCache()
	if cache == nil || cache.LatestVersion == "" {
		return
	}

	// If the binary was upgraded since we last cached, the recorded
	// "latest" might actually equal the new current — in which case
	// we have nothing useful to say. Bail out and let the next stale
	// refresh repopulate the cache.
	if cache.CurrentVersionWhenChecked != n.Current {
		return
	}

	if !IsNewer(cache.LatestVersion, n.Current) {
		return
	}

	fmt.Fprintln(w)
	fmt.Fprintf(w, "A new version of capfire is available: %s (you have %s)\n",
		cache.LatestVersion, n.Current)
	fmt.Fprintln(w, "Update with: brew upgrade capfire")
}

// shouldSkip centralizes every "do nothing" condition so MaybeAsync,
// MaybePrint, and any future entry points stay consistent. Each branch
// is a configuration concern, not a runtime concern — so we deliberately
// don't log or surface why we skipped.
func (n *Notifier) shouldSkip() bool {
	if n == nil {
		return true
	}
	if n.Disabled {
		return true
	}
	if IsDisabled() {
		return true
	}
	if IsDevBuild(n.Current) {
		return true
	}
	return false
}

// refreshCache hits the network and writes the result to disk. Errors
// are deliberately swallowed: a failed fetch must not surface to the
// user (they're trying to deploy, not debug GitHub's API). The cache's
// CheckedAt timestamp is updated even on a non-success response that
// returned an empty tag, so we don't hammer GitHub on every command if
// the repo has no releases yet.
func (n *Notifier) refreshCache(ctx context.Context) {
	tag, err := n.fetcher(ctx)
	if err != nil {
		return
	}

	cache := &Cache{
		CheckedAt:                 n.now(),
		LatestVersion:             tag,
		CurrentVersionWhenChecked: n.Current,
	}
	_ = WriteCache(cache)
}

// CheckSync runs a synchronous, network-bound check that bypasses the
// cache. Used by `capfire version` to give the user a definitive answer
// when they explicitly ask. Returns the latest tag (which may equal
// `Current`) or an error explaining why the check failed.
//
// Unlike MaybeAsync this DOES surface errors — the user invoked a
// "tell me what version is out there" command, they want a real answer
// or a real failure message.
func (n *Notifier) CheckSync(ctx context.Context) (string, error) {
	if IsDisabled() {
		return "", fmt.Errorf("update check disabled via %s", DisabledEnv)
	}
	if IsDevBuild(n.Current) {
		return "", fmt.Errorf("dev build — version unknown")
	}
	tag, err := n.fetcher(ctx)
	if err != nil {
		return "", err
	}
	if tag != "" {
		// Best-effort: keep the cache in sync with what we just
		// learned, so the async path can skip the next refresh.
		_ = WriteCache(&Cache{
			CheckedAt:                 n.now(),
			LatestVersion:             tag,
			CurrentVersionWhenChecked: n.Current,
		})
	}
	return tag, nil
}
