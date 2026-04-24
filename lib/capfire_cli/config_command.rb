# frozen_string_literal: true

module CapfireCli
  # `bin/capfire config` — prints the environment variables Capfire consumes
  # at boot and whether each is set. DOES NOT reveal secrets; values of
  # variables marked `secret: true` are shown as `[set]` / `[missing]`.
  #
  # Purpose: give the admin a one-shot diagnostic they can run on the server
  # without opening `.env` files or the initializer code.
  class ConfigCommand
    # Each entry:
    #   name:     ENV var name
    #   desc:     one-liner help
    #   secret:   true → never print the actual value
    #   default:  human-readable fallback shown when unset
    VARS = [
      { name: 'CAPFIRE_JWT_SECRET', desc: 'HMAC secret used to sign API tokens',
        secret: true, required_in_prod: true },
      { name: 'CAPFIRE_APPS_ROOT', desc: 'Directory where app checkouts live',
        default: '/srv/apps' },
      { name: 'CAPFIRE_ALLOWED_APPS', desc: 'Comma-separated allowlist; empty means any',
        default: '(any app)' },
      { name: 'CAPFIRE_PUBLIC_URL', desc: 'Base URL returned in async deploy track_urls',
        default: '(request.base_url)' },
      { name: 'CF_API_TOKEN', desc: 'Cloudflare API token for LB drain/restore',
        secret: true },
      { name: 'SLACK_WEBHOOK_URL', desc: 'Default Slack webhook (per-app override via capfire.yml)',
        secret: true },
      { name: 'DATABASE_URL', desc: 'Postgres connection string',
        secret: true, required_in_prod: true },
      { name: 'RAILS_ENV', desc: 'Rails environment',
        default: 'development' },
      { name: 'RAILS_MAX_THREADS', desc: 'Puma max threads per worker',
        default: '16' },
      { name: 'PORT', desc: 'HTTP port Capfire listens on',
        default: '3000' }
    ].freeze

    def show
      puts 'Capfire server configuration'
      puts "  apps_root: #{Capfire.config.apps_root}" if defined?(Capfire)
      puts '  vars:'
      VARS.each { |var| print_var(var) }
      puts
      warn_missing_required
    end

    private

    def print_var(var)
      raw = ENV[var[:name]]
      state, display = render_value(raw, var)
      label = var[:name].ljust(24)
      puts "    #{label} #{state}  #{display}"
      puts "    #{' ' * 24}   └─ #{var[:desc]}"
    end

    def render_value(raw, var)
      if raw.present?
        value = var[:secret] ? '[set]' : raw
        [ '[OK]', value ]
      elsif var[:default]
        [ '[--]', "(default: #{var[:default]})" ]
      else
        [ '[--]', '(unset)' ]
      end
    end

    def warn_missing_required
      missing = VARS.select { |v| v[:required_in_prod] && ENV[v[:name]].blank? }
      return if missing.empty?

      puts 'Missing required vars for production:'
      missing.each { |v| puts "  - #{v[:name]}  (#{v[:desc]})" }
    end
  end
end
