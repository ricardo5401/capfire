class DeploysController < ApplicationController
  # POST /deploys
  # body: { "app": "...", "env": "...", "branch": "..." }
  # Response: text/event-stream — log, info, error and a terminal `done` event.
  def create
    params.require(:app)
    params.require(:env)
    branch = params[:branch].presence || 'main'
    app = params[:app]
    env = params[:env]

    authorize_action!(app: app, env: env, cmd: 'deploy')

    prepare_sse_response!
    sse = SseWriter.new(response.stream)

    begin
      DeployService.new(
        app: app,
        env: env,
        branch: branch,
        command: 'deploy',
        triggered_by: current_claims[:sub],
        token_jti: current_claims[:jti]
      ).call do |event, payload|
        sse.event(event, payload)
      end
    rescue StandardError => e
      Rails.logger.error("[deploys#create] #{e.class}: #{e.message}")
      sse.event(:error, message: "#{e.class}: #{e.message}")
      sse.event(:done, exit_code: 1, status: 'failed', error: e.message)
    ensure
      sse.close
    end
  end

  # GET /deploys/:id
  def show
    deploy = Deploy.find(params[:id])
    render json: deploy.as_status_json.merge(log: deploy.log)
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'not_found' }, status: :not_found
  end
end
