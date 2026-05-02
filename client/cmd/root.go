// Package cmd wires the Cobra command tree for the capfire developer CLI.
package cmd

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"github.com/ricardo5401/capfire/client/internal/api"
	"github.com/ricardo5401/capfire/client/internal/config"
	"github.com/ricardo5401/capfire/client/internal/ui"
	"github.com/ricardo5401/capfire/client/internal/version"
)

// Version is injected at build time via `-ldflags "-X .../cmd.Version=..."`.
var Version = "dev"

// updateNotifier is shared across the lifetime of a single `capfire`
// invocation: PersistentPreRunE kicks off a background refresh, the
// command runs, and Execute drains+prints the banner before exit.
//
// It's a package var (not built per-call) so tests can swap it in if
// they ever need to. In production the value is set by the first call
// to ensureNotifier, lazily — that gives us time to read the config
// file before deciding whether to enable the feature.
var updateNotifier *version.Notifier

// drainTimeout is how long Execute() waits for the background fetch to
// finish before printing whatever's already in the cache. 1s is a
// pragmatic ceiling: most `capfire` commands run for seconds or
// minutes (deploys, streaming logs) so adding up to a second at exit
// is imperceptible. For the few "instant" commands like `capfire
// permission`, 1s is the worst case BEFORE the banner shows up — and
// from the second invocation onward the cache is warm and the drain
// returns immediately.
const drainTimeout = 1 * time.Second

// Root is the top-level `capfire` command.
var Root = &cobra.Command{
	Use:           "capfire",
	Short:         "Capfire deploy client",
	Long:          "Capfire is a JWT-authenticated deploy orchestrator. This CLI talks to a Capfire server over HTTP.",
	SilenceUsage:  true,
	SilenceErrors: true,
	Version:       Version,

	// PersistentPreRun fires before EVERY subcommand. We use it as the
	// hook to kick off the background version check — it never blocks,
	// so even commands that don't talk to the server (`capfire config`,
	// `capfire --help`) benefit from the freshness window without
	// paying any latency.
	PersistentPreRun: func(_ *cobra.Command, _ []string) {
		ensureNotifier().MaybeAsync()
	},
}

// Execute runs the root command. Errors are printed via ui helpers so the
// output stays uniform across subcommands. Before returning we drain the
// background version check and print the banner if a newer release is
// available — done here (not in PersistentPostRun) so it fires even
// when the command itself errored out, which is precisely when users
// most need to know "by the way, you're on an old version".
func Execute() error {
	err := Root.Execute()

	if n := updateNotifier; n != nil {
		n.Drain(drainTimeout)
		n.MaybePrint(os.Stderr)
	}

	if err != nil {
		ui.Errorf("%s", err.Error())
		if api.IsUnauthorized(err) {
			ui.Warnf("Your token was rejected. Check `capfire permission` or re-run `capfire config`.")
		}
		return err
	}
	return nil
}

// ensureNotifier lazily builds the package-level Notifier on first use.
// The lazy construction lets us read the user's config (which may opt
// out of the check) before the goroutine is started.
//
// Config-load failures are intentionally ignored: a fresh install with
// no config file should still benefit from the check, and a parse error
// is the user's main problem to fix — we won't compound it by spamming
// "couldn't load config" warnings ahead of every command.
func ensureNotifier() *version.Notifier {
	if updateNotifier != nil {
		return updateNotifier
	}
	n := version.NewNotifier(Version)
	if cfg, err := config.Load(); err == nil && cfg != nil {
		n.Disabled = !cfg.UpdateCheckEnabled()
	}
	updateNotifier = n
	return n
}

// withSignals returns a context that cancels on SIGINT/SIGTERM. Every
// command that talks to the server should use it so Ctrl+C aborts cleanly.
func withSignals() (context.Context, context.CancelFunc) {
	return signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
}

// loadClient reads the on-disk config and wraps it in an api.Client. Prints
// a friendly hint when the file is missing.
func loadClient() (*api.Client, *config.Config, error) {
	cfg, err := config.Load()
	if errors.Is(err, config.ErrNotConfigured) {
		return nil, nil, fmt.Errorf("not configured — run `capfire config` first")
	}
	if err != nil {
		return nil, nil, err
	}
	if err := cfg.Validate(); err != nil {
		return nil, nil, err
	}
	return api.New(cfg.Host, cfg.Token), cfg, nil
}
