package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
)

// TaskRun is the JSON shape returned by /tasks and /tasks/:id.
//
// Mirrors Deploy field-for-field where it makes sense, with task-specific
// extras: `task` (the user-defined name in capfire.yml or the reserved
// `sync`) and `args` (the `params:` values the caller passed).
type TaskRun struct {
	ID              int               `json:"id"`
	App             string            `json:"app"`
	Env             string            `json:"env"`
	Task            string            `json:"task"`
	Branch          string            `json:"branch"`
	Args            map[string]string `json:"args"`
	Status          string            `json:"status"`
	ExitCode        *int              `json:"exit_code"`
	TriggeredBy     string            `json:"triggered_by"`
	StartedAt       string            `json:"started_at"`
	FinishedAt      string            `json:"finished_at"`
	DurationSeconds *int              `json:"duration_seconds"`

	// Only present on `show` responses.
	Log string `json:"log,omitempty"`
}

// TaskRunList mirrors `GET /tasks`.
type TaskRunList struct {
	TaskRuns []TaskRun `json:"task_runs"`
}

// TaskAsyncAck is the 202 payload returned by async task runs.
type TaskAsyncAck struct {
	Status    string            `json:"status"`
	TaskRunID int               `json:"task_run_id"`
	App       string            `json:"app"`
	Env       string            `json:"env"`
	Task      string            `json:"task"`
	Branch    string            `json:"branch"`
	Args      map[string]string `json:"args"`
	TrackURL  string            `json:"track_url"`
	Message   string            `json:"message"`
}

// TaskRequest is the body for POST /tasks.
//
// `Args` is sent as a JSON object with string values. The server validates
// that every key declared under `params:` for the task is present and that
// no unknown keys were passed (see AppConfig#validate_args!).
type TaskRequest struct {
	App    string            `json:"app"`
	Env    string            `json:"env"`
	Task   string            `json:"task"`
	Branch string            `json:"branch,omitempty"`
	Args   map[string]string `json:"args,omitempty"`
	Async  bool              `json:"async,omitempty"`
}

// BusyError carries the parsed 409 payload returned by /tasks when another
// task is already in flight on the same app, OR when `sync` is requested
// while a deploy is running. Surfaced by the CLI's `--wait` polling so it
// can decide how long to back off before retrying.
type BusyError struct {
	Status            int               `json:"-"`
	Code              string            `json:"error"`
	Message           string            `json:"message"`
	RetryAfterSeconds int               `json:"retry_after_seconds"`
	Active            *BusyActive       `json:"active,omitempty"`
	ActiveDeploy      *BusyActiveDeploy `json:"active_deploy,omitempty"`
}

// BusyActive describes the in-flight TaskRun blocking a new request.
type BusyActive struct {
	TaskRunID   int    `json:"task_run_id"`
	Task        string `json:"task"`
	Env         string `json:"env"`
	Branch      string `json:"branch"`
	Status      string `json:"status"`
	TriggeredBy string `json:"triggered_by"`
	StartedAt   string `json:"started_at"`
}

// BusyActiveDeploy describes the in-flight Deploy blocking a `sync` task.
type BusyActiveDeploy struct {
	ID          int    `json:"id"`
	Command     string `json:"command"`
	Branch      string `json:"branch"`
	Status      string `json:"status"`
	TriggeredBy string `json:"triggered_by"`
	StartedAt   string `json:"started_at"`
}

func (e *BusyError) Error() string {
	if e.Message != "" {
		return e.Message
	}
	return fmt.Sprintf("capfire api: HTTP %d (busy)", e.Status)
}

// IsBusy returns true when err is a 409 with the task-specific busy payload.
// Drives the `--wait` retry loop in the CLI.
func IsBusy(err error) (*BusyError, bool) {
	var be *BusyError
	if errors.As(err, &be) {
		return be, true
	}
	return nil, false
}

// ListTasksParams filters /tasks index.
type ListTasksParams struct {
	Active bool
	App    string
	Env    string
	Task   string
	Status string
	Limit  int
}

func (p ListTasksParams) values() url.Values {
	q := url.Values{}
	if p.Active {
		q.Set("active", "true")
	}
	if p.App != "" {
		q.Set("app", p.App)
	}
	if p.Env != "" {
		q.Set("env", p.Env)
	}
	if p.Task != "" {
		q.Set("task", p.Task)
	}
	if p.Status != "" {
		q.Set("status", p.Status)
	}
	if p.Limit > 0 {
		q.Set("limit", fmt.Sprintf("%d", p.Limit))
	}
	return q
}

// ListTasks fetches task runs triggered by the current token holder.
func (c *Client) ListTasks(ctx context.Context, params ListTasksParams) ([]TaskRun, error) {
	var list TaskRunList
	if err := c.getJSON(ctx, "/tasks", params.values(), &list); err != nil {
		return nil, err
	}
	return list.TaskRuns, nil
}

// GetTask fetches a single task run by id, including its full log.
func (c *Client) GetTask(ctx context.Context, id int) (*TaskRun, error) {
	var t TaskRun
	path := fmt.Sprintf("/tasks/%d", id)
	if err := c.getJSON(ctx, path, nil, &t); err != nil {
		return nil, err
	}
	return &t, nil
}

// CreateTaskAsync fires POST /tasks with async=true and returns the 202 ack.
//
// 409 Conflict responses are unwrapped into a typed *BusyError so callers
// can implement `--wait` polling without parsing the raw API error body.
func (c *Client) CreateTaskAsync(ctx context.Context, req TaskRequest) (*TaskAsyncAck, error) {
	req.Async = true
	var ack TaskAsyncAck
	if err := c.postJSON(ctx, "/tasks", nil, req, &ack); err != nil {
		if be := tryParseBusy(err); be != nil {
			return nil, be
		}
		return nil, err
	}
	return &ack, nil
}

// StreamTask opens POST /tasks (no async flag) in streaming mode.
//
// Same 409-to-BusyError translation as CreateTaskAsync — but here it can
// only happen at the very start of the stream, before any SSE event is
// received, because once the server accepted the request and started
// streaming the lock is already ours.
func (c *Client) StreamTask(ctx context.Context, req TaskRequest, handler StreamHandler) (int, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return 1, err
	}
	exitCode, err := c.runStream(ctx, "POST", "/tasks", string(body), handler)
	if err != nil {
		if be := tryParseBusy(err); be != nil {
			return exitCode, be
		}
	}
	return exitCode, err
}

// tryParseBusy inspects an APIError for a 409 with the task-conflict shape
// and returns a typed *BusyError. Returns nil when err isn't a 409 or when
// the body doesn't parse as the expected shape (in which case the caller
// surfaces the original APIError verbatim).
func tryParseBusy(err error) *BusyError {
	var apiErr *APIError
	if !errors.As(err, &apiErr) {
		return nil
	}
	if apiErr.Status != http.StatusConflict {
		return nil
	}
	body := strings.TrimSpace(apiErr.Body)
	if body == "" {
		return nil
	}
	var be BusyError
	if jsonErr := json.Unmarshal([]byte(body), &be); jsonErr != nil {
		return nil
	}
	be.Status = apiErr.Status
	if be.Code != "conflict" {
		return nil
	}
	return &be
}
