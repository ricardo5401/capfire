package cmd

import (
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"github.com/uDocz/capfire/client/internal/ui"
)

var permissionCmd = &cobra.Command{
	Use:     "permission",
	Aliases: []string{"permissions", "whoami"},
	Short:   "Show what your configured token can do",
	Long:    "Queries GET /tokens/me on the configured Capfire server and prints your name, apps, envs, cmds and expiry.",
	RunE:    runPermission,
}

func init() {
	Root.AddCommand(permissionCmd)
}

func runPermission(_ *cobra.Command, _ []string) error {
	client, cfg, err := loadClient()
	if err != nil {
		return err
	}

	ctx, cancel := withSignals()
	defer cancel()

	perm, err := client.Me(ctx)
	if err != nil {
		return err
	}

	fmt.Printf("%s %s\n", ui.Bold("Host:    "), cfg.Host)
	fmt.Printf("%s %s\n", ui.Bold("Token:   "), ui.Bold(perm.Name))
	fmt.Printf("%s %s\n", ui.Bold("JTI:     "), ui.Dim(perm.JTI))
	fmt.Printf("%s %s\n", ui.Bold("Apps:    "), strings.Join(perm.Apps, ", "))
	fmt.Printf("%s %s\n", ui.Bold("Envs:    "), strings.Join(perm.Envs, ", "))
	fmt.Printf("%s %s\n", ui.Bold("Cmds:    "), strings.Join(perm.Cmds, ", "))
	fmt.Printf("%s %s\n", ui.Bold("Issued:  "), valueOrDash(perm.IssuedAt))
	fmt.Printf("%s %s\n", ui.Bold("Expires: "), valueOrNever(perm.ExpiresAt))
	if perm.Revoked {
		ui.Errorf("This token is REVOKED (at %s). Generate a new one on the server.", perm.RevokedAt)
	} else if !perm.KnownLocally {
		ui.Warnf("The token signature is valid but its jti is not in the server's api_tokens table — possibly a stale DB. The deploy will still work.")
	}
	return nil
}

func valueOrDash(v string) string {
	if v == "" {
		return "-"
	}
	return v
}

func valueOrNever(v string) string {
	if v == "" {
		return ui.Dim("never")
	}
	return v
}
