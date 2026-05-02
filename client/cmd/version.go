package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/ricardo5401/capfire/client/internal/ui"
	"github.com/ricardo5401/capfire/client/internal/version"
)

var versionCheck bool

// versionCmd surfaces the build version (already exposed via `--version`
// at the root level) and adds an optional --check flag that hits the
// GitHub Releases API SYNCHRONOUSLY, bypassing the 24h cache. Useful for
// "hey, what's the absolute latest?" without having to wait a day for
// the background pipeline to refresh.
//
// We expose this as a real subcommand (not just `--version`) so the
// flag can carry its own help text and the output can be richer when
// the user explicitly asked.
var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Print the capfire version",
	Long: `Prints the version this binary was built from.

With --check, also queries GitHub for the latest release and reports
whether you're up to date. The synchronous check ignores the 24h cache
that powers the implicit "update available" banner shown after every
command.

Examples:
  capfire version
  capfire version --check`,
	RunE: runVersion,
}

func init() {
	versionCmd.Flags().BoolVar(&versionCheck, "check", false,
		"Synchronously query GitHub for the latest release")
	Root.AddCommand(versionCmd)
}

func runVersion(_ *cobra.Command, _ []string) error {
	// Match the format Cobra emits for `--version` (`capfire version X`)
	// so users don't see two different shapes for the same data.
	fmt.Printf("capfire version %s\n", Version)

	if !versionCheck {
		return nil
	}

	// Suppress the async banner that Execute() prints at exit — we're
	// about to print a richer, synchronous version of the same notice
	// and don't want the user seeing it twice. We disable the package
	// notifier rather than swap it to nil so future callers (e.g. a
	// `capfire version --check && capfire deploy` chain inside the
	// same shell session) still build a fresh one for the next run.
	if updateNotifier != nil {
		updateNotifier.Disabled = true
	}

	// Reuse the package notifier so the check writes through to the
	// same cache the implicit banner reads from. That way, if the user
	// runs `capfire version --check` and then immediately `capfire
	// deploy`, the deploy command sees the freshly-updated cache and
	// doesn't re-fetch.
	n := ensureNotifier()
	ctx, cancel := withSignals()
	defer cancel()

	tag, err := n.CheckSync(ctx)
	if err != nil {
		// The user explicitly asked, so the failure is theirs to see.
		// We deliberately do NOT exit non-zero: this command's main
		// purpose was to print the version, which we already did.
		ui.Warnf("could not check latest release: %s", err.Error())
		return nil
	}

	if tag == "" {
		// API returned 404 — repo has no releases yet.
		fmt.Fprintln(os.Stdout, "No releases published yet on GitHub.")
		return nil
	}

	if version.IsNewer(tag, Version) {
		ui.Warnf("a newer release is available: %s", tag)
		fmt.Println("Update with: brew upgrade capfire")
		return nil
	}

	ui.Successf("you are on the latest release (%s)", tag)
	return nil
}
