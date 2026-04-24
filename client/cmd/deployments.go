package cmd

import (
	"github.com/spf13/cobra"

	"github.com/ricardo5401/capfire/client/internal/api"
	"github.com/ricardo5401/capfire/client/internal/ui"
)

var (
	deploymentsApp    string
	deploymentsEnv    string
	deploymentsStatus string
	deploymentsLimit  int
)

var deploymentsCmd = &cobra.Command{
	Use:     "deployments",
	Aliases: []string{"deploys", "list"},
	Short:   "List deploys you have triggered",
	Long: `Lists the most recent deploys associated with your token (by sub claim).
Filter by app/env/status or increase the limit as needed.

Examples:
  capfire deployments
  capfire deployments --app=myapp --limit=50
  capfire deployments --status=failed`,
	RunE: runDeployments,
}

func init() {
	deploymentsCmd.Flags().StringVar(&deploymentsApp, "app", "", "Filter by app")
	deploymentsCmd.Flags().StringVar(&deploymentsEnv, "env", "", "Filter by environment")
	deploymentsCmd.Flags().StringVar(&deploymentsStatus, "status", "", "Filter by status (pending|running|success|failed)")
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

	deploys, err := client.ListDeploys(ctx, api.ListDeploysParams{
		App:    deploymentsApp,
		Env:    deploymentsEnv,
		Status: deploymentsStatus,
		Limit:  deploymentsLimit,
	})
	if err != nil {
		return err
	}
	if len(deploys) == 0 {
		ui.Infof("No deploys found for the given filters.")
		return nil
	}
	printDeployTable(deploys)
	return nil
}
