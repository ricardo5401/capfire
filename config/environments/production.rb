require 'active_support/core_ext/integer/time'

Rails.application.configure do
  config.cache_classes = true
  config.eager_load = true
  config.consider_all_requests_local = false

  # Logs go to STDOUT so systemd / journald / Docker pick them up.
  logger = ActiveSupport::Logger.new($stdout)
  logger.formatter = config.log_formatter
  config.logger = ActiveSupport::TaggedLogging.new(logger)
  config.log_level = ENV.fetch('RAILS_LOG_LEVEL', 'info').to_sym

  config.active_record.dump_schema_after_migration = false
  config.active_support.report_deprecations = false
end
