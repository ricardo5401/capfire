package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Tests focus on the slice of behavior the CLI relies on:
//   - tryParseBusy: 409 vs other statuses, both task-busy and sync-vs-deploy
//     payload shapes, malformed bodies fall through.
//   - CreateTaskAsync: surfaces *BusyError when the server returns 409.
//   - Round-trip: ListTasks/GetTask/CreateTaskAsync hit the right paths.

func TestTryParseBusy_TaskInFlight(t *testing.T) {
	body := `{
		"error":   "conflict",
		"message": "another task is already in progress for app=pyworker",
		"active": {
			"task_run_id": 87, "task": "backfill", "env": "production",
			"branch": "master", "status": "running",
			"triggered_by": "ana", "started_at": "2026-04-24T14:32:11Z"
		},
		"retry_after_seconds": 60
	}`
	apiErr := &APIError{Status: http.StatusConflict, Body: body}

	be := tryParseBusy(apiErr)
	if be == nil {
		t.Fatal("expected *BusyError, got nil")
	}
	if be.Code != "conflict" {
		t.Errorf("code: want conflict, got %q", be.Code)
	}
	if be.RetryAfterSeconds != 60 {
		t.Errorf("retry_after_seconds: want 60, got %d", be.RetryAfterSeconds)
	}
	if be.Active == nil || be.Active.TaskRunID != 87 || be.Active.Task != "backfill" {
		t.Errorf("active payload not parsed: %+v", be.Active)
	}
	if be.ActiveDeploy != nil {
		t.Errorf("expected ActiveDeploy nil for task busy, got %+v", be.ActiveDeploy)
	}
}

func TestTryParseBusy_SyncVsDeploy(t *testing.T) {
	body := `{
		"error":   "conflict",
		"message": "cannot run sync while a deploy is in progress for app=pyworker",
		"active_deploy": {
			"id": 42, "command": "deploy", "branch": "master",
			"status": "running", "triggered_by": "rel", "started_at": "2026-04-24T14:30:00Z"
		},
		"retry_after_seconds": 120
	}`
	apiErr := &APIError{Status: http.StatusConflict, Body: body}

	be := tryParseBusy(apiErr)
	if be == nil {
		t.Fatal("expected *BusyError, got nil")
	}
	if be.ActiveDeploy == nil || be.ActiveDeploy.ID != 42 {
		t.Errorf("active_deploy payload not parsed: %+v", be.ActiveDeploy)
	}
	if be.Active != nil {
		t.Errorf("expected Active nil for deploy-in-flight, got %+v", be.Active)
	}
}

func TestTryParseBusy_NotConflict(t *testing.T) {
	cases := []*APIError{
		{Status: http.StatusBadRequest, Body: `{"error":"bad_request"}`},
		{Status: http.StatusForbidden, Body: `{"error":"forbidden"}`},
		{Status: http.StatusNotFound, Body: `{"error":"not_found"}`},
		{Status: http.StatusInternalServerError, Body: `{"error":"server_error"}`},
	}
	for _, ae := range cases {
		if be := tryParseBusy(ae); be != nil {
			t.Errorf("status=%d should not parse as busy, got %+v", ae.Status, be)
		}
	}
}

func TestTryParseBusy_409ButWrongShape(t *testing.T) {
	// 409 with a non-conflict error code (e.g. legacy server returning a
	// different shape) must NOT be misinterpreted as a busy signal — the
	// caller would otherwise loop forever on a permanent error.
	apiErr := &APIError{
		Status: http.StatusConflict,
		Body:   `{"error":"something_else","message":"x"}`,
	}
	if be := tryParseBusy(apiErr); be != nil {
		t.Errorf("expected nil for non-conflict 409, got %+v", be)
	}
}

func TestTryParseBusy_UnparseableBody(t *testing.T) {
	apiErr := &APIError{
		Status: http.StatusConflict,
		Body:   `not-even-json`,
	}
	if be := tryParseBusy(apiErr); be != nil {
		t.Errorf("expected nil for malformed 409 body, got %+v", be)
	}
}

func TestTryParseBusy_NilOrPlainError(t *testing.T) {
	if be := tryParseBusy(nil); be != nil {
		t.Errorf("expected nil for nil input, got %+v", be)
	}
	if be := tryParseBusy(errors.New("network refused")); be != nil {
		t.Errorf("expected nil for non-APIError, got %+v", be)
	}
}

