# frozen_string_literal: true

# Endpoint for deploy lifecycle operations.
#
# Two modes:
#   - Streaming (default): returns text/event-stream with log lines in real
#     time. Connection stays open until the deploy finishes.
#   - Async (`async: true`): returns 202 Accepted with the deploy_id
#     immediately. The deploy runs in a background thread. Status can be
#     polled via GET /deploys/:id and Slack notifies on completion (if
#     enabled in the app's capfire.yml).
#
# Concurrency: only one active deploy (pending or running) is allowed per
# `app+env`. A second concurrent POST returns 409 Conflict with info about
# the in-flight deploy.
class DeploysController < ApplicationController
  include Runnable

  SUBSYSTEM = 'deploys#create'

  DEFAULT_LIMIT = 20
  MAX_LIMIT = 100

  # GET /deploys
  #
  # Lists deploys triggered by the current token holder (`sub` claim). Never
  # exposes deploys from other people — keeps the client honest about "mine
  # only" by default. Supports a few optional filters:
  #
  #   ?active=true   => only status in (pending, running)
  #   ?app=NAME      => filter by app
  #   ?env=NAME      => filter by env
  #   ?status=NAME   => one of Deploy::STATUSES
  #   ?limit=N       => cap rows (default 20, max 100)
  def index
    scope = Deploy.where(triggered_by: current_claims[:sub]).recent
    scope = scope.active if truthy?(params[:active])

    if params[:app].present?
      scope = scope.where(app: safe_identifier!(params[:app], as: 'app', pattern: APP_PATTERN))
    end
    if params[:env].present?
      scope = scope.where(env: safe_identifier!(params[:env], as: 'env', pattern: ENV_PATTERN))
    end
    if params[:status].present?
      raise InvalidParameter, 'invalid status' unless Deploy::STATUSES.include?(params[:status])

      scope = scope.where(status: params[:status])
    end

    scope = scope.limit(parse_limit(params[:limit]))
    render(json: { deploys: scope.map(&:as_status_json) })
  end

  def create
    params.require(:app)
    params.require(:env)
    app    = safe_identifier!(params[:app], as: 'app', pattern: APP_PATTERN)
    env    = safe_identifier!(params[:env], as: 'env', pattern: ENV_PATTERN)
    branch = safe_branch!(params[:branch].presence || 'main')
    skip_lb = ActiveModel::Type::Boolean.new.cast(params[:skip_lb])
    async   = ActiveModel::Type::Boolean.new.cast(params[:async])

    authorize_action!(app: app, env: env, cmd: 'deploy')

    service = build_service(app: app, env: env, branch: branch, skip_lb: skip_lb)

    if async
      run_async(service, subsystem: SUBSYSTEM, extra: async_payload(app, env, branch))
    else
      run_streaming(service, subsystem: SUBSYSTEM)
    end
  rescue DeployService::Busy => e
    render_busy(e.active_deploy)
  end

  # GET /deploys/:id
  #
  # Only returns deploys triggered by the same token holder. Prevents a valid
  # token from reading log output of deploys run by other users — logs may
  # contain stack traces, secrets leaked by the deploy command, etc.
  def show
    deploy = Deploy.find_by(id: params[:id], triggered_by: current_claims[:sub])
    return render(json: { error: 'not_found' }, status: :not_found) unless deploy

    render(json: deploy.as_status_json.merge(log: deploy.log))
  end

  private

  def build_service(app:, env:, branch:, skip_lb:)
    DeployService.new(
      app: app, env: env, branch: branch,
      command: 'deploy', skip_lb: skip_lb,
      triggered_by: current_claims[:sub],
      token_jti: current_claims[:jti]
    )
  end

  def async_payload(app, env, branch)
    {
      app: app,
      env: env,
      branch: branch,
      message: 'Deploy queued. Slack will notify on completion if enabled; poll the track_url for status.'
    }
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
