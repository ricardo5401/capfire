// Command capfire is the developer-facing CLI for Capfire deploys.
//
// Everything this binary does boils down to authenticated HTTP calls against
// a Capfire server. It is intentionally stateless — the only local artifact
// is the config file at `$XDG_CONFIG_HOME/capfire/config.yml`, which stores
// the server host and the bearer token for the current user.
package main

import (
	"os"

	"github.com/uDocz/capfire/client/cmd"
)

func main() {
	if err := cmd.Execute(); err != nil {
		os.Exit(1)
	}
}
