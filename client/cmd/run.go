package cmd

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/ricardo5401/capfire/client/internal/api"
	"github.com/ricardo5401/capfire/client/internal/ui"
)

var (
	runBranch      string
	runArgs        map[string]string
	runAsync       bool
	runWait        bool
	runWaitTimeout time.Duration
	runWaitInterval time.Duration
)

// Default backoff values used when the server doesn't suggest one.
const (
	defaultWaitInterval = 30 * time.Second
	maxWaitInterval     = 2 * time.Minute
)

var runCmd = &cobra.Command{
	Use:   "run APP ENV TASK",
	Short: "Run a custom task defined in the app's capfire.yml",
	Long: `Triggers a task on the Capfire server. Tasks are user-defined commands
declared under ` + "`tasks:`" + ` in the app's ` + "`capfire.yml`" + `, plus the reserved
built-in ` + "`sync`" + ` (git fetch + checkout + reset --hard origin/<branch>, then
optional ` + "`tasks.sync.after:`" + ` hooks like ` + "`uv sync`" + ` or ` + "`bundle install`" + `).

Without --async, streams the task log in real time over SSE; exit code matches
the task's exit code. With --async, queues the task and returns immediately
with a track URL you can hit directly (the response includes track_url).

Concurrency: at most one task runs per app at a time. If another task is in
flight on the same app, the server returns 409 Conflict. Use --wait to poll
the lock until it frees and retry automatically.

The reserved ` + "`sync`" + ` task additionally cross-checks the deploy lock — it
returns 409 if a deploy is currently running on the same app, since both
operations mutate the working directory.

Examples:
  capfire run pyworker production reindex
  capfire run pyworker production sync --branch master
  capfire run pyworker production backfill --arg since=2024-01-01
  capfire run pyworker production backfill --arg since=2024-01-01 --async
  capfire run pyworker production reindex --wait
  capfire run pyworker production reindex --wait --wait-timeout 30m`,
	Args: cobra.ExactArgs(3),
	RunE: runRun,
}

func init() {
	runCmd.Flags().StringVar(&runBranch, "branch", "main", "Branch to use (relevant for `sync` and any task using %{branch})")
	runCmd.Flags().StringToStringVar(&runArgs, "arg", nil, "Task argument as key=value, repeatable (e.g. --arg since=2024-01-01)")
	runCmd.Flags().BoolVar(&runAsync, "async", false, "Return immediately instead of streaming logs")
	runCmd.Flags().BoolVar(&runWait, "wait", false, "If another task is in flight, wait for the per-app lock to free and retry")
	runCmd.Flags().DurationVar(&runWaitTimeout, "wait-timeout", 30*time.Minute, "Maximum wait duration when --wait is set (e.g. 10m, 1h)")
	runCmd.Flags().DurationVar(&runWaitInterval, "wait-interval", 0, "Override polling interval when --wait is set (default: server hint, falling back to 30s)")
	Root.AddCommand(runCmd)
}

func runRun(_ *cobra.Command, args []string) error {
	app, env, task := args[0], args[1], args[2]

	client, _, err := loadClient()
	if err != nil {
		return err
	}

	ctx, cancel := withSignals()
	defer cancel()

	req := api.TaskRequest{
		App:    app,
		Env:    env,
		Task:   task,
		Branch: runBranch,
		Args:   runArgs,
	}

	if runAsync {
		return runAsyncWithRetry(ctx, client, req)
	}
	return runStreamingWithRetry(ctx, client, req)
}

func runAsyncWithRetry(ctx context.Context, client *api.Client, req api.TaskRequest) error {
	deadline := waitDeadline()

	for {
		ack, err := client.CreateTaskAsync(ctx, req)
		if err == nil {
			printAsyncAck(ack)
			return nil
		}
		if !shouldRetry(err) {
			return err
		}
		if err := backoff(ctx, err, deadline); err != nil {
			return err
		}
	}
}

func runStreamingWithRetry(ctx context.Context, client *api.Client, req api.TaskRequest) error {
	deadline := waitDeadline()

	for {
		ui.Infof("Running task=%s on %s/%s …", req.Task, req.App, req.Env)
		exitCode, err := client.StreamTask(ctx, req, streamPrinter())
		if err == nil {
			if exitCode != 0 {
				return fmt.Errorf("task failed (exit code %d)", exitCode)
			}
			ui.Successf("Task finished successfully")
			return nil
		}
		if !shouldRetry(err) {
			return err
		}
		if err := backoff(ctx, err, deadline); err != nil {
			return err
		}
	}
}

