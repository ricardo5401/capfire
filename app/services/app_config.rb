# frozen_string_literal: true

require 'yaml'

# Loads the per-app configuration file (`capfire.yml`) living inside an app's
# working directory and exposes a stable API for the rest of the system.
#
# The config file is OPTIONAL. If absent, every method returns sensible
# defaults so existing Capistrano-based Rails apps keep working without any
# yaml changes.
#
# Expected file layout (all sections optional):
#
#   commands:
#     deploy:   "bundle exec cap %{env} deploy BRANCH=%{branch}"
#     restart:  "bundle exec cap %{env} puma:restart"
#     rollback: "bundle exec cap %{env} deploy:rollback"
#     status:   "bundle exec cap %{env} deploy:check"
#
#   environments:
#     production:
#       commands:              # optional per-env overrides
#         restart: "..."
#       load_balancer:
#         enabled: true        # defaults to true when the block is present
#         pool_id: "..."
#         account_id: "..."    # optional, for account-scoped pools
#         origin: "35.185.55.232"
#     staging:
#       load_balancer:
#         enabled: false
#
#   git_sync: false            # opt out of the auto `git fetch + checkout +
#                              # reset --hard` that runs before every deploy.
#                              # Default: true. Only applies to the `deploy`
#                              # command; restart/rollback/status never sync.
#
#   pre_deploy:                # shell commands run BEFORE the deploy command.
#     - "bundle install"       # Only applies to `deploy` (not restart/etc).
#     - "yarn install"         # Runs after git_sync, chained with `&&`, so
#                              # any failure aborts the deploy.
#
#   slack:                     # Slack notifications after deploy finishes.
#     enabled: true            # default: false
#     webhook_env: MY_WEBHOOK  # optional override; default ENV var is
#                              # SLACK_WEBHOOK_URL.
#
#   environments:
#     production:
#       link: "https://app..." # optional, appended to the Slack message so
#                              # the user can jump to the running app.
#
# Placeholders supported inside any command string:
#   %{app}    -> app slug passed to /deploys or /commands
#   %{env}    -> env name (production, staging, ...)
#   %{branch} -> branch to deploy
class AppConfig
  CONFIG_FILENAME = 'capfire.yml'

  DEFAULT_COMMANDS = {
    'deploy' => 'bundle exec cap %<env>s deploy BRANCH=%<branch>s',
    'restart' => 'bundle exec cap %<env>s deploy:restart',
    'rollback' => 'bundle exec cap %<env>s deploy:rollback',
    'status' => 'bundle exec cap %<env>s deploy:check'
  }.freeze

  class Error < StandardError; end
  class UnknownCommand < Error; end
  class InvalidConfig < Error; end

  attr_reader :app, :work_dir

  def initialize(app:, apps_root: Capfire.config.apps_root)
    @app = app
    @apps_root = apps_root
    @work_dir = resolve_work_dir
    @yaml = load_yaml
  end

  # Returns the shell command string to execute for the given command name
  # in the given environment, with placeholders interpolated.
  def command_for(command:, env:, branch: 'main')
    template = lookup_command_template(command, env)
    raise UnknownCommand, "unknown command: #{command}" if template.blank?

    format_template(template, env: env, branch: branch)
  end

  # Whether Capfire should auto-sync the work_dir with `origin/<branch>` before
  # running a `deploy` command. Defaults to true; opt out per-app via
  # `git_sync: false` in capfire.yml (useful for non-git apps or when the
  # deploy tool handles its own checkout).
  def git_sync?
    value = @yaml['git_sync']
    # Treat missing/nil as enabled; any explicit `false` disables it.
    return true if value.nil?

    !!value
  end

  # Returns an array of shell command strings to run before the `deploy`
  # command, in order. Typically `bundle install`, `yarn install`, or similar
  # dependency-refresh steps that should run after the git sync brings new
  # Gemfile.lock / package.json but before the actual deploy.
  def pre_deploy_commands
    raw = @yaml['pre_deploy']
    return [] if raw.blank?
    raise InvalidConfig, 'pre_deploy must be an array of strings' unless raw.is_a?(Array)

    raw.map(&:to_s).reject(&:empty?)
  end

  # Whether to post Slack notifications for this app on deploy completion
  # (success or failure). Opt-in per app. Requires a webhook URL available
  # via env var (default `SLACK_WEBHOOK_URL`).
  def slack_enabled?
    slack_section['enabled'] == true
  end

  # ENV variable name that holds the Slack webhook URL. Lets different apps
  # post to different channels without committing secrets to yaml.
  def slack_webhook_env
    slack_section['webhook_env'].presence || SlackNotifier::DEFAULT_WEBHOOK_ENV
  end

  # Public URL for the given env (optional). Shown as a "Abrir" link in the
  # Slack notification. Returns nil when not configured.
  def link_for(env)
    env_section(env)['link'].presence
  end

  # Returns a LoadBalancerConfig for the given env, or nil when the app+env
  # does not participate in a load balancer.
  def load_balancer_for(env)
    settings = env_section(env)['load_balancer']
    return nil if settings.blank?
    return nil if settings['enabled'] == false

    LoadBalancerConfig.new(
      pool_id: settings['pool_id'],
      account_id: settings['account_id'],
      origin: settings['origin']
    )
  end

  # True when the app has a capfire.yml file on disk.
  def customized?
    File.exist?(config_path)
  end

  def config_path
    File.join(work_dir, CONFIG_FILENAME)
  end

  private

  def resolve_work_dir
    slug = app.to_s.upcase.gsub(/[^A-Z0-9]+/, '_')
    override = ENV["CAPFIRE_APP_DIR_#{slug}"]
    return override if override.present?

    File.join(@apps_root, app.to_s)
  end

  def load_yaml
    return {} unless File.exist?(config_path)

    data = YAML.safe_load_file(config_path) || {}
    raise InvalidConfig, 'capfire.yml must be a mapping' unless data.is_a?(Hash)

    data
  rescue Psych::SyntaxError => e
    raise InvalidConfig, "invalid yaml in #{config_path}: #{e.message}"
  end

  def lookup_command_template(command, env)
    env_commands(env)[command] || base_commands[command] || DEFAULT_COMMANDS[command]
  end

  def base_commands
    @yaml['commands'] || {}
  end

  def env_commands(env)
    env_section(env)['commands'] || {}
  end

  def env_section(env)
    (@yaml['environments'] || {})[env.to_s] || {}
  end

  def slack_section
    @yaml['slack'] || {}
  end

  def format_template(template, env:, branch:)
    format(template, app: app, env: env, branch: branch)
  rescue KeyError => e
    raise InvalidConfig, "unknown placeholder in command template: #{e.message}"
  end
end
