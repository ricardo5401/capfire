package cmd

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/uDocz/capfire/client/internal/api"
	"github.com/uDocz/capfire/client/internal/ui"
)

var (
	deployAsync  bool
	deploySkipLB bool
)

var deployCmd = &cobra.Command{
	Use:   "deploy APP ENV [BRANCH]",
	Short: "Deploy an app to an environment",
	Long: `Triggers a deploy on the Capfire server.

Without --async, streams the deploy log in real time over SSE; exit code
matches the deploy's exit code. With --async, queues the deploy and returns
immediately with a track URL you can poll via ` + "`capfire status ID`" + `.

Examples:
  capfire deploy udoczcom production master
  capfire deploy udoczcom staging feature-x --async
  capfire deploy udoczcom production master --skip-lb`,
	Args: cobra.RangeArgs(2, 3),
	RunE: runDeploy,
}

func init() {
	deployCmd.Flags().BoolVar(&deployAsync, "async", false, "Return immediately instead of streaming logs")
	deployCmd.Flags().BoolVar(&deploySkipLB, "skip-lb", false, "Skip Cloudflare LB drain/restore for this deploy")
	Root.AddCommand(deployCmd)
}

func runDeploy(_ *cobra.Command, args []string) error {
	app, env := args[0], args[1]
	branch := "main"
	if len(args) == 3 {
		branch = args[2]
	}

	client, _, err := loadClient()
	if err != nil {
		return err
	}

	ctx, cancel := withSignals()
	defer cancel()

	req := api.DeployRequest{App: app, Env: env, Branch: branch, SkipLB: deploySkipLB}

	if deployAsync {
		ack, err := client.CreateDeployAsync(ctx, req)
		if err != nil {
			return err
		}
		ui.Successf("Deploy queued: #%d (%s)", ack.DeployID, ack.Status)
		fmt.Printf("  app:    %s\n", ack.App)
		fmt.Printf("  env:    %s\n", ack.Env)
		fmt.Printf("  branch: %s\n", ack.Branch)
		fmt.Println()
		fmt.Printf("Track progress with:  %s\n", ui.Bold(fmt.Sprintf("capfire status %d", ack.DeployID)))
		fmt.Printf("Tail the log with:    %s\n", ui.Bold(fmt.Sprintf("capfire status %d --log", ack.DeployID)))
		return nil
	}

	ui.Infof("Deploying %s@%s to %s …", app, branch, env)
	exitCode, err := client.StreamDeploy(ctx, req, streamPrinter())
	if err != nil {
		return err
	}
	if exitCode != 0 {
		return fmt.Errorf("deploy failed (exit code %d)", exitCode)
	}
	ui.Successf("Deploy finished successfully")
	return nil
}

// streamPrinter returns a handler that pretty-prints SSE events.
func streamPrinter() api.StreamHandler {
	return func(event string, payload map[string]any) error {
		switch event {
		case "log":
			if line, ok := payload["line"].(string); ok {
				fmt.Println(line)
			}
		case "info":
			if msg, ok := payload["message"].(string); ok {
				ui.Infof("%s", msg)
			}
		case "error":
			if msg, ok := payload["message"].(string); ok {
				ui.Errorf("%s", msg)
			}
		case "done":
			// Success/failure banner is printed by the caller using the
			// returned exit code. `done` arrives once and closes the stream.
		}
		return nil
	}
}
