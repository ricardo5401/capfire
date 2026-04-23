# frozen_string_literal: true

require 'faraday'
require 'faraday/retry'
require 'json'

# Drains and restores a node inside a Cloudflare Load Balancer pool.
#
# Strategy: flip the `enabled` flag on the matching origin entry rather than
# delete/recreate it, which preserves weights and health checks. Cloudflare's
# API expects a full `origins` array on PUT, so we fetch, mutate, and submit.
#
# Unlike previous versions, configuration is injected per instance via a
# LoadBalancerConfig. That makes the service per-app/per-env scoped and keeps
# multi-tenant Capfire nodes honest.
class CloudflareLbService
  class Error < StandardError; end
  class NotConfigured < Error; end
  class OriginNotFound < Error; end
  class ApiError < Error; end

  API_BASE = 'https://api.cloudflare.com/client/v4'

  def initialize(config:, logger: Rails.logger)
    @config = config
    @logger = logger
  end

  def configured?
    !!@config&.configured?
  end

  # Disables this node's origin in the pool. Safe no-op when not configured.
  def drain!
    return skip('drain') unless configured?

    set_origin_enabled!(false)
    @logger.info("[cloudflare] drained origin=#{@config.origin} pool=#{@config.pool_id}")
    true
  end

  # Re-enables this node's origin in the pool. Safe no-op when not configured.
  def restore!
    return skip('restore') unless configured?

    set_origin_enabled!(true)
    @logger.info("[cloudflare] restored origin=#{@config.origin} pool=#{@config.pool_id}")
    true
  end

  private

  def skip(action)
    @logger.info("[cloudflare] skipping #{action} — LB not configured")
    false
  end

  def set_origin_enabled!(enabled)
    pool = fetch_pool
    origins = pool.fetch('origins').map(&:dup)
    target = origins.find { |o| o['address'] == @config.origin }
    raise OriginNotFound, "origin #{@config.origin} not in pool #{@config.pool_id}" unless target

    target['enabled'] = enabled
    update_pool(origins)
  end

  def fetch_pool
    response = connection.get(pool_path)
    parse!(response).fetch('result')
  end

  def update_pool(origins)
    response = connection.put(pool_path) do |req|
      req.headers['Content-Type'] = 'application/json'
      req.body = JSON.generate(origins: origins)
    end
    parse!(response)
  end

  def pool_path
    if @config.account_id.present?
      "accounts/#{@config.account_id}/load_balancers/pools/#{@config.pool_id}"
    else
      "user/load_balancers/pools/#{@config.pool_id}"
    end
  end

  def parse!(response)
    body = JSON.parse(response.body.to_s.presence || '{}')
    unless response.success? && body['success']
      errors = body['errors'] || [{ 'message' => "HTTP #{response.status}" }]
      raise ApiError, "cloudflare api error: #{errors.map { |e| e['message'] }.join('; ')}"
    end
    body
  rescue JSON::ParserError => e
    raise ApiError, "cloudflare api returned non-json: #{e.message}"
  end

  def connection
    @connection ||= Faraday.new(url: API_BASE) do |f|
      f.request :retry, max: 3, interval: 0.5, backoff_factor: 2,
                        exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
      f.headers['Authorization'] = "Bearer #{@config.api_token}"
      f.headers['Accept'] = 'application/json'
      f.options.timeout = 10
      f.options.open_timeout = 5
      f.adapter Faraday.default_adapter
    end
  end
end
