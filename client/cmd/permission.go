package cmd

import (
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"github.com/ricardo5401/capfire/client/internal/ui"
)

var permissionCmd = &cobra.Command{
	Use:     "permission",
	Aliases: []string{"permissions", "whoami"},
	Short:   "Show what your configured token can do",
	Long:    "Queries GET /tokens/me on the configured Capfire server and prints your name, per-app grants and expiry.",
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
	fmt.Printf("%s %s\n", ui.Bold("Issued:  "), valueOrDash(perm.IssuedAt))
	fmt.Printf("%s %s\n", ui.Bold("Expires: "), valueOrNever(perm.ExpiresAt))
	fmt.Println()

	if len(perm.Grants) == 0 {
		ui.Warnf("This token has no grants — it cannot deploy anything.")
	} else {
		fmt.Println(ui.Bold("Grants:"))
		w := ui.NewTable(os.Stdout)
		fmt.Fprintln(w, "  APP\tENVS\tCMDS")
		for _, g := range perm.Grants {
			fmt.Fprintf(w, "  %s\t%s\t%s\n",
				prettyWildcard(g.App),
				prettyList(g.Envs),
				prettyList(g.Cmds),
			)
		}
		w.Flush()
	}

	if perm.Revoked {
		fmt.Println()
		ui.Errorf("This token is REVOKED (at %s). Generate a new one on the server.", perm.RevokedAt)
	} else if !perm.KnownLocally {
		fmt.Println()
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

// prettyWildcard highlights the wildcard so it stands out in the table.
func prettyWildcard(v string) string {
	if v == "*" {
		return ui.Yellow("*") + " " + ui.Dim("(any)")
	}
	return v
}

// prettyList renders a slice of claim values, highlighting a bare `*`.
func prettyList(values []string) string {
	if len(values) == 1 && values[0] == "*" {
		return ui.Yellow("*") + " " + ui.Dim("(any)")
	}
	return strings.Join(values, ", ")
}
