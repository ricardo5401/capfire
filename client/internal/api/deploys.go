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
	TriggeredBy     string `json:"triggered_by"`
	StartedAt       string `json:"started_at"`
	FinishedAt      string `json:"finished_at"`
	DurationSeconds *int   `json:"duration_seconds"`

	// Only present on `show` responses.
	Log string `json:"log,omitempty"`
}

// DeployList mirrors `GET /deploys`.
type DeployList struct {
	Deploys []Deploy `json:"deploys"`
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
type ListDeploysParams struct {
	Active bool
	App    string
	Env    string
	Status string
	Limit  int
}

func (p ListDeploysParams) values() url.Values {
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
	if p.Status != "" {
		q.Set("status", p.Status)
	}
	if p.Limit > 0 {
		q.Set("limit", fmt.Sprintf("%d", p.Limit))
	}
	return q
}

// ListDeploys fetches deploys triggered by the current token holder.
func (c *Client) ListDeploys(ctx context.Context, params ListDeploysParams) ([]Deploy, error) {
	var list DeployList
	if err := c.getJSON(ctx, "/deploys", params.values(), &list); err != nil {
		return nil, err
	}
	return list.Deploys, nil
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
