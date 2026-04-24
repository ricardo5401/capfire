# frozen_string_literal: true

module CapfireCli
  # `bin/capfire service restart|status|logs` — thin wrappers around systemctl
  # for the Capfire service unit. Intentionally thin: the install script is
  # the source of truth for the unit file; these commands only spare you from
  # typing the unit name.
  class ServiceCommand < Thor
    package_name 'capfire service'

    DEFAULT_UNIT = 'capfire.service'

    desc 'restart', 'Restart the Capfire systemd service'
    method_option :unit, type: :string, required: false, desc: "Override the unit name (default: #{DEFAULT_UNIT})"
    def restart
      exec_systemctl('restart', options[:unit] || DEFAULT_UNIT)
    end

    desc 'status', 'Show the Capfire systemd service status'
    method_option :unit, type: :string, required: false
    def status
      exec_systemctl('status', options[:unit] || DEFAULT_UNIT)
    end

    desc 'logs', 'Tail Capfire logs via journalctl'
    method_option :unit,  type: :string,  required: false
    method_option :lines, type: :numeric, required: false, default: 200
    method_option :follow, type: :boolean, required: false, default: true
    def logs
      unit = options[:unit] || DEFAULT_UNIT
      cmd = [ 'journalctl', '-u', unit, '-n', options[:lines].to_s ]
      cmd << '-f' if options[:follow]
      system(*cmd)
    end

    private

    def exec_systemctl(action, unit)
      unless command_available?('systemctl')
        raise Thor::Error, 'systemctl not found. Are you on a non-systemd OS? Restart the service manually.'
      end

      system('sudo', 'systemctl', action, unit)
    end

    def command_available?(cmd)
      system("command -v #{cmd} > /dev/null 2>&1")
    end
  end
end
