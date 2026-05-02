# frozen_string_literal: true

# Persists the OS PID of the spawned shell so a separate request (or the
# admin CLI) can abort a deploy/task that's hanging or pegged.
#
# Why store it: the process is launched from a Puma worker thread (via
# CommandRunner -> PTY.spawn). Once the request returns or the worker
# recycles, we lose the in-memory thread reference. The PID is the only
# stable handle that survives across processes — and it's what we need to
# `Process.kill` from another worker handling `POST /:id/abort`.
#
# Scope: pid is recorded right after spawn (CommandRunner exposes it) and
# cleared by AbortService when the run finishes. A NULL value at any point
# is a perfectly valid state — see AbortService for the precedence rules
# (no pid + status=running => orphan lock => just transition to canceled).
class AddPidToDeploysAndTaskRuns < ActiveRecord::Migration[7.1]
  def change
    add_column :deploys,   :pid, :integer
    add_column :task_runs, :pid, :integer
  end
end
