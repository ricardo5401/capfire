# frozen_string_literal: true

# Base controller. Every request is authenticated via JWT (bearer token) and
# authorized per-action via `authorize_action!`. Streaming responses prepare
# headers through `prepare_sse_response!`.
class ApplicationController < ActionController::API
  include ActionController::Live

  before_action :authenticate_request!

  attr_reader :current_claims

  rescue_from JwtService::Unauthorized, with: :render_forbidden
  rescue_from JwtService::Error, with: :render_unauthorized
  rescue_from ActionController::ParameterMissing, with: :render_bad_request

  private

  def authenticate_request!
    token = extract_bearer_token
    @current_claims = JwtService.decode!(token)
  end

  def extract_bearer_token
    header = request.headers['Authorization'].to_s
    return nil unless header.start_with?('Bearer ')

    header.split(' ', 2).last
  end

  def authorize_action!(app:, env:, cmd:)
    JwtService.authorize!(claims: current_claims, app: app, env: env, cmd: cmd)
    return if Capfire.config.app_allowed?(app)

    raise JwtService::Unauthorized, "app=#{app} is not allowlisted on this node"
  end

  def render_unauthorized(err)
    render json: { error: 'unauthorized', message: err.message }, status: :unauthorized
  end

  def render_forbidden(err)
    render json: { error: 'forbidden', message: err.message }, status: :forbidden
  end

  def render_bad_request(err)
    render json: { error: 'bad_request', message: err.message }, status: :bad_request
  end

  # Prepares the response for an SSE stream. Call BEFORE writing any chunks.
  def prepare_sse_response!
    response.headers['Content-Type'] = 'text/event-stream'
    response.headers['Cache-Control'] = 'no-cache, no-store, must-revalidate'
    response.headers['Connection'] = 'keep-alive'
    response.headers['X-Accel-Buffering'] = 'no' # nginx: disable proxy buffering
    response.headers.delete('Content-Length')
  end
end
