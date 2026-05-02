package cmd

import (
	"fmt"
	"strconv"

	"github.com/spf13/cobra"

	"github.com/ricardo5401/capfire/client/internal/ui"
)

var abortReason string

// abortCmd is a parent that hosts `abort deploy` and `abort task`. We
// keep them as separate sub-subcommands (instead of a single
// `capfire abort ID`) because deploys and tasks have independent ID
// spaces — id 42 might be a Deploy AND a TaskRun, and asking the server
// to disambiguate would either need a third "kind" arg or a guess that
// can silently cancel the wrong thing.
var abortCmd = &cobra.Command{
	Use:   "abort",
	Short: "Cancel a running deploy or task",
	Long: `Signals the running shell on the server (process group SIGTERM, then
SIGKILL after a 10s grace period) and transitions the record to ` + "`canceled`" + `.
Idempotent: aborting an already-finished run is a no-op (200 with
abort_status="already_finished").

Permissions: you can always abort runs YOU triggered. Aborting someone
else's run requires ` + "`cmd: \"abort\"`" + ` on the app+env in your token's grants.

Examples:
  capfire abort deploy 42
  capfire abort task 87 --reason "wrong branch"
`,
}

var abortDeployCmd = &cobra.Command{
	Use:   "deploy DEPLOY_ID",
	Short: "Cancel a running deploy",
	Args:  cobra.ExactArgs(1),
	RunE:  runAbortDeploy,
}

var abortTaskCmd = &cobra.Command{
	Use:   "task TASK_RUN_ID",
	Short: "Cancel a running task",
	Args:  cobra.ExactArgs(1),
	RunE:  runAbortTask,
}

func init() {
	abortCmd.PersistentFlags().StringVar(&abortReason, "reason", "",
		"Optional human-readable reason; appended to the run's audit log")

	abortCmd.AddCommand(abortDeployCmd)
	abortCmd.AddCommand(abortTaskCmd)
	Root.AddCommand(abortCmd)
}

func runAbortDeploy(_ *cobra.Command, args []string) error {
	id, err := parseID(args[0], "deploy")
	if err != nil {
		return err
	}

	client, _, err := loadClient()
	if err != nil {
		return err
	}

	ctx, cancel := withSignals()
	defer cancel()

	d, err := client.AbortDeploy(ctx, id, abortReason)
	if err != nil {
		return err
	}
	printAbortResult(abortSummary{
		kind:        "deploy",
		id:          d.ID,
		app:         d.App,
		env:         d.Env,
		label:       d.Command,
		status:      d.Status,
		abortStatus: d.AbortStatus,
		exitCode:    d.AbortExitCode,
	})
	return nil
}

func runAbortTask(_ *cobra.Command, args []string) error {
	id, err := parseID(args[0], "task_run")
	if err != nil {
		return err
	}

	client, _, err := loadClient()
	if err != nil {
		return err
	}

	ctx, cancel := withSignals()
	defer cancel()

	t, err := client.AbortTask(ctx, id, abortReason)
	if err != nil {
		return err
	}
	printAbortResult(abortSummary{
		kind:        "task",
		id:          t.ID,
		app:         t.App,
		env:         t.Env,
		label:       t.Task,
		status:      t.Status,
		abortStatus: t.AbortStatus,
		exitCode:    t.AbortExitCode,
	})
	return nil
}

// abortSummary normalizes the bits both flavors print so the formatting
// stays in one place. `label` is the deploy command name ("deploy",
// "restart", ...) for deploys, or the task name for tasks.
type abortSummary struct {
	kind        string
	id          int
	app         string
	env         string
	label       string
	status      string
	abortStatus string
	exitCode    *int
}

func printAbortResult(s abortSummary) {
	switch s.abortStatus {
	case "canceled":
		ui.Successf("%s #%d canceled (%s/%s %s)", capitalize(s.kind), s.id, s.app, s.env, s.label)
	case "already_finished":
		ui.Warnf("%s #%d was already %s — nothing to abort", capitalize(s.kind), s.id, s.status)
	default:
		// Future-proof: don't pretend to know the outcome if the server
		// adds a new abort_status value we don't recognize yet.
		ui.Infof("%s #%d abort_status=%s status=%s", capitalize(s.kind), s.id, s.abortStatus, s.status)
	}
	if s.exitCode != nil {
		fmt.Printf("  exit code: %d %s\n", *s.exitCode, exitCodeNote(*s.exitCode))
	}
}

// exitCodeNote translates the AbortService convention (143/137/-1) to a
// short human-readable note. Keeps the user from having to remember Linux
// signal arithmetic.
func exitCodeNote(code int) string {
	switch code {
	case 143:
		return "(SIGTERM — process exited cleanly within grace period)"
	case 137:
		return "(SIGKILL — had to force-kill after grace period)"
	case -1:
		return "(no live process — orphan lock cleared)"
	default:
		return ""
	}
}

func parseID(raw, label string) (int, error) {
	id, err := strconv.Atoi(raw)
	if err != nil {
		return 0, fmt.Errorf("invalid %s id %q: must be a number", label, raw)
	}
	return id, nil
}

func capitalize(s string) string {
	if s == "" {
		return s
	}
	return string(s[0]-32) + s[1:]
}
