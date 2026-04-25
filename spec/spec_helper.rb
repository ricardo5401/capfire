# frozen_string_literal: true

# Pure-Ruby spec helper — loaded by every spec.
# Specs that need Rails (DB, controllers, JwtService secret) require
# `rails_helper` on top, which delegates to ActiveSupport's test framework.
RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.warnings = true

  # `--only-failures` and `--next-failure` between runs.
  config.example_status_persistence_file_path = 'tmp/rspec_status.txt'

  config.default_formatter = 'doc' if config.files_to_run.one?

  config.order = :random
  Kernel.srand config.seed
end
