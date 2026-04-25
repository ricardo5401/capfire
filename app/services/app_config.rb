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
#   tasks:                     # arbitrary user-defined work (NOT deploys).
#     reindex:                 # Each task lives under POST /tasks and gets
#       run: "python manage.py reindex --all"   # its own per-app lock that
#     backfill:                                 # is independent of the
#       run: "python scripts/backfill.py --since=%{since}"  # deploy lock.
#       params: [since]                          # Required keys in args.
#     sync:                    # RESERVED name. Built-in: `git fetch +
#       after:                 # checkout + reset --hard origin/<branch>`
#         - "uv sync"          # then runs each `after:` step chained with
#                              # `&&`. Override `run:` for full custom shell
#                              # (you lose the built-in git sync).
#
# Placeholders supported inside any command string:
#   %{app}    -> app slug passed to /deploys or /commands
#   %{env}    -> env name (production, staging, ...)
#   %{branch} -> branch to deploy
#   %{<key>}  -> any key declared in `params:` for a task (passed via `args`)
class AppConfig
  CONFIG_FILENAME = 'capfire.yml'

  DEFAULT_COMMANDS = {
    'deploy' => 'bundle exec cap %<env>s deploy BRANCH=%<branch>s',
    'restart' => 'bundle exec cap %<env>s deploy:restart',
    'rollback' => 'bundle exec cap %<env>s deploy:rollback',
    'status' => 'bundle exec cap %<env>s deploy:check'
  }.freeze

  # Reserved task name with built-in semantics: brings the working dir to the
  # tip of origin/<branch> using the same primitive as a deploy's git sync,
  # then runs the optional `after:` hooks declared by the app (typical:
  # `bundle install`, `uv sync`, `npm ci`).
  SYNC_TASK_NAME = 'sync'

  class Error < StandardError; end
  class UnknownCommand < Error; end
  class UnknownTask < Error; end
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

  # Returns the fully-resolved shell command string for a task defined under
  # `tasks:` in the yaml. Validates that all `params:` declared by the task
  # are present in `args` and that no unknown keys were passed.
  #
  # `sync` is a reserved name with built-in semantics:
  #   - default: `git fetch + checkout + reset --hard origin/<branch>` then
  #     `tasks.sync.after` hooks chained with `&&`.
  #   - if the user defines `tasks.sync.run`, that override wins and the
  #     built-in git sync is NOT prepended (escape hatch — full ownership).
  def task_for(name:, env:, branch: 'main', args: {})
    spec = task_spec(name)

    if name.to_s == SYNC_TASK_NAME && spec['run'].blank?
      build_sync_command(spec: spec, env: env, branch: branch, args: args)
    else
      build_user_task_command(name: name, spec: spec, env: env, branch: branch, args: args)
    end
  end

  # True when the app declares the task in capfire.yml OR the task is the
  # reserved `sync` (which has a built-in default and works even without an
  # explicit declaration).
  def known_task?(name)
    return false if name.blank?
    return true if name.to_s == SYNC_TASK_NAME

    tasks_section.key?(name.to_s)
  end

  # Names of every task callable on this app, including the reserved `sync`.
  # Used by the controller to validate input before authorization.
  def task_names
    names = tasks_section.keys.map(&:to_s)
    names << SYNC_TASK_NAME unless names.include?(SYNC_TASK_NAME)
    names.sort
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

  def tasks_section
    raw = @yaml['tasks'] || {}
    raise InvalidConfig, '`tasks` must be a mapping' unless raw.is_a?(Hash)

    raw
  end

  def task_spec(name)
    return {} if name.to_s == SYNC_TASK_NAME && !tasks_section.key?(SYNC_TASK_NAME)

    spec = tasks_section[name.to_s]
    raise UnknownTask, "unknown task: #{name}" if spec.nil?
    raise InvalidConfig, "task `#{name}` must be a mapping" unless spec.is_a?(Hash)

    spec
  end

  # Built-in `sync`: git sync + after hooks, all chained with `&&` so any
  # failure aborts. After hooks support the same placeholder set as user
  # tasks for consistency.
  def build_sync_command(spec:, env:, branch:, args:)
    declared_params = Array(spec['params']).map(&:to_s)
    validate_args!(name: SYNC_TASK_NAME, declared: declared_params, given: args)

    after = Array(spec['after']).map(&:to_s).reject(&:empty?)
    interpolated_after = after.map do |step|
      format_task_template(step, env: env, branch: branch, args: args)
    end

    [ CommandRunner.git_sync_command(branch: branch), *interpolated_after ].join(' && ')
  end

  def build_user_task_command(name:, spec:, env:, branch:, args:)
    template = spec['run'].to_s
    raise InvalidConfig, "task `#{name}` is missing a `run:` command" if template.empty?

    declared_params = Array(spec['params']).map(&:to_s)
    validate_args!(name: name, declared: declared_params, given: args)

    format_task_template(template, env: env, branch: branch, args: args)
  end

  # Strict params validation: every key declared under `params:` must be
  # present in args, and no extra keys are accepted. This catches typos at
  # call time instead of letting a malformed shell command fail mid-run with
  # a confusing error.
  def validate_args!(name:, declared:, given:)
    given_keys = (given || {}).keys.map(&:to_s)
    missing = declared - given_keys
    extra = given_keys - declared
    return if missing.empty? && extra.empty?

    parts = []
    parts << "missing params: #{missing.join(', ')}" if missing.any?
    parts << "unknown args: #{extra.join(', ')}" if extra.any?
    raise InvalidConfig, "task `#{name}`: #{parts.join('; ')}"
  end

  def format_template(template, env:, branch:)
    format(template, app: app, env: env, branch: branch)
  rescue KeyError => e
    raise InvalidConfig, "unknown placeholder in command template: #{e.message}"
  end

  # Tasks accept arbitrary user-declared `params:` on top of the standard
  # app/env/branch placeholders. We merge them with symbol keys so `format()`
  # finds whichever the user wrote in the template.
  def format_task_template(template, env:, branch:, args:)
    bindings = { app: app, env: env, branch: branch }
    (args || {}).each { |k, v| bindings[k.to_sym] = v.to_s }
    format(template, **bindings)
  rescue KeyError => e
    raise InvalidConfig, "unknown placeholder in task template: #{e.message}"
  end
end
