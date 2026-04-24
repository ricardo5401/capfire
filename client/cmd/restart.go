package cmd

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/capfire-project/capfire/client/internal/api"
	"github.com/capfire-project/capfire/client/internal/ui"
)

var restartAsync bool

var restartCmd = &cobra.Command{
	Use:   "restart APP ENV",
	Short: "Restart an app in an environment",
	Long: `Runs the ` + "`restart`" + ` command on the Capfire server (whatever the app's
capfire.yml resolves — typically ` + "`cap ENV deploy:restart`" + `).

Streams log output by default. Use --async to queue and return immediately.

Example:
  capfire restart myapp production`,
	Args: cobra.ExactArgs(2),
	RunE: runRestart,
}

func init() {
	restartCmd.Flags().BoolVar(&restartAsync, "async", false, "Return immediately instead of streaming logs")
	Root.AddCommand(restartCmd)
}

func runRestart(_ *cobra.Command, args []string) error {
	app, env := args[0], args[1]

	client, _, err := loadClient()
	if err != nil {
		return err
	}

	ctx, cancel := withSignals()
	defer cancel()

	req := api.CommandRequest{App: app, Env: env, Cmd: "restart"}

	if restartAsync {
		ack, err := client.RunCommandAsync(ctx, req)
		if err != nil {
			return err
		}
		ui.Successf("Restart queued: #%d (%s)", ack.DeployID, ack.Status)
		fmt.Println()
		fmt.Printf("Track progress with:  %s\n", ui.Bold(fmt.Sprintf("capfire status %d", ack.DeployID)))
		fmt.Printf("Tail the log with:    %s\n", ui.Bold(fmt.Sprintf("capfire status %d --log", ack.DeployID)))
		return nil
	}

	ui.Infof("Restarting %s in %s …", app, env)
	exitCode, err := client.StreamCommand(ctx, req, streamPrinter())
	if err != nil {
		return err
	}
	if exitCode != 0 {
		return fmt.Errorf("restart failed (exit code %d)", exitCode)
	}
	ui.Successf("Restart finished successfully")
	return nil
}
