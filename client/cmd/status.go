package cmd

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"github.com/ricardo5401/capfire/client/internal/api"
	"github.com/ricardo5401/capfire/client/internal/ui"
)

var (
	statusShowLog bool
	statusTail    int
)

var statusCmd = &cobra.Command{
	Use:   "status [DEPLOY_ID]",
	Short: "Show status of a deploy (or list your active deploys)",
	Long: `Without arguments: lists the deploys you triggered that are currently pending
or running.

With a deploy id: fetches full status + exit code, and optionally prints the
last N log lines (--log, --tail).

Examples:
  capfire status
  capfire status 42
  capfire status 42 --log --tail=100`,
	Args: cobra.MaximumNArgs(1),
	RunE: runStatus,
}

func init() {
	statusCmd.Flags().BoolVar(&statusShowLog, "log", false, "Print the deploy log (only when DEPLOY_ID is given)")
	statusCmd.Flags().IntVar(&statusTail, "tail", 100, "Number of log lines to show when --log is set (0 = all)")
	Root.AddCommand(statusCmd)
}

func runStatus(_ *cobra.Command, args []string) error {
	client, _, err := loadClient()
	if err != nil {
		return err
	}

	ctx, cancel := withSignals()
	defer cancel()

	if len(args) == 0 {
		return listActive(ctx, client)
	}

	id, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("invalid deploy id %q: must be a number", args[0])
	}
	return showOne(ctx, client, id)
}

func listActive(ctx context.Context, client *api.Client) error {
	deploys, err := client.ListDeploys(ctx, api.ListDeploysParams{Active: true, Limit: 20})
	if err != nil {
		return err
	}
	if len(deploys) == 0 {
		ui.Infof("No active deploys for this token.")
		return nil
	}
	printDeployTable(deploys)
	return nil
}

func showOne(ctx context.Context, client *api.Client, id int) error {
	d, err := client.GetDeploy(ctx, id)
	if err != nil {
		return err
	}

	fmt.Printf("%s %s\n", ui.Bold("Deploy:  "), fmt.Sprintf("#%d", d.ID))
	fmt.Printf("%s %s %s\n", ui.Bold("Status:  "), ui.StatusGlyph(d.Status), ui.ColoredStatus(d.Status))
	fmt.Printf("%s %s\n", ui.Bold("App:     "), d.App)
	fmt.Printf("%s %s\n", ui.Bold("Env:     "), d.Env)
	fmt.Printf("%s %s\n", ui.Bold("Branch:  "), d.Branch)
	fmt.Printf("%s %s\n", ui.Bold("Command: "), d.Command)
	fmt.Printf("%s %s\n", ui.Bold("By:      "), d.TriggeredBy)
	fmt.Printf("%s %s\n", ui.Bold("Started: "), valueOrDash(d.StartedAt))
	fmt.Printf("%s %s\n", ui.Bold("Finish:  "), valueOrDash(d.FinishedAt))
	fmt.Printf("%s %s\n", ui.Bold("Took:    "), ui.Duration(d.DurationSeconds))
	if d.ExitCode != nil {
		fmt.Printf("%s %d\n", ui.Bold("Exit:    "), *d.ExitCode)
	}

	if statusShowLog && d.Log != "" {
		fmt.Println()
		fmt.Println(ui.Bold("Log:"))
		fmt.Println(tailLog(d.Log, statusTail))
	}
	return nil
}

// tailLog returns the last `n` lines of log. n<=0 means all.
func tailLog(log string, n int) string {
	if n <= 0 {
		return log
	}
	lines := strings.Split(log, "\n")
	if len(lines) <= n {
		return log
	}
	return strings.Join(lines[len(lines)-n:], "\n")
}

// printDeployTable is shared with the `deployments` command.
func printDeployTable(deploys []api.Deploy) {
	w := ui.NewTable(os.Stdout)
	fmt.Fprintln(w, "ID\tSTATUS\tAPP\tENV\tBRANCH\tCMD\tAGE\tTOOK")
	for _, d := range deploys {
		fmt.Fprintf(w, "%d\t%s %s\t%s\t%s\t%s\t%s\t%s\t%s\n",
			d.ID,
			ui.StatusGlyph(d.Status), ui.ColoredStatus(d.Status),
			d.App, d.Env, d.Branch, d.Command,
			ui.RelTime(d.StartedAt),
			ui.Duration(d.DurationSeconds),
		)
	}
	w.Flush()
}
