# frozen_string_literal: true

# Endpoint for one-shot commands: restart, rollback, status.
#
# Mirrors DeploysController's two modes (streaming + async) and shares the
# same concurrency lock: a running deploy and a running restart on the same
# app+env don't coexist.
class CommandsController < ApplicationController
  ALLOWED = %w[restart rollback status].freeze

  def create
    params.require(:app)
    params.require(:env)
    params.require(:cmd)

    app = params[:app]
    env = params[:env]
    cmd = params[:cmd]
    branch = params[:branch].presence || 'main'
    async = ActiveModel::Type::Boolean.new.cast(params[:async])

    unless ALLOWED.include?(cmd)
      render(json: { error: 'bad_request', message: "unknown command: #{cmd}" }, status: :bad_request)
      return
    end

    authorize_action!(app: app, env: env, cmd: cmd)

    service = DeployService.new(
      app: app, env: env, branch: branch, command: cmd,
      triggered_by: current_claims[:sub],
      token_jti: current_claims[:jti]
    )

    if async
      run_async(service, app: app, env: env, cmd: cmd, branch: branch)
    else
      run_streaming(service)
    end
  rescue DeployService::Busy => e
    render_busy(e.active_deploy)
  end

  private

  def run_streaming(service)
    prepare_sse_response!
    sse = SseWriter.new(response.stream)

    begin
      service.call { |event, payload| sse.event(event, payload) }
    rescue DeployService::Busy
      sse.event(:error, message: 'another operation in progress for this app+env')
      sse.event(:done, exit_code: 1, status: 'failed', error: 'busy')
    rescue StandardError => e
      Rails.logger.error("[commands#create] #{e.class}: #{e.message}")
      sse.event(:error, message: "#{e.class}: #{e.message}")
      sse.event(:done, exit_code: 1, status: 'failed', error: e.message)
    ensure
      sse.close
    end
  end

  def run_async(service, app:, env:, cmd:, branch:)
    deploy = service.enqueue

    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        service.call { |_event, _payload| }
      end
    rescue StandardError => e
      Rails.logger.error("[async-command] #{e.class}: #{e.message}")
    end

    render(json: {
             status: 'accepted',
             deploy_id: deploy.id,
             app: app,
             env: env,
             command: cmd,
             branch: branch,
             track_url: tracking_url(deploy.id),
             message: "#{cmd} queued. Slack will notify on completion if enabled; poll the track_url for status."
           }, status: :accepted)
  end

  def tracking_url(deploy_id)
    base = ENV['CAPFIRE_PUBLIC_URL'].presence || request.base_url
    "#{base.sub(%r{/$}, '')}/deploys/#{deploy_id}"
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
