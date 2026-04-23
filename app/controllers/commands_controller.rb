class CommandsController < ApplicationController
  ALLOWED = %w[restart rollback status].freeze

  # POST /commands
  # body: { "app": "...", "env": "...", "cmd": "restart|rollback|status" }
  def create
    params.require(:app)
    params.require(:env)
    params.require(:cmd)

    app = params[:app]
    env = params[:env]
    cmd = params[:cmd]

    unless ALLOWED.include?(cmd)
      render json: { error: 'bad_request', message: "unknown command: #{cmd}" }, status: :bad_request
      return
    end

    authorize_action!(app: app, env: env, cmd: cmd)

    prepare_sse_response!
    sse = SseWriter.new(response.stream)

    begin
      DeployService.new(
        app: app,
        env: env,
        branch: params[:branch].presence || 'main',
        command: cmd,
        triggered_by: current_claims[:sub],
        token_jti: current_claims[:jti]
      ).call do |event, payload|
        sse.event(event, payload)
      end
    rescue StandardError => e
      Rails.logger.error("[commands#create] #{e.class}: #{e.message}")
      sse.event(:error, message: "#{e.class}: #{e.message}")
      sse.event(:done, exit_code: 1, status: 'failed', error: e.message)
    ensure
      sse.close
    end
  end
end
