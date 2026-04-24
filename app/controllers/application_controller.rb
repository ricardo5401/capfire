# frozen_string_literal: true

# Base controller. Every request is authenticated via JWT (bearer token) and
# authorized per-action via `authorize_action!`. Streaming responses prepare
# headers through `prepare_sse_response!`.
class ApplicationController < ActionController::API
  include ActionController::Live

  # Strict input patterns. Values from HTTP params land directly in shell
  # commands via `sh -c` (see CommandRunner), so anything not matching these
  # regexes is rejected before it reaches the shell. Tightening is safer
  # than escaping — `app`/`env` slugs are never more exotic than these, and
  # branches in every real git host conform to the allowed charset.
  APP_PATTERN    = /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\z/
  ENV_PATTERN    = /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}\z/
  BRANCH_PATTERN = %r{\A[a-zA-Z0-9][a-zA-Z0-9._/-]{0,254}\z}

  # Raised when an HTTP parameter fails the above validation. Rendered as
  # 400 Bad Request with a generic message — we never echo back the raw
  # rejected value to avoid reflecting attacker-controlled content.
  class InvalidParameter < StandardError; end

  before_action :authenticate_request!

  attr_reader :current_claims

  rescue_from JwtService::Unauthorized, with: :render_forbidden
  rescue_from JwtService::Error, with: :render_unauthorized
  rescue_from ActionController::ParameterMissing, with: :render_bad_request
  rescue_from InvalidParameter, with: :render_bad_request

  private

  # Validates a plain identifier (app, env) against a whitelist pattern.
  # Never trust these values to be shell-safe unless they passed here.
  def safe_identifier!(value, as:, pattern:)
    value = value.to_s
    raise InvalidParameter, "invalid #{as}" unless value.match?(pattern)

    value
  end

  # Branches get their own helper because we also reject `..` sequences,
  # which would otherwise let someone steer `git checkout` into a
  # path-traversal-shaped ref.
  def safe_branch!(value)
    value = value.to_s
    return value if value.match?(BRANCH_PATTERN) && !value.include?('..')

    raise InvalidParameter, 'invalid branch'
  end

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
