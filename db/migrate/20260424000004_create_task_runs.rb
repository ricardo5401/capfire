# frozen_string_literal: true

# Persists the lifecycle of a custom task execution defined under `tasks:` in
# an app's `capfire.yml`. Tasks are application-level work (reindex, backfill,
# data migrations, sync) — distinct from the deploy lifecycle which already
# lives in `deploys`.
#
# Locking model (DB-level half — service layer enforces the rest):
#   - Unique partial index on `app` for ('pending','running') rows ensures at
#     most one task is active per app at any moment. A second concurrent
#     request for the same app fails the index and the service translates it
#     into a 409 Conflict.
#   - Tasks DO NOT block deploys at the DB level — that's intentional, so a
#     long backfill doesn't freeze a hotfix on the same node. The `sync` task
#     adds an extra application-level check against active deploys (see
#     `TaskService`) because it mutates the working directory.
class CreateTaskRuns < ActiveRecord::Migration[7.1]
  def change
    create_table :task_runs do |t|
      t.string  :app,          null: false
      t.string  :env,          null: false
      t.string  :task_name,    null: false
      t.string  :branch,       null: false, default: 'main'
      t.jsonb   :args,         null: false, default: {}
      t.string  :status,       null: false, default: 'pending'
      t.integer :exit_code
      t.string  :triggered_by
      t.string  :token_jti
      t.datetime :started_at
      t.datetime :finished_at
      t.text :log,          default: ''
      t.timestamps
    end

    add_index :task_runs, %i[app env]
    add_index :task_runs, :status
    add_index :task_runs, :created_at
    add_index :task_runs, :task_name

    # Per-app exclusivity for active tasks. Mirrors the `deploys` lock so a
    # second concurrent task on the same app collides at the DB layer instead
    # of in Ruby. Both locks coexist (different tables) so a deploy and a
    # non-sync task on the same app CAN run in parallel — the `sync` task
    # adds its own service-level check to prevent that specific case.
    add_index :task_runs, :app,
              unique: true,
              where: "status IN ('pending', 'running')",
              name: 'idx_task_runs_active_per_app'
  end
end