// shouldRetry returns true when the caller asked for `--wait` and the error
// is a server-side busy signal (another task in flight, or sync vs deploy
// conflict). Anything else (auth, network, validation) bubbles up so the
// user gets the real cause.
func shouldRetry(err error) bool {
	if !runWait {
		return false
	}
	_, ok := api.IsBusy(err)
	return ok
}

// backoff prints a human-readable wait line and sleeps until the next
// retry. Sleep duration prefers the server's `retry_after_seconds` hint,
// falls back to --wait-interval (when set) or defaultWaitInterval.
func backoff(ctx context.Context, err error, deadline time.Time) error {
	be, _ := api.IsBusy(err)

	wait := chooseInterval(be)
	now := time.Now()
	if !deadline.IsZero() && now.Add(wait).After(deadline) {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return fmt.Errorf("--wait-timeout exceeded: %s", err.Error())
		}
		wait = remaining
	}

	describeBusy(be, wait)

	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func chooseInterval(be *api.BusyError) time.Duration {
	if runWaitInterval > 0 {
		return capInterval(runWaitInterval)
	}
	if be != nil && be.RetryAfterSeconds > 0 {
		return capInterval(time.Duration(be.RetryAfterSeconds) * time.Second)
	}
	return defaultWaitInterval
}

func capInterval(d time.Duration) time.Duration {
	if d > maxWaitInterval {
		return maxWaitInterval
	}
	if d < time.Second {
		return time.Second
	}
	return d
}

// waitDeadline returns the absolute time at which --wait should give up.
// Zero value when --wait isn't set (the loop runs at most once and returns
// the first error untouched).
func waitDeadline() time.Time {
	if !runWait {
		return time.Time{}
	}
	if runWaitTimeout <= 0 {
		return time.Time{} // wait forever — user asked for it explicitly
	}
	return time.Now().Add(runWaitTimeout)
}

func describeBusy(be *api.BusyError, wait time.Duration) {
	if be == nil {
		ui.Warnf("Server busy — retrying in %s", wait.Round(time.Second))
		return
	}
	switch {
	case be.ActiveDeploy != nil:
		ui.Warnf("Deploy #%d (%s) is in progress — waiting %s",
			be.ActiveDeploy.ID, be.ActiveDeploy.Command, wait.Round(time.Second))
	case be.Active != nil:
		ui.Warnf("Task #%d (%s by %s, started %s) is in progress — waiting %s",
			be.Active.TaskRunID,
			be.Active.Task,
			displayActor(be.Active.TriggeredBy),
			displayStartedAt(be.Active.StartedAt),
			wait.Round(time.Second))
	default:
		ui.Warnf("Server busy — retrying in %s", wait.Round(time.Second))
	}
}

func displayActor(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return "unknown"
	}
	return name
}

// displayStartedAt prints a relative timestamp when possible (e.g. "3m ago")
// and falls back to the raw value the server sent. Avoids dragging a
// timezone library — the server emits ISO-8601 in UTC.
func displayStartedAt(raw string) string {
	if raw == "" {
		return "just now"
	}
	t, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return raw
	}
	d := time.Since(t).Round(time.Second)
	if d < 0 {
		return raw
	}
	return d.String() + " ago"
}

func printAsyncAck(ack *api.TaskAsyncAck) {
	ui.Successf("Task queued: #%d (%s)", ack.TaskRunID, ack.Status)
	fmt.Printf("  app:    %s\n", ack.App)
	fmt.Printf("  env:    %s\n", ack.Env)
	fmt.Printf("  task:   %s\n", ack.Task)
	fmt.Printf("  branch: %s\n", ack.Branch)
	if len(ack.Args) > 0 {
		fmt.Printf("  args:   %s\n", formatArgs(ack.Args))
	}
	fmt.Println()
	if ack.TrackURL != "" {
		fmt.Printf("Track at: %s\n", ack.TrackURL)
	}
}

func formatArgs(args map[string]string) string {
	parts := make([]string, 0, len(args))
	for k, v := range args {
		parts = append(parts, fmt.Sprintf("%s=%s", k, v))
	}
	return strings.Join(parts, " ")
}

