// Package sse consumes Server-Sent Event streams from a Capfire deploy.
//
// Capfire emits four event names; their payloads are defined on the server
// in SseWriter/DeployService. We decode each into a simple Event struct
// carrying the raw JSON bytes for the caller to unmarshal into whatever
// shape they expect.
//
// This is a tiny purpose-built parser instead of pulling a dependency. SSE
// framing is trivial:
//
//	event: log
//	data: {"line":"..."}
//	<blank line>
package sse

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Event is a single parsed SSE event. Data is raw JSON — decode with Decode.
type Event struct {
	Name string
	Data []byte
}

// Decode unmarshals Data into `out`. Returns nil when Data is empty.
func (e Event) Decode(out any) error {
	if len(e.Data) == 0 {
		return nil
	}
	return json.Unmarshal(e.Data, out)
}

// Open performs the POST request and returns an io.ReadCloser streaming the
// SSE body. The caller is responsible for closing it. `headers` may be nil.
func Open(ctx context.Context, method, url, token, body, contentType string) (io.ReadCloser, error) {
	var reader io.Reader
	if body != "" {
		reader = strings.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, url, reader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "text/event-stream")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if body != "" && contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}

	// No overall timeout: deploys routinely take minutes. Cancellation is
	// wired through the request context.
	client := &http.Client{Timeout: 0}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		raw, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	return resp.Body, nil
}

// Parse reads events from r and calls handler for each. Stops when the
// underlying reader returns EOF or context is cancelled. Ignores comment
// lines (SSE heartbeat: `: keep-alive\n\n`).
func Parse(ctx context.Context, r io.Reader, handler func(Event) error) error {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	scanner.Split(splitSSE)

	for scanner.Scan() {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		frame := scanner.Text()
		if frame == "" {
			continue
		}
		event := parseFrame(frame)
		if event.Name == "" && len(event.Data) == 0 {
			continue
		}
		if err := handler(event); err != nil {
			return err
		}
	}
	if err := scanner.Err(); err != nil && !errors.Is(err, io.EOF) {
		// Reading from a prematurely closed stream commonly surfaces as
		// `unexpected EOF` on the underlying TCP connection. Treat it as
		// a normal close — the done event (or lack thereof) is what the
		// caller uses to judge success.
		if strings.Contains(err.Error(), "unexpected EOF") {
			return nil
		}
		// Give slow networks a split-second to flush after cancellation.
		time.Sleep(10 * time.Millisecond)
		return err
	}
	return nil
}

// splitSSE returns one event "frame" per call — everything between blank
// lines. Using a custom split func avoids allocating per line.
func splitSSE(data []byte, atEOF bool) (advance int, token []byte, err error) {
	if atEOF && len(data) == 0 {
		return 0, nil, nil
	}
	// Look for the first \n\n (or \r\n\r\n) which terminates a frame.
	for i := 0; i < len(data)-1; i++ {
		if data[i] == '\n' && data[i+1] == '\n' {
			return i + 2, data[:i], nil
		}
		if i < len(data)-3 && data[i] == '\r' && data[i+1] == '\n' && data[i+2] == '\r' && data[i+3] == '\n' {
			return i + 4, data[:i], nil
		}
	}
	if atEOF {
		return len(data), data, nil
	}
	// Need more data.
	return 0, nil, nil
}

func parseFrame(frame string) Event {
	var ev Event
	for _, line := range strings.Split(frame, "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" || strings.HasPrefix(line, ":") {
			// Comment / keep-alive heartbeat — ignore.
			continue
		}
		switch {
		case strings.HasPrefix(line, "event:"):
			ev.Name = strings.TrimSpace(strings.TrimPrefix(line, "event:"))
		case strings.HasPrefix(line, "data:"):
			chunk := strings.TrimPrefix(line, "data:")
			if strings.HasPrefix(chunk, " ") {
				chunk = chunk[1:]
			}
			if len(ev.Data) > 0 {
				ev.Data = append(ev.Data, '\n')
			}
			ev.Data = append(ev.Data, []byte(chunk)...)
		}
	}
	return ev
}
