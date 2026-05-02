package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/ricardo5401/capfire/client/internal/api"
	"github.com/ricardo5401/capfire/client/internal/ui"
)

var (
	deploymentsApp     string
	deploymentsEnv     string
	deploymentsStatus  string
	deploymentsLimit   int
	deploymentsPage    int
	deploymentsPerPage int
	deploymentsAll     bool
)

var deploymentsCmd = &cobra.Command{
	Use:     "deployments",
	Aliases: []string{"deploys", "list"},
	Short:   "List deploys (yours by default; use --all for the team's)",
	Long: `Lists deploys associated with your token. By default shows only what YOU
triggered (matched on the JWT ` + "`sub`" + ` claim).

Use --all to see every deploy on apps you have any permission on. That's
the right flag for "what is my teammate deploying right now". The server
applies the same visibility rule to ` + "`capfire status ID`" + ` and the abort
endpoint, so anything you can see in this list, you can also inspect.

Pagination: results are paginated (default 20 per page). Use --page to
navigate to older deploys; use --per-page to change the page size up to
the server cap of 100. The footer tells you the current page and total.

Examples:
  capfire deployments
  capfire deployments --all
  capfire deployments --page=2
  capfire deployments --per-page=50
  capfire deployments --all --app=myapp --status=running
  capfire deployments --status=failed`,
	RunE: runDeployments,
}

func init() {
	deploymentsCmd.Flags().BoolVar(&deploymentsAll, "all", false, "Show deploys from every app you have access to (not just yours)")
	deploymentsCmd.Flags().StringVar(&deploymentsApp, "app", "", "Filter by app")
	deploymentsCmd.Flags().StringVar(&deploymentsEnv, "env", "", "Filter by environment")
	deploymentsCmd.Flags().StringVar(&deploymentsStatus, "status", "", "Filter by status (pending|running|success|failed|canceled)")
	deploymentsCmd.Flags().IntVar(&deploymentsPage, "page", 1, "1-based page number")
	deploymentsCmd.Flags().IntVar(&deploymentsPerPage, "per-page", 20, "Rows per page (server caps at 100)")
	// `--limit` predates pagination. We keep it as a hidden alias for
	// `--per-page` so existing scripts and aliases keep working without
	// littering the help output. Users discovering the new flag from
	// docs will pick `--per-page`.
	deploymentsCmd.Flags().IntVar(&deploymentsLimit, "limit", 0, "Deprecated alias for --per-page")
	_ = deploymentsCmd.Flags().MarkHidden("limit")
	Root.AddCommand(deploymentsCmd)
}

func runDeployments(_ *cobra.Command, _ []string) error {
	client, _, err := loadClient()
	if err != nil {
		return err
	}

	ctx, cancel := withSignals()
	defer cancel()

	// Resolve per-page: explicit --limit beats the default --per-page so
	// `capfire deployments --limit=50` keeps working even though
	// --per-page also has a default value of 20. We never send BOTH to
	// the server; --per-page is the canonical wire param.
	perPage := deploymentsPerPage
	if deploymentsLimit > 0 {
		perPage = deploymentsLimit
	}

	list, err := client.ListDeploys(ctx, api.ListDeploysParams{
		All:     deploymentsAll,
		App:     deploymentsApp,
		Env:     deploymentsEnv,
		Status:  deploymentsStatus,
		Page:    deploymentsPage,
		PerPage: perPage,
	})
	if err != nil {
		return err
	}
	if len(list.Deploys) == 0 {
		ui.Infof("No deploys found for the given filters.")
		// Still surface the hint when the list is empty so users in
		// "mine" mode discover --all even before they have any deploys.
		printScopeHint(list.Hint)
		printPaginationFooter(list.Pagination, "deployments")
		return nil
	}
	printDeployTable(list.Deploys)
	printScopeHint(list.Hint)
	printPaginationFooter(list.Pagination, "deployments")
	return nil
}

// printScopeHint writes the server's hint to stderr (so it doesn't pollute
// stdout-piped table output). The server only sets `hint` in "mine" mode,
// so users running with --all never see the noise.
func printScopeHint(hint string) {
	if hint == "" {
		return
	}
	fmt.Fprintf(os.Stderr, "\n%s %s\n", ui.Bold("Tip:"), hint)
}

// printPaginationFooter renders a one-line summary of where the current
// page sits in the result set. Stays silent when the entire result set
// fits on a single page — that's the common "I have 5 deploys" case
// where a footer would just be visual noise.
//
// `commandHint` is the subcommand name we tell the user to re-run with a
// different page (e.g. "deployments" or "tasks") so the footer stays
// useful when shared across listings.
func printPaginationFooter(p *api.Pagination, commandHint string) {
	if p == nil || p.TotalPages <= 1 {
		return
	}

	first := (p.Page-1)*p.PerPage + 1
	last := first + p.PerPage - 1
	if last > p.TotalCount {
		last = p.TotalCount
	}

	fmt.Fprintf(os.Stderr, "\n%s page %d of %d (showing %d-%d of %d)\n",
		ui.Bold("›"),
		p.Page, p.TotalPages,
		first, last, p.TotalCount,
	)

	// Only suggest a next-page command if there IS one — saves the user
	// the disappointment of running the suggestion and getting an empty
	// list back.
	if p.Page < p.TotalPages {
		fmt.Fprintf(os.Stderr, "  next: capfire %s --page=%d\n", commandHint, p.Page+1)
	}
}
