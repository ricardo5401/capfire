# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'yaml'

# AppConfig is pure Ruby — no Rails, no DB, no Capfire.config. We avoid
# `rails_helper` here so this spec runs in environments without Postgres.
require_relative '../../app/services/app_config'
require_relative '../../app/services/load_balancer_config'
require_relative '../../app/services/command_runner'
require_relative '../../app/services/slack_notifier'

RSpec.describe AppConfig do
  let(:tmp_root) { Dir.mktmpdir('capfire-spec') }
  let(:app_dir) { File.join(tmp_root, app_name) }
  let(:app_name) { 'pyworker' }
  subject(:cfg) { described_class.new(app: app_name, apps_root: tmp_root) }

  before { FileUtils.mkdir_p(app_dir) }
  after  { FileUtils.remove_entry(tmp_root) }

  def write_yaml(contents)
    File.write(File.join(app_dir, 'capfire.yml'), contents)
  end

  describe '#task_for' do
    context 'when the task has no `params:`' do
      before do
        write_yaml(<<~YAML)
          tasks:
            reindex:
              run: "python manage.py reindex --all"
        YAML
      end

      it 'interpolates app/env/branch placeholders verbatim' do
        expect(cfg.task_for(name: 'reindex', env: 'production'))
          .to eq('python manage.py reindex --all')
      end

      it 'rejects unknown args (typo protection)' do
        expect { cfg.task_for(name: 'reindex', env: 'production', args: { 'foo' => 'bar' }) }
          .to raise_error(AppConfig::InvalidConfig, /unknown args: foo/)
      end
    end

    context 'when the task declares `params:`' do
      before do
        write_yaml(<<~YAML)
          tasks:
            backfill:
              run: "python scripts/backfill.py --since=%{since} --tenant=%{tenant}"
              params: [since, tenant]
        YAML
      end

      it 'interpolates declared params' do
        result = cfg.task_for(
          name: 'backfill', env: 'production',
          args: { 'since' => '2024-01-01', 'tenant' => 'acme' }
        )
        expect(result).to eq('python scripts/backfill.py --since=2024-01-01 --tenant=acme')
      end

      it 'fails when a declared param is missing from args' do
        expect do
          cfg.task_for(
            name: 'backfill', env: 'production',
            args: { 'since' => '2024-01-01' }
          )
        end.to raise_error(AppConfig::InvalidConfig, /missing params: tenant/)
      end

      it 'fails when args carries keys not declared in params' do
        expect do
          cfg.task_for(
            name: 'backfill', env: 'production',
            args: { 'since' => '2024-01-01', 'tenant' => 'acme', 'rogue' => 'x' }
          )
        end.to raise_error(AppConfig::InvalidConfig, /unknown args: rogue/)
      end

      it 'reports both missing and extra in the same error' do
        expect do
          cfg.task_for(
            name: 'backfill', env: 'production',
            args: { 'rogue' => 'x' }
          )
        end.to raise_error(
          AppConfig::InvalidConfig,
          /missing params: since, tenant.*unknown args: rogue/m
        )
      end
    end

    context 'with the reserved `sync` task' do
      it 'returns the built-in git_sync chain when no override is given' do
        write_yaml(<<~YAML)
          tasks:
            sync:
              after:
                - "uv sync"
        YAML

        result = cfg.task_for(name: 'sync', env: 'production', branch: 'master')
        expect(result).to eq(
          'git fetch --prune origin && git checkout master && ' \
          'git reset --hard origin/master && uv sync'
        )
      end

      it 'falls back to default branch `main` when no branch is given' do
        write_yaml("tasks:\n  sync:\n    after: []\n")

        result = cfg.task_for(name: 'sync', env: 'production')
        expect(result).to include('git checkout main')
        expect(result).to include('git reset --hard origin/main')
      end

      it 'works without the app declaring `sync` at all' do
        write_yaml("tasks:\n  reindex:\n    run: \"echo hi\"\n")

        result = cfg.task_for(name: 'sync', env: 'production', branch: 'main')
        expect(result).to start_with('git fetch --prune origin')
        expect(result).not_to include('&&  ') # no trailing empty hooks
      end

      it 'respects an explicit `run:` override (no built-in git sync)' do
        write_yaml(<<~YAML)
          tasks:
            sync:
              run: "custom-shell --opt"
        YAML

        result = cfg.task_for(name: 'sync', env: 'production', branch: 'main')
        expect(result).to eq('custom-shell --opt')
        expect(result).not_to include('git fetch')
      end

      it 'chains multiple `after:` steps with &&' do
        write_yaml(<<~YAML)
          tasks:
            sync:
              after:
                - "uv sync"
                - "uv run python manage.py migrate"
        YAML

        result = cfg.task_for(name: 'sync', env: 'production', branch: 'main')
        expect(result).to end_with('uv sync && uv run python manage.py migrate')
      end

      it 'shellescapes branch names with slashes (release branches)' do
        write_yaml("tasks:\n  sync:\n    after: []\n")

        result = cfg.task_for(name: 'sync', env: 'production', branch: 'feature/abc-123')
        expect(result).to include('git checkout feature/abc-123')
      end
    end

    context 'with an unknown task' do
      it 'raises UnknownTask before touching the shell' do
        write_yaml("tasks:\n  reindex:\n    run: \"echo hi\"\n")

        expect { cfg.task_for(name: 'definitely_not_declared', env: 'production') }
          .to raise_error(AppConfig::UnknownTask, /definitely_not_declared/)
      end
    end

    context 'with a malformed task spec' do
      it 'rejects non-mapping entries' do
        write_yaml("tasks:\n  reindex: \"not-a-mapping\"\n")

        expect { cfg.task_for(name: 'reindex', env: 'production') }
          .to raise_error(AppConfig::InvalidConfig, /must be a mapping/)
      end

      it 'rejects user tasks missing `run:`' do
        write_yaml("tasks:\n  reindex:\n    params: [since]\n")

        expect { cfg.task_for(name: 'reindex', env: 'production', args: { 'since' => 'x' }) }
          .to raise_error(AppConfig::InvalidConfig, /missing a `run:` command/)
      end

      it 'rejects placeholders pointing at undeclared params' do
        write_yaml(<<~YAML)
          tasks:
            backfill:
              run: "do --since=%{since}"
              # forgot to declare params: [since]
        YAML

        expect { cfg.task_for(name: 'backfill', env: 'production') }
          .to raise_error(AppConfig::InvalidConfig, /unknown placeholder/)
      end
    end
  end

  describe '#known_task?' do
    before do
      write_yaml(<<~YAML)
        tasks:
          reindex:
            run: "echo hi"
      YAML
    end

    it 'returns true for tasks declared in yaml' do
      expect(cfg.known_task?('reindex')).to be true
    end

    it 'always returns true for the reserved `sync`' do
      expect(cfg.known_task?('sync')).to be true
    end

    it 'returns false for undeclared names' do
      expect(cfg.known_task?('not_a_task')).to be false
    end

    it 'returns false for blank input' do
      expect(cfg.known_task?(nil)).to be false
      expect(cfg.known_task?('')).to be false
    end
  end

  describe '#task_names' do
    it 'always includes `sync` even when not declared' do
      write_yaml("tasks:\n  reindex:\n    run: \"echo hi\"\n")
      expect(cfg.task_names).to eq(%w[reindex sync])
    end

    it 'returns sorted names' do
      write_yaml(<<~YAML)
        tasks:
          zoo:
            run: "x"
          alpha:
            run: "y"
          sync:
            after: ["uv sync"]
      YAML
      expect(cfg.task_names).to eq(%w[alpha sync zoo])
    end

    it 'returns just `sync` for apps without a `tasks:` section' do
      write_yaml('commands: { deploy: "echo deploy" }')
      expect(cfg.task_names).to eq(%w[sync])
    end
  end
end
