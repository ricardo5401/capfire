package cmd

import (
	"context"
	"fmt"
	"os"
	"strconv"

	"github.com/spf13/cobra"

	"github.com/ricardo5401/capfire/client/internal/api"
	"github.com/ricardo5401/capfire/client/internal/ui"
)

var (
	taskShowLog bool
	taskTail    int
	taskActive  bool
	taskApp     string
	taskEnvFlag string
	taskName    string
	taskLimit   int
)

var taskCmd = &cobra.Command{
	Use:   "task [TASK_RUN_ID]",
	Short: "Show status of a task run (or list your active tasks)",
	Long: `Without arguments: lists task runs you triggered that are currently pending
or running, similar to ` + "`capfire status`" + ` but for tasks.

With a task_run id: fetches full status + exit code, and optionally prints
the captured log (--log, --tail).

Examples:
  capfire task                          # list your active tasks
  capfire task --app pyworker           # filter the list
  capfire task 87                       # detail of one
  capfire task 87 --log --tail 200`,
	Args: cobra.MaximumNArgs(1),
	RunE: runTask,
}

func init() {
	taskCmd.Flags().BoolVar(&taskShowLog, "log", false, "Print the task run log (only when TASK_RUN_ID is given)")
	taskCmd.Flags().IntVar(&taskTail, "tail", 100, "Number of log lines to show when --log is set (0 = all)")
	taskCmd.Flags().BoolVar(&taskActive, "active", true, "Filter the list to active runs only (no effect with TASK_RUN_ID)")
	taskCmd.Flags().StringVar(&taskApp, "app", "", "Filter list by app")
	taskCmd.Flags().StringVar(&taskEnvFlag, "env", "", "Filter list by env")
	taskCmd.Flags().StringVar(&taskName, "task", "", "Filter list by task name")
	taskCmd.Flags().IntVar(&taskLimit, "limit", 20, "Max rows to list (server caps at 100)")
	Root.AddCommand(taskCmd)
}

func runTask(_ *cobra.Command, args []string) error {
	client, _, err := loadClient()
	if err != nil {
		return err
	}

	ctx, cancel := withSignals()
	defer cancel()

	if len(args) == 0 {
		return listTaskRuns(ctx, client)
	}

	id, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("invalid task_run id %q: must be a number", args[0])
	}
	return showOneTaskRun(ctx, client, id)
}

func listTaskRuns(ctx context.Context, client *api.Client) error {
	tasks, err := client.ListTasks(ctx, api.ListTasksParams{
		Active: taskActive,
		App:    taskApp,
		Env:    taskEnvFlag,
		Task:   taskName,
		Limit:  taskLimit,
	})
	if err != nil {
		return err
	}
	if len(tasks) == 0 {
		ui.Infof("No matching task runs for this token.")
		return nil
	}
	printTaskRunTable(tasks)
	return nil
}

func showOneTaskRun(ctx context.Context, client *api.Client, id int) error {
	tr, err := client.GetTask(ctx, id)
	if err != nil {
		return err
	}

	fmt.Printf("%s %s\n", ui.Bold("Task:    "), fmt.Sprintf("#%d", tr.ID))
	fmt.Printf("%s %s %s\n", ui.Bold("Status:  "), ui.StatusGlyph(tr.Status), ui.ColoredStatus(tr.Status))
	fmt.Printf("%s %s\n", ui.Bold("App:     "), tr.App)
	fmt.Printf("%s %s\n", ui.Bold("Env:     "), tr.Env)
	fmt.Printf("%s %s\n", ui.Bold("Name:    "), tr.Task)
	fmt.Printf("%s %s\n", ui.Bold("Branch:  "), tr.Branch)
	if len(tr.Args) > 0 {
		fmt.Printf("%s %s\n", ui.Bold("Args:    "), formatArgs(tr.Args))
	}
	fmt.Printf("%s %s\n", ui.Bold("By:      "), tr.TriggeredBy)
	fmt.Printf("%s %s\n", ui.Bold("Started: "), valueOrDash(tr.StartedAt))
	fmt.Printf("%s %s\n", ui.Bold("Finish:  "), valueOrDash(tr.FinishedAt))
	fmt.Printf("%s %s\n", ui.Bold("Took:    "), ui.Duration(tr.DurationSeconds))
	if tr.ExitCode != nil {
		fmt.Printf("%s %d\n", ui.Bold("Exit:    "), *tr.ExitCode)
	}

	if taskShowLog && tr.Log != "" {
		fmt.Println()
		fmt.Println(ui.Bold("Log:"))
		fmt.Println(tailLog(tr.Log, taskTail))
	}
	return nil
}

func printTaskRunTable(tasks []api.TaskRun) {
	w := ui.NewTable(os.Stdout)
	fmt.Fprintln(w, "ID\tSTATUS\tAPP\tENV\tTASK\tBRANCH\tAGE\tTOOK")
	for _, t := range tasks {
		fmt.Fprintf(w, "%d\t%s %s\t%s\t%s\t%s\t%s\t%s\t%s\n",
			t.ID,
			ui.StatusGlyph(t.Status), ui.ColoredStatus(t.Status),
			t.App, t.Env, t.Task, t.Branch,
			ui.RelTime(t.StartedAt),
			ui.Duration(t.DurationSeconds),
		)
	}
	_ = w.Flush()
	// Hint at the detail subcommand once at the end so users discover it.
	if len(tasks) > 0 {
		fmt.Fprintf(os.Stderr, "\nUse `capfire task <ID>` for full detail (add --log for output).\n")
	}
}
