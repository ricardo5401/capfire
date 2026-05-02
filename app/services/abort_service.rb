# frozen_string_literal: true

# Aborts a running Deploy or TaskRun: signals its process group, transitions
# the record to `canceled`, and records why.
#
# Why a single service for both kinds:
#   The Deploy and TaskRun models have identical surface area for this
#   operation — same active states, same `pid`, same `append_log!`/finished
#   transitions. Duplicating the kill logic across two services would mean
#   two places to keep consistent the next time we tweak grace periods or
#   exit-code conventions.
#
# Lifecycle (in order):
#
#   1. Validate the record is in an active state. If it's already
#      success/failed/canceled we return :already_finished — the caller
#      converts that into a benign 200 with the existing payload (idempotent
#      from the user's POV, no error).
#
#   2. If the record carries a PID, signal the whole PROCESS GROUP. We use
#      a negative PID with `Process.kill` because `sh -c` spawns descendants
#      (cap, ssh, ruby, the deploy script's own children, ...). Signalling
#      only the leader leaves orphans behind that keep holding the work_dir
#      open and may finish the deploy AFTER we marked it canceled.
#
#      Sequence: SIGTERM -> wait `grace_seconds` (default 10s) -> SIGKILL
#      if still alive. Each kill exits early when the process is already
#      gone (Errno::ESRCH).
#
#   3. Transition the record to `canceled` with an `exit_code` that
#      preserves forensic info:
#        - 143 (= 128 + SIGTERM)  -> died on SIGTERM cleanly
#        - 137 (= 128 + SIGKILL)  -> only died after we escalated
#        -  -1                    -> no PID was ever recorded (orphan lock
#                                    from a Puma restart, or aborted while
#                                    still in `pending` before spawn)
#
#   4. Append a footer line to the log so anyone reading it later sees who
#      pulled the plug and when. The CommandRunner stream is gone by this
#      point, so we write directly via `append_log!`.
#
# Concurrency note:
#   The DeployService thread will eventually try to `mark_finished!` the
#   record after the kill — that update would overwrite our `canceled`
#   status with `failed`. We accept this race as a no-op because:
#     - `mark_finished!` reads `exit_code.zero?` and the killed process
#       returns non-zero, so it would land on `failed` regardless.
#     - The race window is the time between SIGKILL and the runner thread
#       observing the dead PID — typically milliseconds.
#   To avoid the overwrite anyway, mark_finished checks the current status
#   in the DB; see Deploy#mark_finished! / TaskRun#mark_finished! (the
#   guard is added together with this service).
class AbortService
  # Raised when caller asks to abort something that doesn't exist.
  class NotFound < StandardError; end

  # SIGTERM: 15. Linux returns 128 + signal number as the exit code when a
  # process dies on a signal — preserving these exact values in the DB
  # gives us "why was this aborted" information without a separate column.
  SIGTERM_EXIT = 143
  SIGKILL_EXIT = 137
  NO_PROCESS_EXIT = -1

  DEFAULT_GRACE_SECONDS = 10
  POLL_INTERVAL_SECONDS = 0.5

  Result = Struct.new(:status, :exit_code, :record, keyword_init: true) do
    def to_h
      { status: status, exit_code: exit_code, record: record }
    end
  end

  def initialize(record:, requested_by: nil, reason: nil,
                 grace_seconds: DEFAULT_GRACE_SECONDS, logger: Rails.logger)
    @record = record
    @requested_by = requested_by
    @reason = reason
    @grace_seconds = grace_seconds
    @logger = logger
  end

  # Returns a Result whose `status` is one of:
  #   :already_finished -> no-op, the record was already terminal
  #   :canceled         -> we transitioned the record to canceled (with
  #                        whatever exit_code best describes how)
  def call
    return result(:already_finished) unless active?

    exit_code = kill_process_group
    transition_to_canceled!(exit_code)
    append_audit_log!(exit_code)

    @logger.info(
      "[abort] #{kind}=#{@record.id} app=#{@record.app} " \
      "exit=#{exit_code} requested_by=#{@requested_by || 'system'}"
    )

    result(:canceled, exit_code)
  end

  private

  def active?
    @record.class::ACTIVE_STATUSES.include?(@record.status)
  end

  # Returns the exit code we want to persist:
  #   - SIGTERM_EXIT if the process died within the grace period
  #   - SIGKILL_EXIT if we had to escalate
  #   - NO_PROCESS_EXIT if there's no PID to signal (orphan lock)
  #
  # ESRCH on the very first kill means the process is already dead; we
  # treat it as a clean SIGTERM exit so the user doesn't see a confusing
  # 137 just because Puma restarted right before they aborted.
  def kill_process_group
    pid = @record.pid
    return NO_PROCESS_EXIT if pid.blank? || pid.zero?

    return SIGTERM_EXIT unless signal_group(pid, 'TERM')
    return SIGTERM_EXIT if wait_for_exit(pid, @grace_seconds)

    @logger.warn("[abort] pid=#{pid} survived SIGTERM after #{@grace_seconds}s — escalating to SIGKILL")
    signal_group(pid, 'KILL')
    SIGKILL_EXIT
  rescue StandardError => e
    # Catch-all so a kill failure NEVER leaves the record stuck in running.
    # We log loudly and keep going to the DB transition — the user's intent
    # was "stop this run", and the DB part of that intent we can always
    # honor even if the OS side misbehaved.
    @logger.error("[abort] kill failed for #{kind}=#{@record.id}: #{e.class}: #{e.message}")
    NO_PROCESS_EXIT
  end

  # Returns true when the signal was delivered, false when the process was
  # already gone. Errno::EPERM (no permission to signal) bubbles up — that's
  # a setup bug worth surfacing, not silently swallowing.
  #
  # The leading `-` on the PID makes this a process-group signal: SIGTERM
  # to every descendant of the original `sh -c`. Without this, `cap` and
  # its `ssh` children survive the shell and finish the deploy behind our
  # back. PTY.spawn and our Open3 fallback (with `pgroup: true`) both make
  # the spawned child the group leader, so `pid == pgid`.
  def signal_group(pid, signal)
    Process.kill("-#{signal}", pid)
    true
  rescue Errno::ESRCH
    false
  end

  # Polls Process.kill(0, pid) until it raises ESRCH (process gone) or the
  # deadline elapses. Cheaper than `waitpid` and works regardless of
  # whether we're the parent (we usually aren't — the runner thread is).
  def wait_for_exit(pid, seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      begin
        Process.kill(0, pid)
        sleep POLL_INTERVAL_SECONDS
      rescue Errno::ESRCH
        return true
      end
    end
    false
  end

  # Marks the record canceled in a single UPDATE so the runner thread that
  # would otherwise call `mark_finished!` finds a non-active row and
  # bails out (see the guard added in Deploy#mark_finished!).
  def transition_to_canceled!(exit_code)
    @record.update!(
      status: 'canceled',
      exit_code: exit_code,
      finished_at: Time.current
    )
  end

  def append_audit_log!(exit_code)
    actor = @requested_by.presence || 'system'
    suffix = @reason.presence ? " — #{@reason}" : ''
    @record.append_log!(
      "\n[capfire] aborted by #{actor} at #{Time.current.utc.iso8601} " \
      "(exit=#{exit_code})#{suffix}\n"
    )
  end

  def result(status, exit_code = nil)
    Result.new(status: status, exit_code: exit_code, record: @record)
  end

  # 'deploy' or 'task' — used for log lines so grep'ing the journal stays
  # readable when both kinds of abort fly by.
  def kind
    @record.is_a?(TaskRun) ? 'task' : 'deploy'
  end
end
