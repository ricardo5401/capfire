package api

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/uDocz/capfire/client/internal/sse"
)

// StreamHandler is invoked for every SSE event received. Returning a
// non-nil error aborts the stream early.
type StreamHandler func(event string, payload map[string]any) error

// StreamDeploy opens POST /deploys in streaming mode and forwards each SSE
// event to handler. Returns the final `done` event's exit_code (or an error).
func (c *Client) StreamDeploy(ctx context.Context, req DeployRequest, handler StreamHandler) (int, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return 1, err
	}
	return c.runStream(ctx, "POST", "/deploys", string(body), handler)
}

// StreamCommand opens POST /commands in streaming mode.
func (c *Client) StreamCommand(ctx context.Context, req CommandRequest, handler StreamHandler) (int, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return 1, err
	}
	return c.runStream(ctx, "POST", "/commands", string(body), handler)
}

func (c *Client) runStream(ctx context.Context, method, path, body string, handler StreamHandler) (int, error) {
	url := c.Host + path
	reader, err := sse.Open(ctx, method, url, c.Token, body, "application/json")
	if err != nil {
		return 1, err
	}
	defer reader.Close()

	exitCode := 1
	var sawDone bool

	parseErr := sse.Parse(ctx, reader, func(ev sse.Event) error {
		var payload map[string]any
		if err := ev.Decode(&payload); err != nil {
			return fmt.Errorf("decode %s event: %w", ev.Name, err)
		}
		if handler != nil {
			if err := handler(ev.Name, payload); err != nil {
				return err
			}
		}
		if ev.Name == "done" {
			sawDone = true
			if raw, ok := payload["exit_code"].(float64); ok {
				exitCode = int(raw)
			}
		}
		return nil
	})
	if parseErr != nil {
		return exitCode, parseErr
	}
	if !sawDone {
		return exitCode, fmt.Errorf("stream ended without a `done` event")
	}
	return exitCode, nil
}
