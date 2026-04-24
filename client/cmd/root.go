// Package cmd wires the Cobra command tree for the capfire developer CLI.
package cmd

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/spf13/cobra"

	"github.com/ricardo5401/capfire/client/internal/api"
	"github.com/ricardo5401/capfire/client/internal/config"
	"github.com/ricardo5401/capfire/client/internal/ui"
)

// Version is injected at build time via `-ldflags "-X .../cmd.Version=..."`.
var Version = "dev"

// Root is the top-level `capfire` command.
var Root = &cobra.Command{
	Use:           "capfire",
	Short:         "Capfire deploy client",
	Long:          "Capfire is a JWT-authenticated deploy orchestrator. This CLI talks to a Capfire server over HTTP.",
	SilenceUsage:  true,
	SilenceErrors: true,
	Version:       Version,
}

// Execute runs the root command. Errors are printed via ui helpers so the
// output stays uniform across subcommands.
func Execute() error {
	if err := Root.Execute(); err != nil {
		ui.Errorf("%s", err.Error())
		if api.IsUnauthorized(err) {
			ui.Warnf("Your token was rejected. Check `capfire permission` or re-run `capfire config`.")
		}
		return err
	}
	return nil
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
