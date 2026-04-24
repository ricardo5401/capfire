// Package ui centralises terminal output: colors, tables, status glyphs.
//
// Every command in cmd/ funnels through here so we have a single place to
// adjust theme, respect NO_COLOR, or pipe output to non-tty sinks (CI).
package ui

import (
	"fmt"
	"io"
	"os"
	"text/tabwriter"
	"time"

	"github.com/fatih/color"
)

// Pre-resolved color fns so we don't rebuild the attribute list per call.
var (
	Bold    = color.New(color.Bold).SprintFunc()
	Dim     = color.New(color.Faint).SprintFunc()
	Red     = color.New(color.FgRed).SprintFunc()
	Green   = color.New(color.FgGreen).SprintFunc()
	Yellow  = color.New(color.FgYellow).SprintFunc()
	Cyan    = color.New(color.FgCyan).SprintFunc()
	Magenta = color.New(color.FgMagenta).SprintFunc()
)

// Successf prints a green checkmark prefixed message.
func Successf(format string, a ...any) {
	fmt.Fprintf(os.Stdout, "%s %s\n", Green("✓"), fmt.Sprintf(format, a...))
}

// Errorf prints a red X prefixed message to stderr.
func Errorf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "%s %s\n", Red("✗"), fmt.Sprintf(format, a...))
}

// Infof prints a cyan arrow prefixed message.
func Infof(format string, a ...any) {
	fmt.Fprintf(os.Stdout, "%s %s\n", Cyan("›"), fmt.Sprintf(format, a...))
}

// Warnf prints a yellow exclamation prefixed message.
func Warnf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "%s %s\n", Yellow("!"), fmt.Sprintf(format, a...))
}

// NewTable returns a tabwriter configured with our standard column padding.
func NewTable(w io.Writer) *tabwriter.Writer {
	return tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
}

// StatusGlyph returns a colored single-char indicator for a deploy status.
func StatusGlyph(status string) string {
	switch status {
	case "success":
		return Green("✓")
	case "failed":
		return Red("✗")
	case "running":
		return Yellow("●")
	case "pending":
		return Dim("○")
	case "canceled":
		return Dim("–")
	default:
		return Dim("?")
	}
}

// ColoredStatus returns the status word in its glyph's color for tables.
func ColoredStatus(status string) string {
	switch status {
	case "success":
		return Green(status)
	case "failed":
		return Red(status)
	case "running":
		return Yellow(status)
	case "pending":
		return Dim(status)
	case "canceled":
		return Dim(status)
	default:
		return status
	}
}

// RelTime formats an ISO-8601 string as "3m ago" style. Returns "-" on parse
// errors or empty input so tables stay well aligned.
func RelTime(iso string) string {
	if iso == "" {
		return "-"
	}
	t, err := time.Parse(time.RFC3339, iso)
	if err != nil {
		return iso
	}
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds ago", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	}
}

// Duration formats a duration-in-seconds pointer for tables.
func Duration(seconds *int) string {
	if seconds == nil {
		return "-"
	}
	d := time.Duration(*seconds) * time.Second
	if d < time.Minute {
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
	return fmt.Sprintf("%dm%ds", int(d.Minutes()), int(d.Seconds())%60)
}
