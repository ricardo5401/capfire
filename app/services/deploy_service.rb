# frozen_string_literal: true

# Orchestrates a full Capfire deploy lifecycle and streams output via a block.
#
# Lifecycle:
#   1. Create Deploy record (status=pending).
#   2. If LB is configured for this app+env (via capfire.yml), drain the node.
#   3. Mark deploy running, spawn the command via CommandRunner.
#   4. Append each output line to the Deploy log and yield it to the caller.
#   5. Restore the LB (always — even on failure) if it was drained.
#   6. Mark deploy success/failed and yield a terminal `:done` event.
#
# Whether LB is touched is now driven entirely by per-app `capfire.yml`
# (see AppConfig#load_balancer_for). `PRODUCTION_ENVS` is gone — a staging env
# can drain if its yaml says so, and a production env can skip drain if it
# doesn't. This keeps Capfire honest for nodes that host multiple apps with
# different topologies.
#
# The block receives (event_name, payload_hash) where event_name is one of:
#   :log, :info, :error, :done
class DeployService
  attr_reader :deploy

  def initialize(app:, env:, branch:, command: 'deploy', triggered_by: nil, token_jti: nil,
                 skip_lb: false, app_config: nil, runner_class: CommandRunner,
                 lb_service_class: CloudflareLbService, notifier_class: SlackNotifier,
                 logger: Rails.logger)
    @app = app
    @env = env
    @branch = branch
    @command = command
    @triggered_by = triggered_by
    @token_jti = token_jti
    @skip_lb = skip_lb
    @app_config = app_config || AppConfig.new(app: app)
    @runner_class = runner_class
    @lb_service_class = lb_service_class
    @notifier_class = notifier_class
    @logger = logger
    @lb_config = @app_config.load_balancer_for(env)
    @lb_service = @lb_service_class.new(config: @lb_config)
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
    notify_slack(success: exit_code.zero?, reason: exit_code.zero? ? nil : "exit code #{exit_code}")
    @deploy
  rescue StandardError => e
    @logger.error("[deploy] #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    emit(:error, message: "#{e.class}: #{e.message}")
    restore_if_drained(true) if @drained
    finalize_on_error(e)
    notify_slack(success: false, reason: "#{e.class}: #{e.message}")
    @deploy
  end

  private

  def drain_if_needed
    return false unless should_manage_lb?

    emit(:info, message: "draining origin=#{@lb_config.origin} from Cloudflare LB")
    @drained = @lb_service.drain!
  rescue CloudflareLbService::Error => e
    emit(:error, message: "cloudflare drain failed: #{e.message}")
    raise
  end

  def restore_if_drained(drained)
    return unless drained

    @lb_service.restore!
    emit(:info, message: "restored origin=#{@lb_config.origin} to Cloudflare LB")
  rescue CloudflareLbService::Error => e
    # Log but don't re-raise — the deploy itself may have succeeded.
    emit(:error, message: "cloudflare restore failed: #{e.message}")
    @logger.error("[deploy] cloudflare restore failed: #{e.message}")
  end

  def execute_runner
    runner = @runner_class.new(
      app: @app, env: @env, branch: @branch, command: @command, app_config: @app_config
    )
    @deploy.mark_running!

    runner.run do |line|
      @deploy.append_log!("#{line}\n")
      emit(:log, line: line)
    end
  rescue CommandRunner::Error => e
    emit(:error, message: e.message)
    1
  end

  def finalize_on_error(error)
    return unless @deploy

    @deploy.update!(status: 'failed', exit_code: @deploy.exit_code || 1, finished_at: Time.current)
    emit(:done, deploy_id: @deploy.id, exit_code: @deploy.exit_code, status: 'failed', error: error.message)
  end

  # LB is managed only when:
  #   - the caller didn't request skip_lb,
  #   - AND the command is a 'deploy' (restart/rollback/status don't drain),
  #   - AND the app+env has a load_balancer block in capfire.yml,
  #   - AND that block is complete enough to hit the Cloudflare API.
  def should_manage_lb?
    return false if @skip_lb
    return false unless @command == 'deploy'
    return false if @lb_config.nil?

    @lb_service.configured?
  end

  # Posts a Slack notification. No-op unless the command is `deploy` AND the
  # app has `slack.enabled: true` in its capfire.yml AND the webhook URL is
  # configured via ENV.
  def notify_slack(success:, reason: nil)
    return unless @command == 'deploy'
    return unless @app_config.slack_enabled?

    notifier = @notifier_class.new(webhook_env: @app_config.slack_webhook_env, logger: @logger)
    return unless notifier.configured?

    link = @app_config.link_for(@env)
    if success
      notifier.notify_success(app: @app, env: @env, branch: @branch, author: @triggered_by, link: link)
    else
      notifier.notify_failure(
        app: @app, env: @env, branch: @branch, author: @triggered_by, reason: reason, link: link
      )
    end
  end

  def emit(event, payload)
    @block&.call(event, payload)
  end
end
