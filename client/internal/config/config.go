// Package config loads and writes the Capfire client configuration file.
//
// Resolution order (first match wins):
//
//  1. $CAPFIRE_CONFIG  — absolute path override (useful for CI, rootless
//     setups, or people who pin their dotfiles under a non-standard location).
//  2. $XDG_CONFIG_HOME/capfire/config.yml
//  3. $HOME/.config/capfire/config.yml
//
// The file stores the API host and a JWT bearer token, so it is always
// written with permissions 0600. Callers never pass the token around by
// value — they pull it from here on demand.
package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

// ErrNotConfigured is returned when no config file is present yet.
// Callers should print a hint pointing at `capfire config`.
var ErrNotConfigured = errors.New("capfire is not configured — run `capfire config`")

// Config is the on-disk shape of the client config file.
type Config struct {
	Host  string `yaml:"host"`
	Token string `yaml:"token"`

	// Path is the absolute path the config was loaded from. Zero value when
	// the Config was constructed programmatically (e.g. during `capfire
	// config` before the first save).
	Path string `yaml:"-"`
}

// Load reads the config file from disk. Returns ErrNotConfigured when no
// file exists, a decoded Config on success, and any IO/YAML error otherwise.
func Load() (*Config, error) {
	path, err := ResolvePath()
	if err != nil {
		return nil, err
	}

	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotConfigured
	}
	if err != nil {
		return nil, fmt.Errorf("read config %s: %w", path, err)
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse config %s: %w", path, err)
	}
	cfg.Path = path
	return &cfg, nil
}

// Save writes the config to disk with 0600 permissions. Creates parent
// directories as needed. Overrides the stored path with `path` when it is
// non-empty — otherwise writes back to cfg.Path (or resolves a default).
func (c *Config) Save(path string) error {
	target := path
	if target == "" {
		target = c.Path
	}
	if target == "" {
		resolved, err := ResolvePath()
		if err != nil {
			return err
		}
		target = resolved
	}

	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}

	data, err := yaml.Marshal(c)
	if err != nil {
		return fmt.Errorf("encode config: %w", err)
	}

	if err := os.WriteFile(target, data, 0o600); err != nil {
		return fmt.Errorf("write config %s: %w", target, err)
	}
	c.Path = target
	return nil
}

// Validate returns an error describing any missing required fields.
func (c *Config) Validate() error {
	if c.Host == "" {
		return errors.New("missing `host` — run `capfire config`")
	}
	if c.Token == "" {
		return errors.New("missing `token` — run `capfire config`")
	}
	return nil
}

// ResolvePath returns the absolute path the config would load from / write
// to, following the XDG convention described in the package doc. Does not
// touch the filesystem.
func ResolvePath() (string, error) {
	if override := os.Getenv("CAPFIRE_CONFIG"); override != "" {
		return override, nil
	}
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "capfire", "config.yml"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home dir: %w", err)
	}
	return filepath.Join(home, ".config", "capfire", "config.yml"), nil
}
