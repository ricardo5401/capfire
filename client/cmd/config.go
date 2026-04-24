package cmd

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"
	"golang.org/x/term"

	"github.com/uDocz/capfire/client/internal/config"
	"github.com/uDocz/capfire/client/internal/ui"
)

var (
	configHost  string
	configToken string
	configPath  string
	configShow  bool
)

var configCmd = &cobra.Command{
	Use:   "config",
	Short: "Configure the Capfire server host and your API token",
	Long: `Prompts for the Capfire server URL and your API token, then writes them to
$XDG_CONFIG_HOME/capfire/config.yml (or ~/.config/capfire/config.yml).

Non-interactive usage:
  capfire config --host=https://deploy-node-1.internal.udocz.com --token=eyJ...

Pick a custom location with --path (or the CAPFIRE_CONFIG env var).
Use --show to print where the config file resolves to.`,
	RunE: runConfig,
}

func init() {
	configCmd.Flags().StringVar(&configHost, "host", "", "Capfire server URL (e.g. https://host.example)")
	configCmd.Flags().StringVar(&configToken, "token", "", "Bearer token issued by `bin/capfire tokens create`")
	configCmd.Flags().StringVar(&configPath, "path", "", "Write config to this absolute path instead of the default")
	configCmd.Flags().BoolVar(&configShow, "show", false, "Print the resolved config path and current values")
	Root.AddCommand(configCmd)
}

func runConfig(_ *cobra.Command, _ []string) error {
	if configShow {
		return showConfig()
	}

	existing, err := config.Load()
	if err != nil && !errors.Is(err, config.ErrNotConfigured) {
		return err
	}

	host := firstNonEmpty(configHost, existingHost(existing))
	token := configToken

	if host == "" {
		host, err = prompt("Capfire server URL", "https://deploy-node-1.internal.example.com")
		if err != nil {
			return err
		}
	}
	host = strings.TrimSpace(host)
	if host == "" {
		return errors.New("host cannot be empty")
	}

	if token == "" {
		token, err = promptSecret("API token")
		if err != nil {
			return err
		}
	}
	token = strings.TrimSpace(token)
	if token == "" {
		return errors.New("token cannot be empty")
	}

	cfg := &config.Config{Host: host, Token: token}
	if existing != nil {
		cfg.Path = existing.Path
	}
	if err := cfg.Save(configPath); err != nil {
		return err
	}

	ui.Successf("Saved config to %s", cfg.Path)
	return nil
}

func showConfig() error {
	path, err := config.ResolvePath()
	if err != nil {
		return err
	}
	fmt.Printf("%s %s\n", ui.Bold("Config path:"), path)

	cfg, err := config.Load()
	if errors.Is(err, config.ErrNotConfigured) {
		ui.Warnf("No config file yet — run `capfire config`.")
		return nil
	}
	if err != nil {
		return err
	}
	fmt.Printf("%s %s\n", ui.Bold("Host:       "), cfg.Host)
	fmt.Printf("%s %s\n", ui.Bold("Token:      "), maskToken(cfg.Token))
	return nil
}

func existingHost(cfg *config.Config) string {
	if cfg == nil {
		return ""
	}
	return cfg.Host
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

// prompt asks the user for input, echoing characters.
func prompt(label, placeholder string) (string, error) {
	if placeholder != "" {
		fmt.Printf("%s (e.g. %s): ", ui.Bold(label), ui.Dim(placeholder))
	} else {
		fmt.Printf("%s: ", ui.Bold(label))
	}
	reader := bufio.NewReader(os.Stdin)
	line, err := reader.ReadString('\n')
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(line), nil
}

// promptSecret reads a line without echoing. Falls back to plain prompt when
// stdin is not a terminal (CI piping the token via heredoc).
func promptSecret(label string) (string, error) {
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return prompt(label, "")
	}
	fmt.Printf("%s: ", ui.Bold(label))
	bytes, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Println()
	if err != nil {
		return "", err
	}
	return string(bytes), nil
}

func maskToken(token string) string {
	if len(token) <= 12 {
		return ui.Dim("[set]")
	}
	return fmt.Sprintf("%s…%s", token[:6], token[len(token)-4:])
}
