# Orchestrates a full Capfire deploy lifecycle and streams output via a block.
#
# Lifecycle:
#   1. Create Deploy record (status=pending).
#   2. If env=production, drain the node from Cloudflare LB.
#   3. Mark deploy running, spawn Capistrano via CapistranoRunner.
#   4. Append each output line to the Deploy log and yield it to the caller.
#   5. Restore Cloudflare LB (always — even on failure) if it was drained.
#   6. Mark deploy success/failed and yield a terminal `:done` event.
#
# The block receives (event_name, payload_hash) where event_name is one of:
#   :log, :info, :error, :done
class DeployService
  PRODUCTION_ENVS = %w[production prod].freeze

  attr_reader :deploy

  def initialize(app:, env:, branch:, command: 'deploy', triggered_by: nil, token_jti: nil,
                 lb_service: CloudflareLbService.new, runner_class: CapistranoRunner,
                 logger: Rails.logger)
    @app = app
    @env = env
    @branch = branch
    @command = command
    @triggered_by = triggered_by
    @token_jti = token_jti
    @lb_service = lb_service
    @runner_class = runner_class
    @logger = logger
  end

  def call(&block)
    @block = block
    @deploy = Deploy.create!(
      app: @app,
      env: @env,
      branch: @branch,
      command: @command,
      status: 'pending',
      triggered_by: @triggered_by,
      token_jti: @token_jti
    )

    emit(:info, deploy_id: @deploy.id, app: @app, env: @env, branch: @branch, command: @command,
                message: "starting #{@command} #{@app}@#{@branch} -> #{@env}")

    drained = drain_if_needed
    exit_code = execute_runner
    restore_if_drained(drained)

    @deploy.mark_finished!(exit_code: exit_code)
    emit(:done, deploy_id: @deploy.id, exit_code: exit_code, status: @deploy.status)
    @deploy
  rescue StandardError => e
    @logger.error("[deploy] #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    emit(:error, message: "#{e.class}: #{e.message}")
    restore_if_drained(true) if @drained
    finalize_on_error(e)
    @deploy
  end

  private

  def drain_if_needed
    return false unless production? && should_manage_lb?

    emit(:info, message: 'draining node from Cloudflare LB')
    @drained = @lb_service.drain!
  rescue CloudflareLbService::Error => e
    emit(:error, message: "cloudflare drain failed: #{e.message}")
    raise
  end

  def restore_if_drained(drained)
    return unless drained

    @lb_service.restore!
    emit(:info, message: 'node restored to Cloudflare LB')
  rescue CloudflareLbService::Error => e
    # Log but don't re-raise — the deploy itself may have succeeded.
    emit(:error, message: "cloudflare restore failed: #{e.message}")
    @logger.error("[deploy] cloudflare restore failed: #{e.message}")
  end

  def execute_runner
    runner = @runner_class.new(app: @app, env: @env, branch: @branch, command: @command)
    @deploy.mark_running!

    runner.run do |line|
      @deploy.append_log!("#{line}\n")
      emit(:log, line: line)
    end
  rescue CapistranoRunner::Error => e
    emit(:error, message: e.message)
    1
  end

  def finalize_on_error(error)
    return unless @deploy

    @deploy.update!(status: 'failed', exit_code: @deploy.exit_code || 1, finished_at: Time.current)
    emit(:done, deploy_id: @deploy.id, exit_code: @deploy.exit_code, status: 'failed', error: error.message)
  end

  def production?
    PRODUCTION_ENVS.include?(@env.to_s.downcase)
  end

  def should_manage_lb?
    @command == 'deploy' && @lb_service.configured?
  end

  def emit(event, payload)
    @block&.call(event, payload)
  end
end
