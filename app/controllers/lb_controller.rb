# frozen_string_literal: true

# Exposes direct Load Balancer operations without a deploy attached.
#
# Useful for orchestrators (GitHub Actions, custom CI scripts) that need to
# coordinate drain/restore across multiple nodes while running the actual
# deploy steps elsewhere — e.g. building assets centrally first, then
# rsyncing them to all nodes before flipping one out of the pool.
#
# Endpoints:
#   POST /lb/drain    { "app": "...", "env": "..." }
#   POST /lb/restore  { "app": "...", "env": "..." }
#
# Authorization: the token must include the `drain` or `restore` cmd claim
# for the given app + env.
class LbController < ApplicationController
  ACTIONS = {
    'drain' => :drain!,
    'restore' => :restore!
  }.freeze

  def drain
    perform('drain')
  end

  def restore
    perform('restore')
  end

  private

  def perform(action)
    app, env = require_app_and_env!
    authorize_action!(app: app, env: env, cmd: action)

    service, config = resolve_service(app: app, env: env)
    return if service.nil?

    service.public_send(ACTIONS.fetch(action))
    render json: success_payload(action: action, app: app, env: env, config: config)
  rescue CloudflareLbService::Error => e
    Rails.logger.error("[lb##{action}] #{e.class}: #{e.message}")
    render json: { error: 'cloudflare_error', message: e.message }, status: :bad_gateway
  end

  def require_app_and_env!
    params.require(:app)
    params.require(:env)
    [ params[:app], params[:env] ]
  end

  # Returns [service, config] when ready, or renders an error and returns nil.
  def resolve_service(app:, env:)
    config = AppConfig.new(app: app).load_balancer_for(env)
    return render_not_configured("no load_balancer block for app=#{app} env=#{env}") if config.nil?

    service = CloudflareLbService.new(config: config)
    unless service.configured?
      return render_not_configured('load_balancer block is incomplete (pool_id, origin, CF_API_TOKEN)')
    end

    [ service, config ]
  end

  def render_not_configured(message)
    render json: { error: 'not_configured', message: message }, status: :unprocessable_entity
    nil
  end

  def success_payload(action:, app:, env:, config:)
    {
      status: "#{action}d",
      app: app,
      env: env,
      pool_id: config.pool_id,
      origin: config.origin
    }
  end
end
