# frozen_string_literal: true

# Orchestrates a single task execution defined under `tasks:` in an app's
# `capfire.yml` (or the reserved built-in `sync` task) and streams output
# line-by-line via a block, the same way `DeployService` does.
#
# Lifecycle:
#   1. Resolve the final shell string via `AppConfig#task_for` (this also
#      validates declared `params:` against the caller's `args`).
#   2. Create the TaskRun record (status=pending). The DB unique partial
#      index on `app` for active rows raises `ActiveRecord::RecordNotUnique`
#      if another task is already in flight on the same app — translated
#      into `TaskService::Busy` for the controller.
#   3. For the reserved `sync` task only: cross-check `Deploy.active_for`
#      and abort if a deploy is currently running. `sync` mutates the
#      working dir; letting it race with a deploy would clobber the
#      checkout. Non-sync tasks intentionally skip this check so a long
#      backfill doesn't block hotfixes.
#   4. Mark TaskRun running, run the command via `CommandRunner`, append
#      every line to `log` and yield `:log` events to the caller.
#   5. Mark TaskRun success/failed and yield `:done` with the exit code.
#
# What this service deliberately does NOT do (compared to DeployService):
#   - No load balancer drain/restore. Tasks are application work, not
#     release lifecycle — Cloudflare doesn't care.
#   - No `pre_deploy` hooks from yaml. Tasks run exactly what the user
#     declared in `tasks.<name>.run` (or the built-in sync recipe).
#   - No automatic `git_sync`. The runner's `build_full_command` only
#     prepends git sync for `command == 'deploy'`, and tasks pass a
#     different command name so that branch is skipped.
#   - No Slack notifications in this version. Tasks are tracked via the
#     CLI/HTTP polling against `GET /tasks/:id`. Slack support can be added
#     later as opt-in per task without changing the contract.
class TaskService
  # Raised when another task is already pending or running for the same app.
  # Carries the active TaskRun so the controller can surface useful info
  # (task name, who triggered it, since when) in the 409 payload.
  class Busy < StandardError
    attr_reader :active_task_run

    def initialize(active_task_run)
      @active_task_run = active_task_run
      super("another task is already in progress for app=#{active_task_run.app}")
    end
  end

  # Raised when `sync` is requested while a deploy is in flight on the same
  # app. Same shape as Busy but pointing at the offending deploy so the
  # caller knows where to look.
  class DeployInFlight < StandardError
    attr_reader :active_deploy

    def initialize(active_deploy)
      @active_deploy = active_deploy
      super("cannot run sync while deploy ##{active_deploy.id} is in progress for app=#{active_deploy.app}")
    end
  end

  attr_reader :task_run

  def initialize(app:, env:, task_name:, branch: 'main', args: {},
                  triggered_by: nil, token_jti: nil,
                  app_config: nil, runner_class: CommandRunner,
                  logger: Rails.logger)
    @app = app
    @env = env
    @task_name = task_name.to_s
    @branch = branch
    @args = args || {}
    @triggered_by = triggered_by
    @token_jti = token_jti
    @app_config = app_config || AppConfig.new(app: app)
    @runner_class = runner_class
    @logger = logger
  end

  # Creates the TaskRun without running anything. Used by async mode so the
  # HTTP response can return the task_run_id immediately while a background
  # thread does the work. Also performs the sync-vs-deploy cross-check so
  # the conflict surfaces to the caller before we even hit the DB lock.
  def enqueue
    ensure_no_active_deploy_for_sync!

    @task_run ||= TaskRun.create!(
      app: @app,
      env: @env,
      task_name: @task_name,
      branch: @branch,
      args: @args,
      status: 'pending',
      triggered_by: @triggered_by,
      token_jti: @token_jti
    )
  rescue ActiveRecord::RecordNotUnique
    raise Busy, TaskRun.active_for(@app).first
  end

  def call(&block)
    @block = block
    enqueue

    emit(:info, task_run_id: @task_run.id, app: @app, env: @env, task: @task_name,
                branch: @branch, args: @args,
                message: "starting task=#{@task_name} app=#{@app} branch=#{@branch} -> #{@env}")

    exit_code = execute_runner
    @task_run.mark_finished!(exit_code: exit_code)
    emit(:done, task_run_id: @task_run.id, exit_code: exit_code, status: @task_run.status)
    @task_run
  rescue Busy, DeployInFlight
    raise
  rescue StandardError => e
    @logger.error("[task] #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    emit(:error, message: "#{e.class}: #{e.message}")
    finalize_on_error(e)
    @task_run
  end

  private

  # The reserved `sync` task rewrites the working directory via git reset
  # --hard. Letting it race with a deploy would corrupt the checkout the
  # deploy is currently using. Non-sync tasks don't touch git, so they're
  # free to run alongside a deploy on the same app.
  def ensure_no_active_deploy_for_sync!
    return unless @task_name == AppConfig::SYNC_TASK_NAME

    active = Deploy.active_for(@app).first
    raise DeployInFlight, active if active
  end

  def execute_runner
    command_string = @app_config.task_for(
      name: @task_name, env: @env, branch: @branch, args: @args
    )

    runner = @runner_class.new(
      app: @app, env: @env, branch: @branch,
      command: @task_name, app_config: @app_config,
      command_string: command_string
    )
    @task_run.mark_running!

    runner.run do |line|
      @task_run.append_log!("#{line}\n")
      emit(:log, line: line)
    end
  rescue CommandRunner::Error, AppConfig::Error => e
    emit(:error, message: e.message)
    1
  end

  def finalize_on_error(error)
    return unless @task_run

    @task_run.update!(
      status: 'failed',
      exit_code: @task_run.exit_code || 1,
      finished_at: Time.current
    )
    emit(:done, task_run_id: @task_run.id, exit_code: @task_run.exit_code,
                status: 'failed', error: error.message)
  end

  def emit(event, payload)
    @block&.call(event, payload)
  end
end
