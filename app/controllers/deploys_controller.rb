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

  def create
    params.require(:app)
    params.require(:env)
    app = params[:app]
    env = params[:env]
    branch = params[:branch].presence || 'main'
    skip_lb = ActiveModel::Type::Boolean.new.cast(params[:skip_lb])
    async = ActiveModel::Type::Boolean.new.cast(params[:async])

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
  def show
    deploy = Deploy.find(params[:id])
    render(json: deploy.as_status_json.merge(log: deploy.log))
  rescue ActiveRecord::RecordNotFound
    render(json: { error: 'not_found' }, status: :not_found)
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
end
