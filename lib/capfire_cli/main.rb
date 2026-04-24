# frozen_string_literal: true

module CapfireCli
  # Top-level Thor command for `bin/capfire`.
  #
  # Ships only admin / server-side subcommands. The developer-facing client
  # (`capfire deploy`, `capfire restart`, etc.) lives in the separate Go CLI
  # under `client/`; do not pollute this file with anything a dev would run
  # from their laptop.
  class Main < Thor
    desc 'tokens SUBCOMMAND ...ARGS', 'Manage API tokens (create / list / revoke)'
    subcommand 'tokens', TokensCommand
    # Back-compat alias — earlier revisions used singular `token`.
    map 'token' => 'tokens'

    desc 'project SUBCOMMAND ...ARGS', 'Manage apps under CAPFIRE_APPS_ROOT'
    subcommand 'project', ProjectCommand
    map 'projects' => 'project'

    desc 'service SUBCOMMAND ...ARGS', 'Manage the Capfire systemd service'
    subcommand 'service', ServiceCommand

    desc 'config', 'Show current Capfire server configuration (env vars)'
    def config
      ConfigCommand.new.show
    end
    # Alias: user-facing name the setup docs use.
    map 'server-config' => 'config'

    desc 'restart', 'Restart the Capfire service (alias for `service restart`)'
    method_option :unit, type: :string, required: false
    def restart
      ServiceCommand.new([], options.slice(:unit)).restart
    end

    desc 'status', 'Show Capfire service status (alias for `service status`)'
    method_option :unit, type: :string, required: false
    def status
      ServiceCommand.new([], options.slice(:unit)).status
    end

    desc 'version', 'Print Capfire version'
    def version
      puts "capfire #{Capfire::VERSION}" if defined?(Capfire::VERSION)
      puts 'capfire unknown-version' unless defined?(Capfire::VERSION)
    end

    def self.exit_on_failure?
      true
    end
  end
end
