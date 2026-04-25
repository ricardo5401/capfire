# frozen_string_literal: true

# Loaded by specs that need Rails: DB-backed models (Deploy, TaskRun),
# controllers, request specs, and anything that depends on
# `Capfire.config` (jwt_secret, apps_root).
require 'spec_helper'

ENV['RAILS_ENV'] ||= 'test'
require File.expand_path('../config/environment', __dir__)

# In a Rails 7+ API app `ActiveRecord::Migration.maintain_test_schema!`
# would clone the production schema into the test DB. We skip that on
# purpose so devs without a local Postgres can still run the unit specs
# (which don't touch the DB) by requiring `spec_helper` instead.
abort('Rails is running in production!') if Rails.env.production?
require 'rspec/rails'

Rails.application.eager_load!

RSpec.configure do |config|
  # Wraps every example in a transaction that rolls back on completion.
  # Plays well with the unique partial index on `app` for active deploys
  # and active task runs — leftover rows can't leak between tests.
  config.use_transactional_fixtures = true

  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
end
