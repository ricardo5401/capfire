require 'thor'
require 'securerandom'

# Capfire CLI entry point. Autoloaded by bin/capfire.
module CapfireCli
  autoload :Main, 'capfire_cli/main'
  autoload :TokensCommand, 'capfire_cli/tokens_command'
end
