# frozen_string_literal: true

# Endpoint for one-shot commands: restart, rollback, status.
#
# Mirrors DeploysController's two modes (streaming + async) and shares the
# same concurrency lock: a running deploy and a running restart on the same
# app+env don't coexist.
class CommandsController < ApplicationController
  include Runnable

  ALLOWED = %w[restart rollback status].freeze
  SUBSYSTEM = 'commands#create'

  def create
    params.require(:app)
    params.require(:env)
    params.require(:cmd)

    app    = safe_identifier!(params[:app], as: 'app', pattern: APP_PATTERN)
    env    = safe_identifier!(params[:env], as: 'env', pattern: ENV_PATTERN)
    cmd    = params[:cmd].to_s
    branch = safe_branch!(params[:branch].presence || 'main')
    async  = ActiveModel::Type::Boolean.new.cast(params[:async])

    unless ALLOWED.include?(cmd)
      render(json: { error: 'bad_request', message: 'unknown command' }, status: :bad_request)
      return
    end

    authorize_action!(app: app, env: env, cmd: cmd)

    service = build_service(app: app, env: env, branch: branch, cmd: cmd)

    if async
      run_async(service, subsystem: SUBSYSTEM, extra: async_payload(app, env, branch, cmd))
    else
      run_streaming(service, subsystem: SUBSYSTEM)
    end
  rescue DeployService::Busy => e
    render_busy(e.active_deploy)
  end

  private

  def build_service(app:, env:, branch:, cmd:)
    DeployService.new(
      app: app, env: env, branch: branch, command: cmd,
      triggered_by: current_claims[:sub],
      token_jti: current_claims[:jti]
    )
  end

  def async_payload(app, env, branch, cmd)
    {
      app: app,
      env: env,
      command: cmd,
      branch: branch,
      message: "#{cmd} queued. Slack will notify on completion if enabled; poll the track_url for status."
    }
  end
end
