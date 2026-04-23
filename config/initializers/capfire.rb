# Capfire runtime config — read once at boot and exposed as immutable struct.

module Capfire
  Config = Struct.new(
    :jwt_secret,
    :jwt_algorithm,
    :apps_root,
    :allowed_apps,
    :cf_api_token,
    :cf_account_id,
    :cf_pool_id,
    :cf_node_origin,
    :cf_disabled,
    keyword_init: true
  ) do
    def cloudflare_configured?
      !cf_disabled && cf_api_token.present? && cf_pool_id.present? && cf_node_origin.present?
    end

    def app_allowed?(app)
      return true if allowed_apps.empty?

      allowed_apps.include?(app)
    end
  end

  def self.config
    @config ||= build_config
  end

  def self.build_config
    Config.new(
      jwt_secret: ENV.fetch('CAPFIRE_JWT_SECRET') { default_jwt_secret },
      jwt_algorithm: 'HS256',
      apps_root: ENV.fetch('CAPFIRE_APPS_ROOT', '/srv/apps'),
      allowed_apps: parse_list(ENV['CAPFIRE_ALLOWED_APPS']),
      cf_api_token: ENV['CF_API_TOKEN'],
      cf_account_id: ENV['CF_ACCOUNT_ID'],
      cf_pool_id: ENV['CF_POOL_ID'],
      cf_node_origin: ENV['CF_NODE_ORIGIN'],
      cf_disabled: %w[1 true yes].include?(ENV['CF_DISABLE'].to_s.downcase)
    )
  end

  def self.parse_list(raw)
    return [] if raw.nil? || raw.strip.empty?

    raw.split(',').map(&:strip).reject(&:empty?)
  end

  def self.default_jwt_secret
    if Rails.env.production?
      raise 'CAPFIRE_JWT_SECRET must be set in production'
    end

    'development-only-insecure-secret-change-me'
  end
end
