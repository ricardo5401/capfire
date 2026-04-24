// Package api is the thin HTTP client that talks to a Capfire server.
//
// Every request attaches the bearer token from the loaded config and accepts
// JSON. SSE streaming lives here too because it shares the bearer auth with
// plain JSON endpoints.
package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

// Client is a reusable HTTP client bound to a host + token pair.
type Client struct {
	Host  string
	Token string

	// HTTP is overridable in tests. nil defaults to a plain http.Client with
	// a reasonable timeout — streaming calls construct their own client
	// without a timeout so long-running deploys don't get killed.
	HTTP *http.Client
}

// New builds a Client. Host must include scheme. Trailing slashes are trimmed.
func New(host, token string) *Client {
	for len(host) > 0 && host[len(host)-1] == '/' {
		host = host[:len(host)-1]
	}
	return &Client{
		Host:  host,
		Token: token,
		HTTP:  &http.Client{Timeout: 30 * time.Second},
	}
}

// APIError is returned for non-2xx JSON responses. The server's JSON body is
// captured verbatim in Body when available so callers can format it.
type APIError struct {
	Status int
	Body   string
}

func (e *APIError) Error() string {
	if e.Body != "" {
		return fmt.Sprintf("capfire api: HTTP %d: %s", e.Status, e.Body)
	}
	return fmt.Sprintf("capfire api: HTTP %d", e.Status)
}

// getJSON performs GET `path` and decodes the response into `out`.
// `query` is optional and may be nil.
func (c *Client) getJSON(ctx context.Context, path string, query url.Values, out any) error {
	req, err := c.newRequest(ctx, http.MethodGet, path, query, nil)
	if err != nil {
		return err
	}
	return c.doJSON(req, out)
}

// postJSON performs POST `path` with JSON body and decodes the response.
// If `out` is nil the body is discarded.
func (c *Client) postJSON(ctx context.Context, path string, query url.Values, body any, out any) error {
	var reader io.Reader
	if body != nil {
		buf, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("encode request body: %w", err)
		}
		reader = bytes.NewReader(buf)
	}
	req, err := c.newRequest(ctx, http.MethodPost, path, query, reader)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return c.doJSON(req, out)
}

func (c *Client) newRequest(ctx context.Context, method, path string, query url.Values, body io.Reader) (*http.Request, error) {
	u, err := url.Parse(c.Host + path)
	if err != nil {
		return nil, fmt.Errorf("parse url %q: %w", c.Host+path, err)
	}
	if query != nil {
		u.RawQuery = query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, method, u.String(), body)
	if err != nil {
		return nil, err
	}
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}
	req.Header.Set("Accept", "application/json")
	return req, nil
}

func (c *Client) doJSON(req *http.Request, out any) error {
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("%s %s: %w", req.Method, req.URL.Path, err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("read response body: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return &APIError{Status: resp.StatusCode, Body: string(raw)}
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("decode response: %w (raw=%q)", err, truncate(string(raw), 500))
	}
	return nil
}

func truncate(s string, limit int) string {
	if len(s) <= limit {
		return s
	}
	return s[:limit] + "..."
}

// IsUnauthorized returns true for 401/403 responses — useful for the CLI to
// print a hint pointing at `capfire config`.
func IsUnauthorized(err error) bool {
	var apiErr *APIError
	if !errors.As(err, &apiErr) {
		return false
	}
	return apiErr.Status == http.StatusUnauthorized || apiErr.Status == http.StatusForbidden
}
