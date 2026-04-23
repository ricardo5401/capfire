module CapfireCli
  class Main < Thor
    desc 'token SUBCOMMAND ...ARGS', 'Manage API tokens'
    subcommand 'token', TokensCommand

    desc 'version', 'Print Capfire version'
    def version
      puts "capfire #{Capfire::VERSION}" if defined?(Capfire::VERSION)
      puts "capfire unknown-version" unless defined?(Capfire::VERSION)
    end

    def self.exit_on_failure?
      true
    end
  end
end
