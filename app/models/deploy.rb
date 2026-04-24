# frozen_string_literal: true

# Persists the lifecycle of a deploy/restart/rollback/status run.
#
# Uniqueness index on `app` for rows in ('pending','running') enforces that
# only one active operation exists per app at a time (see migrations). That's
# the DB-level half of the concurrency lock used by `DeployService`.
class Deploy < ApplicationRecord
  STATUSES = %w[pending running success failed canceled].freeze
  COMMANDS = %w[deploy restart rollback status].freeze
  ACTIVE_STATUSES = %w[pending running].freeze

  validates :app, :env, :branch, :command, :status, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :command, inclusion: { in: COMMANDS }

  scope :recent, -> { order(created_at: :desc) }
  scope :running, -> { where(status: 'running') }
  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :active_for, ->(app) { active.where(app: app) }

  def mark_running!(started_at: Time.current)
    update!(status: 'running', started_at: started_at)
  end

  def mark_finished!(exit_code:, finished_at: Time.current)
    status = exit_code.to_i.zero? ? 'success' : 'failed'
    update!(status: status, exit_code: exit_code, finished_at: finished_at)
  end

  def append_log!(chunk)
    # Appends a log chunk without rewriting the whole column from Ruby on every line.
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
      branch: branch,
      command: command,
      status: status,
      exit_code: exit_code,
      triggered_by: triggered_by,
      started_at: started_at,
      finished_at: finished_at,
      duration_seconds: duration_seconds
    }
  end
end
