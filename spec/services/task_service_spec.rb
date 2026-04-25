# frozen_string_literal: true

require 'rails_helper'

# Service spec stubs CommandRunner so we never spawn a real PTY. Tests
# exercise lifecycle, persistence, busy detection, and the sync-vs-deploy
# cross-check — the actual shell semantics are covered by AppConfig specs.
RSpec.describe TaskService do
  let(:app)    { 'pyworker' }
  let(:env)    { 'production' }
  let(:branch) { 'master' }

  # A faux runner that records what it was given and yields fake output.
  # We intentionally keep it as a struct of-doubles instead of a `class
  # double` because CommandRunner accepts a long kwargs list whose schema
  # is verified separately in command_runner_spec (when added).
  let(:fake_runner_class) do
    Class.new do
      attr_reader :captured_kwargs

      def self.last
        @last
      end

      def self.reset!
        @last = nil
      end

      def initialize(**kwargs)
        @captured_kwargs = kwargs
        self.class.instance_variable_set(:@last, self)
      end

      def run
        yield 'line 1'
        yield 'line 2'
        0
      end
    end
  end

  let(:app_config) do
    instance_double(
      AppConfig,
      task_for: 'echo running',
      work_dir: '/tmp/pyworker'
    )
  end

  before { fake_runner_class.reset! }

  def build_service(**overrides)
    described_class.new(
      app: app, env: env, task_name: 'reindex', branch: branch,
      args: { 'since' => '2024-01-01' },
      triggered_by: 'spec-user',
      token_jti: 'jti-1',
      app_config: app_config,
      runner_class: fake_runner_class,
      **overrides
    )
  end

  describe '#call (happy path)' do
    it 'creates a TaskRun, marks it running, persists log, and finishes success' do
      events = []
      service = build_service
      service.call { |event, payload| events << [ event, payload ] }

      task_run = service.task_run
      expect(task_run).to be_present
      expect(task_run.status).to eq('success')
      expect(task_run.exit_code).to eq(0)
      expect(task_run.log).to include('line 1', 'line 2')
      expect(task_run.task_name).to eq('reindex')
      expect(task_run.args).to eq('since' => '2024-01-01')
      expect(task_run.triggered_by).to eq('spec-user')

      expect(events.map(&:first)).to include(:info, :log, :done)
      done_event = events.last
      expect(done_event[0]).to eq(:done)
      expect(done_event[1][:exit_code]).to eq(0)
      expect(done_event[1][:status]).to eq('success')
    end

    it 'feeds the resolved command_string into the runner' do
      build_service.call

      expect(fake_runner_class.last.captured_kwargs[:command_string]).to eq('echo running')
      expect(fake_runner_class.last.captured_kwargs[:command]).to eq('reindex')
      expect(fake_runner_class.last.captured_kwargs[:branch]).to eq(branch)
    end
  end

  describe '#call when the runner returns non-zero' do
    let(:failing_runner_class) do
      Class.new do
        def initialize(**); end

        def run
          yield 'something broke'
          7
        end
      end
    end

    it 'persists status=failed and surfaces the exit code via :done' do
      events = []
      service = build_service(runner_class: failing_runner_class)
      service.call { |event, payload| events << [ event, payload ] }

      expect(service.task_run.status).to eq('failed')
      expect(service.task_run.exit_code).to eq(7)
      done_event = events.find { |e, _| e == :done }
      expect(done_event[1][:exit_code]).to eq(7)
      expect(done_event[1][:status]).to eq('failed')
    end
  end

  describe '#call when AppConfig raises (e.g. params validation)' do
    before do
      allow(app_config).to receive(:task_for)
        .and_raise(AppConfig::InvalidConfig, 'task `backfill`: missing params: since')
    end

    it 'marks the task_run as failed and emits :error + :done' do
      events = []
      service = build_service
      service.call { |event, payload| events << [ event, payload ] }

      expect(service.task_run.status).to eq('failed')
      expect(service.task_run.exit_code).to eq(1)
      expect(events.map(&:first)).to include(:error, :done)
    end
  end

  describe 'concurrency: per-app task lock' do
    it 'raises Busy when another task is already active for the same app' do
      blocker = TaskRun.create!(
        app: app, env: env, task_name: 'backfill',
        branch: 'master', status: 'running',
        triggered_by: 'other-user'
      )

      expect { build_service.enqueue }.to raise_error(TaskService::Busy) do |err|
        expect(err.active_task_run.id).to eq(blocker.id)
      end
    end

    it 'propagates Busy through #call too' do
      TaskRun.create!(
        app: app, env: env, task_name: 'backfill',
        branch: 'master', status: 'running'
      )

      expect { build_service.call { |_, _| } }.to raise_error(TaskService::Busy)
    end

    it 'allows tasks on different apps to run concurrently' do
      TaskRun.create!(
        app: 'other-app', env: env, task_name: 'backfill',
        branch: 'master', status: 'running'
      )

      service = build_service
      expect { service.call { |_, _| } }.not_to raise_error
      expect(service.task_run.status).to eq('success')
    end
  end

  describe 'concurrency: sync vs deploy cross-check' do
    let(:active_deploy) do
      Deploy.create!(
        app: app, env: env, branch: 'master',
        command: 'deploy', status: 'running',
        triggered_by: 'someone'
      )
    end

    it 'raises DeployInFlight when a deploy is running and the task is `sync`' do
      active_deploy # touch to insert
      service = build_service(task_name: 'sync')

      expect { service.enqueue }.to raise_error(TaskService::DeployInFlight) do |err|
        expect(err.active_deploy.id).to eq(active_deploy.id)
      end
    end

    it 'does NOT raise DeployInFlight for non-sync tasks (intentional non-blocking)' do
      active_deploy
      service = build_service(task_name: 'reindex')

      expect { service.call { |_, _| } }.not_to raise_error
      expect(service.task_run.status).to eq('success')
    end
  end

  describe '#enqueue' do
    it 'creates a pending task_run without running anything' do
      service = build_service
      task_run = service.enqueue

      expect(task_run).to be_persisted
      expect(task_run.status).to eq('pending')
      expect(fake_runner_class.last).to be_nil
    end

    it 'is idempotent — calling twice returns the same record' do
      service = build_service
      first  = service.enqueue
      second = service.enqueue
      expect(second.id).to eq(first.id)
    end
  end
end
