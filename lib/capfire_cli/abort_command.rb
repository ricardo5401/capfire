# frozen_string_literal: true

module CapfireCli
  # `bin/capfire abort deploy|task ID` — server-side admin abort.
  #
  # Bypasses JWT entirely (this runs as the system user with DB access)
  # and goes straight to AbortService. The intended use case is operator
  # recovery: someone's deploy got stuck, the JWT-authenticated client
  # path can't reach the server, or no token holder with `cmd: abort` is
  # available — the local admin opens an SSH session and pulls the plug.
  #
  # Why not reuse the HTTP path: an admin sitting on the box should NOT
  # need a working JWT to recover from a hung process. If the auth layer
  # is part of the problem, this CLI keeps working.
  class AbortCommand < Thor
    package_name 'capfire abort'

    desc 'deploy DEPLOY_ID', 'Cancel a running deploy (admin, no JWT)'
    long_desc <<~DESC
      Signals the deploy's process group (SIGTERM, then SIGKILL after a 10s
      grace period) and transitions the row to `canceled`. Idempotent:
      aborting an already-finished deploy is a no-op.

      Use this when:
        - a deploy is hung and there's no token holder with `cmd: abort`,
        - Puma was restarted and a row is stuck in `running` with a dead
          PID (orphan lock — releases the lock so new deploys can run),
        - the JWT auth layer itself is the problem.

      Examples:
        bin/capfire abort deploy 42
        bin/capfire abort deploy 42 --reason "deployed wrong branch"
    DESC
    method_option :reason, type: :string, required: false,
                           desc: 'Optional reason; appended to the audit log line'
    def deploy(id)
      record = ::Deploy.find_by(id: id)
      abort_record(record, kind: 'deploy', id: id)
    end

    desc 'task TASK_RUN_ID', 'Cancel a running task (admin, no JWT)'
    long_desc <<~DESC
      Same protocol as `abort deploy`, applied to a TaskRun. Useful for
      stuck Python workers, hung backfills, or any task with a dead PID
      blocking the per-app task lock.

      Examples:
        bin/capfire abort task 87
        bin/capfire abort task 87 --reason "wrong since= argument"
    DESC
    method_option :reason, type: :string, required: false,
                           desc: 'Optional reason; appended to the audit log line'
    def task(id)
      record = ::TaskRun.find_by(id: id)
      abort_record(record, kind: 'task', id: id)
    end

    private

    # Common dispatch — find the record (or fail loudly), call AbortService
    # with `system` as the actor, and pretty-print the outcome. Exits with
    # status 1 on not-found so scripts can detect the case.
    def abort_record(record, kind:, id:)
      if record.nil?
        say_status('error', "no #{kind} found with id=#{id}", :red)
        exit(1)
      end

      result = ::AbortService.new(
        record: record,
        requested_by: 'admin-cli',
        reason: options[:reason]
      ).call

      print_result(result, kind: kind)
    end

    def print_result(result, kind:)
      label = kind.capitalize
      record = result.record

      case result.status
      when :canceled
        say_status('canceled', "#{label} ##{record.id} aborted (#{record.app}/#{record.env})", :green)
      when :already_finished
        say_status('skip', "#{label} ##{record.id} was already #{record.status}", :yellow)
      else
        say_status('info', "#{label} ##{record.id} status=#{record.status}", :white)
      end

      return unless result.exit_code

      say "  exit code: #{result.exit_code} #{exit_code_note(result.exit_code)}"
    end

    # Translates AbortService's exit-code convention to a human note. Same
    # legend the Go client prints — keeps the operator experience uniform
    # whether they ran the abort over HTTP or locally.
    def exit_code_note(code)
      case code
      when ::AbortService::SIGTERM_EXIT
        '(SIGTERM — process exited cleanly within grace period)'
      when ::AbortService::SIGKILL_EXIT
        '(SIGKILL — had to force-kill after grace period)'
      when ::AbortService::NO_PROCESS_EXIT
        '(no live process — orphan lock cleared)'
      else
        ''
      end
    end
  end
end
