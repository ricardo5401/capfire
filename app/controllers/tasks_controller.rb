# frozen_string_literal: true

# Endpoint for custom tasks defined under `tasks:` in an app's `capfire.yml`,
# plus the reserved built-in `sync` task.
#
# Tasks are application-level work (reindex, backfill, sync, data migrations)
# and run with their own per-app concurrency lock that is independent of the
# deploy lock — except for `sync`, which mutates the working directory and
# therefore blocks (and is blocked by) deploys on the same app.
#
# Two execution modes, identical to /deploys:
#   - Streaming (default): SSE with log lines in real time.
#   - Async (`async: true`): 202 with track_url and a background thread.
#
# Concurrency contract:
#   - 409 if another task is already pending/running for the same app.
#   - 409 if the request is `sync` and a deploy is in flight on the same app.
#   - Non-sync tasks may run concurrently with deploys of the SAME app —
#     intentional, so a long backfill never freezes a hotfix.
class TasksController < ApplicationController
  include Runnable

  SUBSYSTEM = 'tasks#create'

  DEFAULT_LIMIT = 20
  MAX_LIMIT = 100

  # Strict task name whitelist. Same reasoning as APP_PATTERN: this value
  # ends up in shell commands via `sh -c`, so we never let through anything
  # that wasn't validated upfront. Matches the keys allowed in capfire.yml.
  TASK_NAME_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\z/

  # GET /tasks
  #
  # Lists task runs triggered by the current token holder. Mirrors the
  # privacy posture of /deploys#index — never expose runs from other users.
  def index
    scope = TaskRun.where(triggered_by: current_claims[:sub]).recent
    scope = scope.active if truthy?(params[:active])

    if params[:app].present?
      scope = scope.where(app: safe_identifier!(params[:app], as: 'app', pattern: APP_PATTERN))
    end
    if params[:env].present?
      scope = scope.where(env: safe_identifier!(params[:env], as: 'env', pattern: ENV_PATTERN))
    end
    if params[:task].present?
      scope = scope.where(task_name: safe_task_name!(params[:task]))
    end
    if params[:status].present?
      raise InvalidParameter, 'invalid status' unless TaskRun::STATUSES.include?(params[:status])

      scope = scope.where(status: params[:status])
    end

    scope = scope.limit(parse_limit(params[:limit]))
    render(json: { task_runs: scope.map(&:as_status_json) })
  end

  # POST /tasks
  def create
    params.require(:app)
    params.require(:env)
    params.require(:task)

    app    = safe_identifier!(params[:app], as: 'app', pattern: APP_PATTERN)
    env    = safe_identifier!(params[:env], as: 'env', pattern: ENV_PATTERN)
    task   = safe_task_name!(params[:task])
    branch = safe_branch!(params[:branch].presence || 'main')
    args   = parse_args(params[:args])
    async  = ActiveModel::Type::Boolean.new.cast(params[:async])

    # Authorize with cmd="task:<name>" so a single token system covers both
    # the legacy commands and the new task surface. JWT grants list this in
    # the `cmds:` array (or use the new `tasks: [...]` shorthand which is
    # translated upstream in JwtService).
    authorize_action!(app: app, env: env, cmd: "task:#{task}")

    # Build AppConfig once and reuse for both validation and execution so a
    # bad capfire.yml fails the request BEFORE we create a TaskRun.
    app_config = AppConfig.new(app: app)
    unless app_config.known_task?(task)
      render(json: {
        error: 'bad_request',
        message: "unknown task `#{task}` for app=#{app}",
        available_tasks: app_config.task_names
      }, status: :bad_request)
      return
    end

    service = build_service(
      app: app, env: env, task: task, branch: branch, args: args, app_config: app_config
    )

    if async
      run_async(service, subsystem: SUBSYSTEM, resource: :task,
                         extra: async_payload(app, env, task, branch, args))
    else
      run_streaming(service, subsystem: SUBSYSTEM)
    end
  rescue TaskService::Busy => e
    render_task_busy(e.active_task_run)
  rescue TaskService::DeployInFlight => e
    render_deploy_in_flight(e.active_deploy)
  rescue AppConfig::Error => e
    render(json: { error: 'bad_request', message: e.message }, status: :bad_request)
  end

  # GET /tasks/:id
  #
  # Same privacy rule as /deploys/:id: only the original triggerer can read
  # the log. Drives the CLI's `--wait` polling and the standalone tracking
  # use case.
  def show
    task_run = TaskRun.find_by(id: params[:id], triggered_by: current_claims[:sub])
    return render(json: { error: 'not_found' }, status: :not_found) unless task_run

    render(json: task_run.as_status_json.merge(log: task_run.log))
  end

  private

  def build_service(app:, env:, task:, branch:, args:, app_config:)
    TaskService.new(
      app: app, env: env, task_name: task, branch: branch, args: args,
      app_config: app_config,
      triggered_by: current_claims[:sub],
      token_jti: current_claims[:jti]
    )
  end

  def safe_task_name!(value)
    safe_identifier!(value, as: 'task', pattern: TASK_NAME_PATTERN)
  end

  # `args` accepts:
  #   - JSON body: { "args": { "since": "2024-01-01" } }
  #   - Form-style nested params: args[since]=2024-01-01
  # We coerce everything to a flat string-keyed hash so AppConfig sees a
  # predictable shape regardless of how the client serialized the request.
  def parse_args(raw)
    return {} if raw.blank?

    hash = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
    raise InvalidParameter, 'args must be an object' unless hash.is_a?(Hash)

    hash.each_with_object({}) do |(key, value), acc|
      raise InvalidParameter, 'args keys must be scalar' if key.is_a?(Hash) || key.is_a?(Array)
      raise InvalidParameter, 'args values must be scalar' if value.is_a?(Hash) || value.is_a?(Array)

      acc[key.to_s] = value.to_s
    end
  end

  def async_payload(app, env, task, branch, args)
    {
      app: app,
      env: env,
      task: task,
      branch: branch,
      args: args,
      message: "task=#{task} queued. Poll the track_url for status."
    }
  end

  def render_task_busy(active_task_run)
    render(json: {
      error: 'conflict',
      message: "another task is already in progress for app=#{active_task_run.app}",
      active: {
        task_run_id: active_task_run.id,
        task: active_task_run.task_name,
        env: active_task_run.env,
        branch: active_task_run.branch,
        status: active_task_run.status,
        triggered_by: active_task_run.triggered_by,
        started_at: active_task_run.started_at
      },
      retry_after_seconds: 60
    }, status: :conflict)
  end

  def render_deploy_in_flight(active_deploy)
    render(json: {
      error: 'conflict',
      message: "cannot run sync while a deploy is in progress for app=#{active_deploy.app}",
      active_deploy: {
        id: active_deploy.id,
        command: active_deploy.command,
        branch: active_deploy.branch,
        status: active_deploy.status,
        triggered_by: active_deploy.triggered_by,
        started_at: active_deploy.started_at
      },
      retry_after_seconds: 120
    }, status: :conflict)
  end

  def truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def parse_limit(raw)
    return DEFAULT_LIMIT if raw.blank?

    value = raw.to_i
    return DEFAULT_LIMIT if value <= 0

    [ value, MAX_LIMIT ].min
  end
end
