require 'pty'
require 'open3'
require 'shellwords'

# Runs a Capistrano command inside an app's working directory and yields
# output line-by-line.
#
# A PTY is preferred so tools like `cap` produce colored, unbuffered output
# identical to interactive usage. If PTY is unavailable (unlikely on Linux
# but possible in containers without /dev/ptmx), we fall back to Open3 with
# line-buffered pipes.
class CapistranoRunner
  class Error < StandardError; end
  class AppNotFound < Error; end

  COMMAND_TEMPLATES = {
    'deploy'   => ->(env, branch) { ['bundle', 'exec', 'cap', env, 'deploy', "BRANCH=#{branch}"] },
    'rollback' => ->(env, _branch) { ['bundle', 'exec', 'cap', env, 'deploy:rollback'] },
    'restart'  => ->(env, _branch) { ['bundle', 'exec', 'cap', env, 'deploy:restart'] },
    'status'   => ->(env, _branch) { ['bundle', 'exec', 'cap', env, 'deploy:check'] }
  }.freeze

  attr_reader :app, :env, :branch, :command, :work_dir

  def initialize(app:, env:, branch: 'main', command: 'deploy', work_dir: nil)
    @app = app
    @env = env
    @branch = branch
    @command = command
    @work_dir = work_dir || resolve_work_dir(app)
  end

  # Yields each raw line (without trailing newline) and returns the process exit code.
  def run
    argv = build_argv
    ensure_work_dir!

    Rails.logger.info("[capistrano] cd #{work_dir} && #{argv.shelljoin}")

    exit_status = run_with_pty(argv) do |line|
      yield line if block_given?
    end
    exit_status
  rescue PTY::ChildExited => e
    e.status.exitstatus || 1
  end

  private

  def build_argv
    template = COMMAND_TEMPLATES.fetch(command) do
      raise ArgumentError, "unknown capistrano command: #{command}"
    end
    template.call(env, branch)
  end

  def ensure_work_dir!
    return if File.directory?(work_dir)

    raise AppNotFound, "working directory not found for app=#{app}: #{work_dir}"
  end

  def resolve_work_dir(app)
    slug = app.upcase.gsub(/[^A-Z0-9]+/, '_')
    override = ENV["CAPFIRE_APP_DIR_#{slug}"]
    return override if override.present?

    File.join(Capfire.config.apps_root, app)
  end

  def run_with_pty(argv)
    PTY.spawn({ 'TERM' => 'xterm-256color' }, *argv, chdir: work_dir) do |reader, _writer, pid|
      begin
        reader.each_line do |line|
          yield line.chomp
        end
      rescue Errno::EIO
        # Expected when the child process closes the PTY.
      ensure
        _, status = Process.wait2(pid) rescue [nil, nil]
        return status ? (status.exitstatus || 1) : 1
      end
    end
  rescue NotImplementedError, Errno::ENOENT
    run_with_open3(argv) { |line| yield line }
  end

  def run_with_open3(argv)
    exit_code = 1
    Open3.popen2e(*argv, chdir: work_dir) do |_stdin, stdout_err, wait_thr|
      stdout_err.each_line do |line|
        yield line.chomp
      end
      exit_code = wait_thr.value.exitstatus || 1
    end
    exit_code
  end
end
