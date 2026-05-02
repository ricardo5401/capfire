# frozen_string_literal: true

require 'rails_helper'

# AbortService is the heart of the kill-and-cancel feature. These specs
# exercise the four real-world cases:
#
#   1. Active record with a live PID — process group gets SIGTERM and dies
#      cleanly; record transitions to canceled with exit_code=143.
#   2. Active record with a stubborn PID that ignores SIGTERM — service
#      escalates to SIGKILL after the grace period; exit_code=137.
#   3. Active record without a PID (orphan from a Puma restart) — no
#      signaling, just a clean DB transition with exit_code=-1.
#   4. Already-finished record — no-op, returns :already_finished.
#
# We never spawn a real shell here. Process.kill is stubbed at the module
# level so the specs run in milliseconds and don't risk killing whatever
# happens to live on a recycled PID on the test host.
RSpec.describe AbortService do
  let(:fake_pid) { 99_999 }
  let(:requested_by) { 'spec-user' }
  let(:reason) { 'because' }

  let(:deploy) do
    Deploy.create!(
      app: 'pyworker', env: 'production', branch: 'master',
      command: 'deploy', status: 'running',
      pid: fake_pid, started_at: 1.minute.ago,
      triggered_by: 'someone'
    )
  end

  let(:task_run) do
    TaskRun.create!(
      app: 'pyworker', env: 'production', branch: 'master',
      task_name: 'reindex', status: 'running',
      pid: fake_pid, started_at: 1.minute.ago,
      triggered_by: 'someone'
    )
  end

  describe 'happy path: SIGTERM clears the process within the grace period' do
    before do
      # First Process.kill('-TERM', pid) succeeds.
      allow(Process).to receive(:kill).with('-TERM', fake_pid).and_return(1)
      # The wait_for_exit poll: kill(0, pid) raises ESRCH almost immediately.
      allow(Process).to receive(:kill).with(0, fake_pid).and_raise(Errno::ESRCH)
    end

    it 'transitions the deploy to canceled with exit_code=143' do
      result = described_class.new(record: deploy, requested_by: requested_by, reason: reason).call

      expect(result.status).to eq(:canceled)
      expect(result.exit_code).to eq(AbortService::SIGTERM_EXIT)

      deploy.reload
      expect(deploy.status).to eq('canceled')
      expect(deploy.exit_code).to eq(143)
      expect(deploy.finished_at).to be_present
    end

    it 'appends an audit log line with actor + reason' do
      described_class.new(record: deploy, requested_by: requested_by, reason: reason).call
      expect(deploy.reload.log).to include('aborted by spec-user').and include('because')
    end

    it 'works the same way for a TaskRun' do
      result = described_class.new(record: task_run, requested_by: requested_by).call

      expect(result.status).to eq(:canceled)
      expect(result.exit_code).to eq(AbortService::SIGTERM_EXIT)
      expect(task_run.reload.status).to eq('canceled')
    end
  end

  describe 'escalation: SIGTERM is ignored, falls through to SIGKILL' do
    before do
      # SIGTERM goes through, but the wait_for_exit poll never sees the
      # process die — kill(0, pid) keeps succeeding for the entire grace
      # window. We shrink the grace to keep the spec fast.
      allow(Process).to receive(:kill).with('-TERM', fake_pid).and_return(1)
      allow(Process).to receive(:kill).with(0, fake_pid).and_return(1)
      allow(Process).to receive(:kill).with('-KILL', fake_pid).and_return(1)
    end

    it 'records exit_code=137 (SIGKILL) when SIGTERM did not work in time' do
      result = described_class.new(
        record: deploy, requested_by: requested_by, grace_seconds: 0.05
      ).call

      expect(result.exit_code).to eq(AbortService::SIGKILL_EXIT)
      expect(deploy.reload.exit_code).to eq(137)
      expect(Process).to have_received(:kill).with('-KILL', fake_pid)
    end
  end

  describe 'orphan lock: record has no PID' do
    let(:deploy_without_pid) do
      Deploy.create!(
        app: 'other-app', env: 'production', branch: 'master',
        command: 'deploy', status: 'running',
        pid: nil, started_at: 1.minute.ago,
        triggered_by: 'someone'
      )
    end

    it 'transitions to canceled with exit_code=-1 and never calls Process.kill' do
      allow(Process).to receive(:kill)

      result = described_class.new(record: deploy_without_pid, requested_by: requested_by).call

      expect(result.exit_code).to eq(AbortService::NO_PROCESS_EXIT)
      expect(deploy_without_pid.reload.status).to eq('canceled')
      expect(Process).not_to have_received(:kill)
    end
  end

  describe 'already-finished records' do
    let(:finished_deploy) do
      Deploy.create!(
        app: 'finished-app', env: 'production', branch: 'master',
        command: 'deploy', status: 'success',
        exit_code: 0, started_at: 2.minutes.ago, finished_at: 1.minute.ago,
        triggered_by: 'someone'
      )
    end

    it 'returns :already_finished without touching the record or signaling' do
      allow(Process).to receive(:kill)

      result = described_class.new(record: finished_deploy, requested_by: requested_by).call

      expect(result.status).to eq(:already_finished)
      expect(result.exit_code).to be_nil
      expect(finished_deploy.reload.status).to eq('success')
      expect(Process).not_to have_received(:kill)
    end
  end

  describe 'process already dead by the time we signal' do
    before do
      # Simulates the very tight race where the process exited between the
      # caller's "abort this" and our first kill(). ESRCH on the first
      # attempt is a clean exit, not an escalation trigger.
      allow(Process).to receive(:kill).with('-TERM', fake_pid).and_raise(Errno::ESRCH)
    end

    it 'records exit_code=143 (clean) without ever escalating to SIGKILL' do
      result = described_class.new(record: deploy, requested_by: requested_by).call

      expect(result.exit_code).to eq(AbortService::SIGTERM_EXIT)
      expect(Process).not_to have_received(:kill).with('-KILL', fake_pid)
    end
  end

  describe 'mark_finished! guard against overwriting canceled' do
    # The runner thread might call mark_finished! a few ms after we
    # transitioned to canceled. The guard added on Deploy and TaskRun
    # should prevent that from flipping us back to `failed`.
    it 'keeps the record canceled even if mark_finished! is called afterwards' do
      allow(Process).to receive(:kill).with('-TERM', fake_pid).and_return(1)
      allow(Process).to receive(:kill).with(0, fake_pid).and_raise(Errno::ESRCH)

      described_class.new(record: deploy, requested_by: requested_by).call
      expect(deploy.reload.status).to eq('canceled')

      # Simulate the runner finishing late with a non-zero exit code.
      deploy.mark_finished!(exit_code: 1)

      expect(deploy.reload.status).to eq('canceled')
      expect(deploy.reload.exit_code).to eq(143)
    end
  end
end