func TestIsBusy_Wrapping(t *testing.T) {
	be := &BusyError{Status: 409, Code: "conflict", RetryAfterSeconds: 30}
	// errors.As walks the chain — wrapping a BusyError must still be
	// detectable, since the rest of the codebase wraps with %w freely.
	wrapped := fmt.Errorf("call failed: %w", be)

	got, ok := IsBusy(wrapped)
	if !ok {
		t.Fatal("IsBusy should detect a wrapped *BusyError")
	}
	if got != be {
		t.Errorf("IsBusy returned a different pointer than the wrapped one")
	}
}

func TestCreateTaskAsync_Returns202(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/tasks" || r.Method != http.MethodPost {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		var got TaskRequest
		if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
			t.Fatalf("decode body: %v", err)
		}
		if !got.Async {
			t.Error("CreateTaskAsync must force Async=true")
		}
		if got.Task != "reindex" {
			t.Errorf("task: want reindex, got %q", got.Task)
		}
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(`{
			"status": "accepted", "task_run_id": 7, "track_url": "/tasks/7",
			"app": "pyworker", "env": "production", "task": "reindex", "branch": "master"
		}`))
	}))
	defer srv.Close()

	c := New(srv.URL, "tok")
	ack, err := c.CreateTaskAsync(context.Background(), TaskRequest{
		App: "pyworker", Env: "production", Task: "reindex", Branch: "master",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ack.TaskRunID != 7 {
		t.Errorf("task_run_id: want 7, got %d", ack.TaskRunID)
	}
	if !strings.HasSuffix(ack.TrackURL, "/tasks/7") {
		t.Errorf("track_url: want suffix /tasks/7, got %q", ack.TrackURL)
	}
}

func TestCreateTaskAsync_Returns409AsBusyError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusConflict)
		_, _ = w.Write([]byte(`{
			"error": "conflict",
			"message": "another task is already in progress for app=pyworker",
			"active": { "task_run_id": 87, "task": "backfill", "env": "production",
			            "branch": "master", "status": "running",
			            "triggered_by": "ana", "started_at": "2026-04-24T14:32:11Z" },
			"retry_after_seconds": 60
		}`))
	}))
	defer srv.Close()

	c := New(srv.URL, "tok")
	_, err := c.CreateTaskAsync(context.Background(), TaskRequest{
		App: "pyworker", Env: "production", Task: "reindex",
	})
	if err == nil {
		t.Fatal("expected error, got nil")
	}

	be, ok := IsBusy(err)
	if !ok {
		t.Fatalf("expected *BusyError, got %T: %v", err, err)
	}
	if be.RetryAfterSeconds != 60 {
		t.Errorf("retry_after_seconds: want 60, got %d", be.RetryAfterSeconds)
	}
	if be.Active == nil || be.Active.TaskRunID != 87 {
		t.Errorf("active payload missing: %+v", be.Active)
	}
}

func TestListTasks_PassesQueryParams(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if q.Get("active") != "true" {
			t.Errorf("active query: want 'true', got %q", q.Get("active"))
		}
		if q.Get("app") != "pyworker" {
			t.Errorf("app query: got %q", q.Get("app"))
		}
		if q.Get("task") != "reindex" {
			t.Errorf("task query: got %q", q.Get("task"))
		}
		if q.Get("limit") != "5" {
			t.Errorf("limit query: got %q", q.Get("limit"))
		}
		_, _ = w.Write([]byte(`{"task_runs":[]}`))
	}))
	defer srv.Close()

	c := New(srv.URL, "tok")
	_, err := c.ListTasks(context.Background(), ListTasksParams{
		Active: true, App: "pyworker", Task: "reindex", Limit: 5,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestGetTask_ParsesLog(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/tasks/42" {
			t.Errorf("path: got %q", r.URL.Path)
		}
		_, _ = w.Write([]byte(`{
			"id": 42, "app": "pyworker", "env": "production", "task": "reindex",
			"branch": "main", "status": "success", "log": "line1\nline2"
		}`))
	}))
	defer srv.Close()

	c := New(srv.URL, "tok")
	tr, err := c.GetTask(context.Background(), 42)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if tr.ID != 42 {
		t.Errorf("id: want 42, got %d", tr.ID)
	}
	if !strings.Contains(tr.Log, "line1") {
		t.Errorf("log not parsed: %q", tr.Log)
	}
}
