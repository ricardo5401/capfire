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
  def create
    params.require(:app)
    params.require(:env)
    app = params[:app]
    env = params[:env]
    branch = params[:branch].presence || 'main'
    skip_lb = ActiveModel::Type::Boolean.new.cast(params[:skip_lb])
    async = ActiveModel::Type::Boolean.new.cast(params[:async])

    authorize_action!(app: app, env: env, cmd: 'deploy')

    service = DeployService.new(
      app: app, env: env, branch: branch,
      command: 'deploy', skip_lb: skip_lb,
      triggered_by: current_claims[:sub],
      token_jti: current_claims[:jti]
    )

    if async
      run_async(service, app: app, env: env, branch: branch)
    else
      run_streaming(service)
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

  # Streams the deploy over SSE (original behavior).
  def run_streaming(service)
    prepare_sse_response!
    sse = SseWriter.new(response.stream)

    begin
      service.call { |event, payload| sse.event(event, payload) }
    rescue DeployService::Busy
      # Can't emit the 409 over SSE (headers already sent). Surface as an
      # error event and close. The terminal `done` with status failed means
      # tooling treats it as a failed deploy.
      sse.event(:error, message: 'deploy already in progress for this app+env')
      sse.event(:done, exit_code: 1, status: 'failed', error: 'busy')
    rescue StandardError => e
      Rails.logger.error("[deploys#create] #{e.class}: #{e.message}")
      sse.event(:error, message: "#{e.class}: #{e.message}")
      sse.event(:done, exit_code: 1, status: 'failed', error: e.message)
    ensure
      sse.close
    end
  end

  # Fires the deploy in a background thread and returns 202 immediately.
  def run_async(service, app:, env:, branch:)
    deploy = service.enqueue
    spawn_background_deploy(service)

    render(json: {
             status: 'accepted',
             deploy_id: deploy.id,
             app: app,
             env: env,
             branch: branch,
             track_url: tracking_url(deploy.id),
             message: 'Deploy queued. Slack will notify on completion if enabled; poll the track_url for status.'
           }, status: :accepted)
  end

  # Builds the public URL clients can poll to check deploy status. Respects
  # CAPFIRE_PUBLIC_URL if set (useful when Capfire runs behind a proxy that
  # rewrites Host headers); falls back to request.base_url otherwise.
  def tracking_url(deploy_id)
    base = ENV['CAPFIRE_PUBLIC_URL'].presence || request.base_url
    "#{base.sub(%r{/$}, '')}/deploys/#{deploy_id}"
  end

  # Runs the deploy in a separate thread with its own DB connection. Events
  # are dropped (no subscriber); logs still persist to the Deploy record.
  def spawn_background_deploy(service)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        service.call { |_event, _payload| } # swallow SSE events in async mode
      end
    rescue StandardError => e
      Rails.logger.error("[async-deploy] #{e.class}: #{e.message}")
    end
  end

  def render_busy(active_deploy)
    render(json: {
             error: 'conflict',
             message: "another deploy is already in progress for #{active_deploy.app}:#{active_deploy.env}",
             active_deploy: {
               id: active_deploy.id,
               command: active_deploy.command,
               branch: active_deploy.branch,
               status: active_deploy.status,
               triggered_by: active_deploy.triggered_by,
               started_at: active_deploy.started_at
             },
             retry_after_seconds: 600
           }, status: :conflict)
  end
end
