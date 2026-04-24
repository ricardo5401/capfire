package api

import "context"

// Grant is a single per-app permission tuple inside a token.
type Grant struct {
	App  string   `json:"app"`
	Envs []string `json:"envs"`
	Cmds []string `json:"cmds"`
}

// Permission mirrors the JSON payload returned by `GET /tokens/me`.
type Permission struct {
	Name         string  `json:"name"`
	JTI          string  `json:"jti"`
	Grants       []Grant `json:"grants"`
	IssuedAt     string  `json:"issued_at"`
	ExpiresAt    string  `json:"expires_at"`
	Revoked      bool    `json:"revoked"`
	RevokedAt    string  `json:"revoked_at"`
	KnownLocally bool    `json:"known_locally"`
}

// Me fetches the current token's permissions from the server.
func (c *Client) Me(ctx context.Context) (*Permission, error) {
	var p Permission
	if err := c.getJSON(ctx, "/tokens/me", nil, &p); err != nil {
		return nil, err
	}
	return &p, nil
}
