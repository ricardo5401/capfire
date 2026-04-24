# frozen_string_literal: true

require_relative 'boot'

require 'rails'
# Pick only the frameworks Capfire actually needs.
require 'active_model/railtie'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'rails/test_unit/railtie'

Bundler.require(*Rails.groups)

module Capfire
  class Application < Rails::Application
    config.load_defaults 7.1

    # API-only mode.
    config.api_only = true

    # Autoload lib/ for the CLI support code.
    config.autoload_lib(ignore: %w[assets tasks])

    # Stream-friendly response buffering defaults. Rack::ETag would buffer
    # the full response body to compute a hash, which breaks SSE streaming.
    # `MiddlewareStack#delete` uses `delete_if` internally, so it is a safe
    # no-op when Rack::ETag is not part of the API-only default stack.
    config.middleware.delete Rack::ETag

    # Time zone — all timestamps use UTC internally; Europe/Berlin for display only.
    config.time_zone = 'UTC'

    # Don't wrap params in a root key for API requests.
    config.action_controller.wrap_parameters_by_default = false
  end
end
