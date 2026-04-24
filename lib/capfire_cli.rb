# frozen_string_literal: true

require 'thor'
require 'securerandom'

# Capfire CLI entry point. Autoloaded by bin/capfire.
module CapfireCli
  autoload :Main, 'capfire_cli/main'
  autoload :TokensCommand, 'capfire_cli/tokens_command'
  autoload :ProjectCommand, 'capfire_cli/project_command'
  autoload :ServiceCommand, 'capfire_cli/service_command'
  autoload :ConfigCommand, 'capfire_cli/config_command'
end
