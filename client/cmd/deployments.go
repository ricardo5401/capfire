package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/ricardo5401/capfire/client/internal/api"
	"github.com/ricardo5401/capfire/client/internal/ui"
)

var (
	deploymentsApp    string
	deploymentsEnv    string
	deploymentsStatus string
	deploymentsLimit  int
	deploymentsAll    bool
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

Examples:
  capfire deployments
  capfire deployments --all
  capfire deployments --all --app=myapp --status=running
  capfire deployments --status=failed`,
	RunE: runDeployments,
}

func init() {
	deploymentsCmd.Flags().BoolVar(&deploymentsAll, "all", false, "Show deploys from every app you have access to (not just yours)")
	deploymentsCmd.Flags().StringVar(&deploymentsApp, "app", "", "Filter by app")
	deploymentsCmd.Flags().StringVar(&deploymentsEnv, "env", "", "Filter by environment")
	deploymentsCmd.Flags().StringVar(&deploymentsStatus, "status", "", "Filter by status (pending|running|success|failed|canceled)")
	deploymentsCmd.Flags().IntVar(&deploymentsLimit, "limit", 20, "Max rows to return (server caps at 100)")
	Root.AddCommand(deploymentsCmd)
}

func runDeployments(_ *cobra.Command, _ []string) error {
	client, _, err := loadClient()
	if err != nil {
		return err
	}

	ctx, cancel := withSignals()
	defer cancel()

	list, err := client.ListDeploys(ctx, api.ListDeploysParams{
		All:    deploymentsAll,
		App:    deploymentsApp,
		Env:    deploymentsEnv,
		Status: deploymentsStatus,
		Limit:  deploymentsLimit,
	})
	if err != nil {
		return err
	}
	if len(list.Deploys) == 0 {
		ui.Infof("No deploys found for the given filters.")
		// Still surface the hint when the list is empty so users in
		// "mine" mode discover --all even before they have any deploys.
		printScopeHint(list.Hint)
		return nil
	}
	printDeployTable(list.Deploys)
	printScopeHint(list.Hint)
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
