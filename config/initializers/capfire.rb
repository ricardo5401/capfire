# frozen_string_literal: true

# Capfire runtime config — read once at boot and exposed as an immutable struct.
#
# Load balancer settings (pool_id, account_id, origin) used to live here as
# global ENV vars. They are now PER-APP, configured inside each app's
# `capfire.yml`, so a single Capfire node can serve multiple apps with
# different LB topologies (or none at all). See `AppConfig`.
#
# The only Cloudflare-related global that remains is `CF_API_TOKEN`, which is
# a secret and should not live in checked-in yaml.

module Capfire
  Config = Struct.new(
    :jwt_secret,
    :jwt_algorithm,
    :apps_root,
    :allowed_apps,
    keyword_init: true
  ) do
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
      allowed_apps: parse_list(ENV['CAPFIRE_ALLOWED_APPS'])
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
