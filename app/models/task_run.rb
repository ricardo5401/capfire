# frozen_string_literal: true

# Persists the lifecycle of a custom task execution.
#
# Tasks are application-level work declared under `tasks:` in an app's
# `capfire.yml` (reindex, backfill, sync, etc.) and are conceptually separate
# from deploys: they don't drain the load balancer, don't run pre_deploy
# hooks, and — except for the reserved `sync` task — don't touch git.
#
# Concurrency:
#   The unique index on `app` for ('pending','running') rows enforces that at
#   most ONE task is active per app. `TaskService` translates the resulting
#   `ActiveRecord::RecordNotUnique` into a 409 Conflict so callers can either
#   retry or use the CLI's `--wait` flag to poll until the lock is free.
#
#   `sync` adds a cross-table check against `Deploy.active_for(app)` because
#   it rewrites the working directory and must not race with a concurrent
#   deploy. Non-sync tasks intentionally do NOT block deploys — that's the
#   whole point of having a separate model: a 90-minute backfill should not
#   freeze a production hotfix.
class TaskRun < ApplicationRecord
  STATUSES = %w[pending running success failed canceled].freeze
  ACTIVE_STATUSES = %w[pending running].freeze

  validates :app, :env, :task_name, :branch, :status, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }
  scope :running, -> { where(status: 'running') }
  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :active_for, ->(app) { active.where(app: app) }

  def mark_running!(started_at: Time.current)
    update!(status: 'running', started_at: started_at)
  end

  def mark_finished!(exit_code:, finished_at: Time.current)
    new_status = exit_code.to_i.zero? ? 'success' : 'failed'
    update!(status: new_status, exit_code: exit_code, finished_at: finished_at)
  end

  # Same chunk-append trick as Deploy: avoids rewriting the whole `log` column
  # from Ruby on every line streamed by the runner.
  def append_log!(chunk)
    sql = self.class.sanitize_sql_array([ 'log = COALESCE(log, ?) || ?', '', chunk ])
    self.class.where(id: id).update_all(sql)
    self.log = "#{log}#{chunk}"
  end

  def duration_seconds
    return nil unless started_at && finished_at

    (finished_at - started_at).to_i
  end

  def as_status_json
    {
      id: id,
      app: app,
      env: env,
      task: task_name,
      branch: branch,
      args: args,
      status: status,
      exit_code: exit_code,
      triggered_by: triggered_by,
      started_at: started_at,
      finished_at: finished_at,
      duration_seconds: duration_seconds
    }
  end
end
