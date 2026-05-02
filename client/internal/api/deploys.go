package api

import (
	"context"
	"fmt"
	"net/url"
)

// Deploy is the JSON shape returned by /deploys and /deploys/:id.
type Deploy struct {
	ID              int    `json:"id"`
	App             string `json:"app"`
	Env             string `json:"env"`
	Branch          string `json:"branch"`
	Command         string `json:"command"`
	Status          string `json:"status"`
	ExitCode        *int   `json:"exit_code"`
	PID             *int   `json:"pid"`
	TriggeredBy     string `json:"triggered_by"`
	StartedAt       string `json:"started_at"`
	FinishedAt      string `json:"finished_at"`
	DurationSeconds *int   `json:"duration_seconds"`

	// Only present on `show` responses.
	Log string `json:"log,omitempty"`

	// Only present on POST /deploys/:id/abort responses. Carries the
	// final outcome ("canceled" or "already_finished") plus the exit
	// code AbortService landed on (143/137/-1, see server-side service
	// for semantics).
	AbortStatus   string `json:"abort_status,omitempty"`
	AbortExitCode *int   `json:"abort_exit_code,omitempty"`
}

// DeployList mirrors `GET /deploys`. The server now returns a `scope`
// marker ("mine" or "all") and an optional `hint` string telling users
// about the `--all` flag — both surfaced verbatim by the CLI so the
// behavior is discoverable without reading docs.
//
// Pagination is always present on this endpoint (even on the first
// page) so the client can render a "page X of Y" footer without
// branching on whether the field exists. Server contract documented in
// docs/server/api.md.
type DeployList struct {
	Deploys    []Deploy    `json:"deploys"`
	Scope      string      `json:"scope,omitempty"`
	Hint       string      `json:"hint,omitempty"`
	Pagination *Pagination `json:"pagination,omitempty"`
}

// Pagination is the metadata block returned alongside every paginated
// listing endpoint. Same shape across `/deploys` and `/tasks` so a
// single helper on the CLI side can render the footer for both.
type Pagination struct {
	Page       int `json:"page"`
	PerPage    int `json:"per_page"`
	TotalCount int `json:"total_count"`
	TotalPages int `json:"total_pages"`
}

// AsyncAck is the 202 payload returned by async deploys/commands.
type AsyncAck struct {
	Status   string `json:"status"`
	DeployID int    `json:"deploy_id"`
	App      string `json:"app"`
	Env      string `json:"env"`
	Branch   string `json:"branch"`
	Command  string `json:"command"`
	TrackURL string `json:"track_url"`
	Message  string `json:"message"`
}

// ListDeploysParams filters the /deploys index endpoint.
//
// `All` flips the server-side scope from "deploys I triggered" to "deploys
// on every app I have any grant on" — that's how a teammate sees your
// in-flight deploy. Default is the conservative "mine only" scope.
//
// Pagination params:
//   - Page (1-based; the server treats out-of-range pages as empty
//     results, not errors).
//   - PerPage (server caps at 100).
//   - Limit is the LEGACY param — kept for backwards-compat with
//     scripts pinned to it. The server uses it as an alias for PerPage
//     when PerPage is not set; on the CLI side we send PerPage when the
//     user asked for `--per-page` and Limit when they used `--limit`.
type ListDeploysParams struct {
	All     bool
	Active  bool
	App     string
	Env     string
	Status  string
	Page    int
	PerPage int
	Limit   int
}

func (p ListDeploysParams) values() url.Values {
	q := url.Values{}
	if p.All {
		q.Set("all", "true")
	}
	if p.Active {
		q.Set("active", "true")
	}
	if p.App != "" {
		q.Set("app", p.App)
	}
	if p.Env != "" {
		q.Set("env", p.Env)
	}
	if p.Status != "" {
		q.Set("status", p.Status)
	}
	if p.Page > 0 {
		q.Set("page", fmt.Sprintf("%d", p.Page))
	}
	if p.PerPage > 0 {
		q.Set("per_page", fmt.Sprintf("%d", p.PerPage))
	}
	if p.Limit > 0 {
		q.Set("limit", fmt.Sprintf("%d", p.Limit))
	}
	return q
}

// ListDeploys fetches deploys visible to the current token holder. With
// `params.All == false` (default), this is "deploys you triggered". With
// `params.All == true`, this is "deploys on apps you can see".
//
// Returns the full DeployList (not just the slice) so callers can surface
// the server's `hint` to the user — that's the discoverability mechanism
// for the new `--all` flag.
func (c *Client) ListDeploys(ctx context.Context, params ListDeploysParams) (*DeployList, error) {
	var list DeployList
	if err := c.getJSON(ctx, "/deploys", params.values(), &list); err != nil {
		return nil, err
	}
	return &list, nil
}

// AbortDeploy fires POST /deploys/:id/abort.
//
// `reason` is optional and is appended to the deploy's audit log line so
// "why was this killed" is visible to anyone reading the log later.
//
// Returns the updated Deploy with `AbortStatus` set. A 200 with
// `abort_status="already_finished"` means the deploy was no longer active
// — we treat it as success because the caller's intent ("stop this thing")
// is satisfied either way.
func (c *Client) AbortDeploy(ctx context.Context, id int, reason string) (*Deploy, error) {
	body := map[string]string{}
	if reason != "" {
		body["reason"] = reason
	}
	var d Deploy
	path := fmt.Sprintf("/deploys/%d/abort", id)
	if err := c.postJSON(ctx, path, nil, body, &d); err != nil {
		return nil, err
	}
	return &d, nil
}

// GetDeploy fetches a single deploy by id, including its full log.
func (c *Client) GetDeploy(ctx context.Context, id int) (*Deploy, error) {
	var d Deploy
	path := fmt.Sprintf("/deploys/%d", id)
	if err := c.getJSON(ctx, path, nil, &d); err != nil {
		return nil, err
	}
	return &d, nil
}

// DeployRequest is the body for POST /deploys.
type DeployRequest struct {
	App    string `json:"app"`
	Env    string `json:"env"`
	Branch string `json:"branch,omitempty"`
	SkipLB bool   `json:"skip_lb,omitempty"`
	Async  bool   `json:"async,omitempty"`
}

// CreateDeployAsync fires POST /deploys with async=true and returns the 202 ack.
func (c *Client) CreateDeployAsync(ctx context.Context, req DeployRequest) (*AsyncAck, error) {
	req.Async = true
	var ack AsyncAck
	if err := c.postJSON(ctx, "/deploys", nil, req, &ack); err != nil {
		return nil, err
	}
	return &ack, nil
}

// CommandRequest is the body for POST /commands.
type CommandRequest struct {
	App    string `json:"app"`
	Env    string `json:"env"`
	Cmd    string `json:"cmd"`
	Branch string `json:"branch,omitempty"`
	Async  bool   `json:"async,omitempty"`
}

// RunCommandAsync fires POST /commands with async=true.
func (c *Client) RunCommandAsync(ctx context.Context, req CommandRequest) (*AsyncAck, error) {
	req.Async = true
	var ack AsyncAck
	if err := c.postJSON(ctx, "/commands", nil, req, &ack); err != nil {
		return nil, err
	}
	return &ack, nil
}
