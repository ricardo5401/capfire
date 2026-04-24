# frozen_string_literal: true

require 'pty'
require 'open3'
require 'shellwords'

# Runs a deploy-style command inside an app's working directory and yields
# output line-by-line.
#
# Previously named `CapistranoRunner` and hardcoded to Capistrano argv. It is
# now a generic shell runner: the command to execute is resolved through
# `AppConfig` (which reads `capfire.yml`), falling back to the Capistrano
# defaults when no custom config is present. This unlocks non-Rails and
# non-Capistrano apps without any change to the runner itself.
#
# A PTY is preferred so tools like `cap` produce colored, unbuffered output
# identical to interactive usage. If PTY is unavailable (unlikely on Linux
# but possible in minimal containers without /dev/ptmx), we fall back to
# Open3 with line-buffered pipes.
#
# Every spawned command runs inside `Bundler.with_unbundled_env` because
# Capfire itself is a bundled Rails app: its process environment carries
# `BUNDLE_GEMFILE`, `RUBYOPT=-rbundler/setup`, `BUNDLE_PATH`, etc. pointing
# to Capfire's own bundle. Without the unbundled wrapper, `bundle install`
# and `bundle exec` in a child app's cockpit resolve to Capfire's Gemfile
# and install gems into Capfire's vendor/bundle — classic bundler leak.
class CommandRunner
  class Error < StandardError; end
  class AppNotFound < Error; end

  attr_reader :app, :env, :branch, :command, :work_dir

  def initialize(app:, env:, branch: 'main', command: 'deploy', app_config: nil)
    @app = app
    @env = env
    @branch = branch
    @command = command
    @app_config = app_config || AppConfig.new(app: app)
    @work_dir = @app_config.work_dir
  end

  # Yields each raw line (without trailing newline) and returns the process exit code.
  def run(&block)
    ensure_work_dir!
    command_string = build_full_command

    Rails.logger.info("[runner] cd #{work_dir} && #{command_string}")

    # Strip Capfire's bundler env before spawning so the child app resolves
    # its own Gemfile/bundle path. See class-level comment for context.
    Bundler.with_unbundled_env do
      run_with_pty(command_string, &block)
    end
  rescue PTY::ChildExited => e
    e.status.exitstatus || 1
  end

  private

  def ensure_work_dir!
    return if File.directory?(work_dir)

    raise AppNotFound, "working directory not found for app=#{app}: #{work_dir}"
  end

  # Builds the final shell command to run, prepending (for `deploy` only):
  #   1. Git sync: `fetch + checkout + reset --hard` against `origin/<branch>`.
  #      Opt out via `git_sync: false` in capfire.yml.
  #   2. Pre-deploy hooks: shell commands from `pre_deploy:` in capfire.yml,
  #      chained with `&&`. Typical uses: `bundle install`, `yarn install`.
  #
  # Restart/rollback/status skip both steps — they don't need fresh code or
  # refreshed dependencies.
  def build_full_command
    base = @app_config.command_for(command: command, env: env, branch: branch)
    return base unless command == 'deploy'

    steps = []
    steps << git_sync_command if @app_config.git_sync?
    steps.concat(@app_config.pre_deploy_commands)
    steps << base
    steps.join(' && ')
  end

  def git_sync_command
    ref = branch.to_s.shellescape
    [
      'git fetch --prune origin',
      "git checkout #{ref}",
      "git reset --hard origin/#{ref}"
    ].join(' && ')
  end

  # Uses `sh -c` so custom `capfire.yml` commands can include pipes, env vars,
  # chained commands, or call arbitrary scripts transparently.
  def run_with_pty(command_string, &block)
    PTY.spawn({ 'TERM' => 'xterm-256color' }, 'sh', '-c', command_string, chdir: work_dir) do |reader, _writer, pid|
      reader.each_line { |line| block&.call(line.chomp) }
    rescue Errno::EIO
      # Expected when the child closes the PTY — stop reading.
    ensure
      _, status = safe_wait(pid)
      # Returning from ensure is intentional here: PTY.spawn has no other way
      # to surface the final exit status back to the caller.
      return status ? (status.exitstatus || 1) : 1 # rubocop:disable Lint/EnsureReturn
    end
  rescue NotImplementedError, Errno::ENOENT
    run_with_open3(command_string, &block)
  end

  def run_with_open3(command_string, &block)
    exit_code = 1
    Open3.popen2e('sh', '-c', command_string, chdir: work_dir) do |_stdin, stdout_err, wait_thr|
      stdout_err.each_line { |line| block&.call(line.chomp) }
      exit_code = wait_thr.value.exitstatus || 1
    end
    exit_code
  end

  def safe_wait(pid)
    Process.wait2(pid)
  rescue Errno::ECHILD
    [nil, nil]
  end
end
