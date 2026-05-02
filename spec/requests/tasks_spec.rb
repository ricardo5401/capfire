# frozen_string_literal: true

require 'rails_helper'

# Request specs hit the real /tasks endpoints with a signed JWT minted via
# JwtService.encode. Streaming mode is exercised through SSE chunks; async
# mode through the 202 JSON contract. The actual shell execution is
# stubbed at the CommandRunner boundary so no PTY is spawned.
RSpec.describe 'POST /tasks', type: :request do
  let(:app_name) { 'pyworker' }
  let(:env)      { 'production' }
  let(:branch)   { 'master' }

  let(:tmp_root) { Dir.mktmpdir('capfire-req-spec') }
  let(:app_dir)  { File.join(tmp_root, app_name) }

  before do
    FileUtils.mkdir_p(app_dir)
    File.write(File.join(app_dir, 'capfire.yml'), <<~YAML)
      tasks:
        reindex:
          run: "echo reindex"
        backfill:
          run: "echo backfill since=%{since}"
          params: [since]
        sync:
          after:
            - "echo done"
    YAML

    # Point AppConfig at our temp dir for the duration of the spec.
    allow(Capfire.config).to receive(:apps_root).and_return(tmp_root)

    # Replace CommandRunner with a stub that doesn't spawn anything.
    stub_const('CommandRunner', Class.new(CommandRunner) do
      def self.git_sync_command(branch:)
        "echo git-sync #{branch}"
      end

      def run
        yield 'fake output'
        0
      end
    end)
  end

  after { FileUtils.remove_entry(tmp_root) if File.directory?(tmp_root) }

  def auth_headers(grants:)
    token, = JwtService.encode(name: 'spec-user', grants: grants)
    { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' }
  end

  let(:default_grants) do
    [ { app: app_name, envs: [ env ], cmds: [ 'task:reindex', 'task:backfill', 'task:sync' ] } ]
  end

  describe 'happy paths (async mode)' do
    it 'creates a TaskRun and returns 202 with task_run_id + track_url' do
      post '/tasks',
           params: { app: app_name, env: env, task: 'reindex', branch: branch, async: true }.to_json,
           headers: auth_headers(grants: default_grants)

      expect(response).to have_http_status(:accepted)
      body = response.parsed_body
      expect(body['status']).to eq('accepted')
      expect(body['task_run_id']).to be_a(Integer)
      expect(body['track_url']).to match(%r{/tasks/\d+\z})
      expect(body['task']).to eq('reindex')
      expect(body['branch']).to eq(branch)

      task_run = TaskRun.find(body['task_run_id'])
      expect(task_run.app).to eq(app_name)
      expect(task_run.task_name).to eq('reindex')
      expect(task_run.triggered_by).to eq('spec-user')
    end

    it 'persists args sent in the JSON body' do
      post '/tasks',
           params: {
             app: app_name, env: env, task: 'backfill',
             branch: branch, args: { since: '2024-01-01' }, async: true
           }.to_json,
           headers: auth_headers(grants: default_grants)

      expect(response).to have_http_status(:accepted)
      task_run = TaskRun.last
      expect(task_run.args).to eq('since' => '2024-01-01')
    end
  end

  describe 'authorization' do
    it 'returns 403 when the token has no task:<name> grant' do
      post '/tasks',
           params: { app: app_name, env: env, task: 'reindex', async: true }.to_json,
           headers: auth_headers(
             grants: [ { app: app_name, envs: [ env ], cmds: [ 'deploy' ] } ]
           )

      expect(response).to have_http_status(:forbidden)
    end

    it 'accepts the `tasks:` shorthand on the grant' do
      post '/tasks',
           params: { app: app_name, env: env, task: 'reindex', async: true }.to_json,
           headers: auth_headers(
             grants: [ { app: app_name, envs: [ env ], tasks: [ 'reindex' ] } ]
           )

      expect(response).to have_http_status(:accepted)
    end

    it 'accepts the `task:*` wildcard on cmds' do
      post '/tasks',
           params: { app: app_name, env: env, task: 'backfill', args: { since: 'x' }, async: true }.to_json,
           headers: auth_headers(
             grants: [ { app: app_name, envs: [ env ], cmds: [ 'task:*' ] } ]
           )

      expect(response).to have_http_status(:accepted)
    end
  end

  describe 'validation' do
    it 'returns 400 for an unknown task with the available_tasks list' do
      post '/tasks',
           params: { app: app_name, env: env, task: 'definitely_not_declared', async: true }.to_json,
           headers: auth_headers(grants: [ { app: app_name, envs: [ env ], cmds: [ 'task:*' ] } ])

      expect(response).to have_http_status(:bad_request)
      body = response.parsed_body
      expect(body['error']).to eq('bad_request')
      expect(body['available_tasks']).to include('reindex', 'backfill', 'sync')
    end

    it 'returns 400 when a declared param is missing from args' do
      post '/tasks',
           params: { app: app_name, env: env, task: 'backfill', async: true }.to_json,
           headers: auth_headers(grants: default_grants)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to match(/missing params: since/)
    end

    it 'returns 400 when args carries undeclared keys' do
      post '/tasks',
           params: {
             app: app_name, env: env, task: 'backfill',
             args: { since: 'x', rogue: 'y' }, async: true
           }.to_json,
           headers: auth_headers(grants: default_grants)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to match(/unknown args: rogue/)
    end

    it 'rejects invalid task names before authorization' do
      post '/tasks',
           params: { app: app_name, env: env, task: '../etc/passwd', async: true }.to_json,
           headers: auth_headers(grants: [ { app: app_name, envs: [ env ], cmds: [ 'task:*' ] } ])

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe 'concurrency' do
    it 'returns 409 with the active task payload when one is already running' do
      blocker = TaskRun.create!(
        app: app_name, env: env, task_name: 'backfill',
        branch: branch, status: 'running',
        triggered_by: 'someone-else',
        started_at: 1.minute.ago
      )

      post '/tasks',
           params: { app: app_name, env: env, task: 'reindex', async: true }.to_json,
           headers: auth_headers(grants: default_grants)

      expect(response).to have_http_status(:conflict)
      body = response.parsed_body
      expect(body['error']).to eq('conflict')
      expect(body['active']).to include(
        'task_run_id' => blocker.id,
        'task' => 'backfill',
        'triggered_by' => 'someone-else'
      )
      expect(body['retry_after_seconds']).to be > 0
    end

    it 'returns 409 with active_deploy when sync is requested while a deploy is running' do
      deploy = Deploy.create!(
        app: app_name, env: env, branch: branch,
        command: 'deploy', status: 'running',
        triggered_by: 'releaser',
        started_at: 30.seconds.ago
      )

      post '/tasks',
           params: { app: app_name, env: env, task: 'sync', async: true }.to_json,
           headers: auth_headers(grants: default_grants)

      expect(response).to have_http_status(:conflict)
      body = response.parsed_body
      expect(body['active_deploy']).to include('id' => deploy.id, 'command' => 'deploy')
    end

    it 'allows non-sync tasks while a deploy is running on the same app' do
      Deploy.create!(
        app: app_name, env: env, branch: branch,
        command: 'deploy', status: 'running',
        triggered_by: 'releaser'
      )

      post '/tasks',
           params: { app: app_name, env: env, task: 'reindex', async: true }.to_json,
           headers: auth_headers(grants: default_grants)

      expect(response).to have_http_status(:accepted)
    end
  end

  describe 'GET /tasks/:id' do
    it 'returns the task run + log when the caller is the original triggerer' do
      run = TaskRun.create!(
        app: app_name, env: env, task_name: 'reindex',
        branch: branch, status: 'success',
        log: 'line1\nline2\n',
        triggered_by: 'spec-user',
        started_at: 1.minute.ago, finished_at: Time.current
      )

      get "/tasks/#{run.id}", headers: auth_headers(grants: default_grants)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body['id']).to eq(run.id)
      expect(body['log']).to include('line1')
    end

    # Policy change: tokens with any grant on the app see all runs on it,
    # including someone else's. This is the team-visibility feature; the
    # tradeoff is that logs are no longer per-user-private.
    it 'returns the run from another user when the token has a grant on the app' do
      run = TaskRun.create!(
        app: app_name, env: env, task_name: 'reindex',
        branch: branch, status: 'success',
        triggered_by: 'someone-else'
      )

      get "/tasks/#{run.id}", headers: auth_headers(grants: default_grants)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['id']).to eq(run.id)
    end

    it 'returns 403 when the token has no grant on the run app' do
      run = TaskRun.create!(
        app: 'other-app', env: env, task_name: 'reindex',
        branch: branch, status: 'success',
        triggered_by: 'someone-else'
      )

      get "/tasks/#{run.id}", headers: auth_headers(grants: default_grants)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'GET /tasks (index)' do
    # The streaming-mode tests above can spawn a background thread that
    # creates TaskRun rows OUTSIDE the spec's transaction (see Runnable
    # concern). Truncate before the index assertions so those leaked
    # rows don't pollute the visible-set checks.
    before { TaskRun.delete_all }

    it 'defaults to only task runs triggered by the caller (mine scope)' do
      mine = TaskRun.create!(
        app: app_name, env: env, task_name: 'reindex',
        branch: branch, status: 'success',
        triggered_by: 'spec-user'
      )
      TaskRun.create!(
        app: app_name, env: env, task_name: 'reindex',
        branch: branch, status: 'success',
        triggered_by: 'someone-else'
      )

      get '/tasks', headers: auth_headers(grants: default_grants)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      ids = body['task_runs'].map { |t| t['id'] }
      expect(ids).to contain_exactly(mine.id)
      expect(body['scope']).to eq('mine')
      # Hint surfaces the --all flag so users discover team visibility.
      expect(body['hint']).to be_present
    end

    it 'with ?all=true lists every run on apps the token has access to' do
      mine = TaskRun.create!(
        app: app_name, env: env, task_name: 'reindex',
        branch: branch, status: 'success',
        triggered_by: 'spec-user'
      )
      teammate = TaskRun.create!(
        app: app_name, env: env, task_name: 'backfill',
        branch: branch, status: 'success',
        triggered_by: 'someone-else'
      )
      TaskRun.create!(
        app: 'unrelated-app', env: env, task_name: 'reindex',
        branch: branch, status: 'success',
        triggered_by: 'someone-else'
      )

      get '/tasks', params: { all: 'true' }, headers: auth_headers(grants: default_grants)

      body = response.parsed_body
      ids = body['task_runs'].map { |t| t['id'] }
      expect(ids).to contain_exactly(mine.id, teammate.id)
      expect(body['scope']).to eq('all')
      expect(body['hint']).to be_nil
    end

    it 'rejects ?app= filtering for an app the token cannot see in --all mode' do
      get '/tasks', params: { all: 'true', app: 'unrelated-app' },
                    headers: auth_headers(grants: default_grants)
      expect(response).to have_http_status(:forbidden)
    end

    it 'filters by task name when ?task= is given' do
      a = TaskRun.create!(
        app: app_name, env: env, task_name: 'reindex',
        branch: branch, status: 'success', triggered_by: 'spec-user'
      )
      TaskRun.create!(
        app: app_name, env: env, task_name: 'backfill',
        branch: branch, status: 'success', triggered_by: 'spec-user'
      )

      get '/tasks', params: { task: 'reindex' }, headers: auth_headers(grants: default_grants)

      ids = response.parsed_body['task_runs'].map { |t| t['id'] }
      expect(ids).to contain_exactly(a.id)
    end
  end
end
