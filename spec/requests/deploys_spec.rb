# frozen_string_literal: true

require 'rails_helper'

# Focused on the policy change introduced together with the abort feature:
# index/show used to filter by `triggered_by`, now filters by visibility
# (mine by default, ?all=true expands to "every app you have access to").
#
# Streaming and async creation flows are exercised through the existing
# CommandsController/TaskService coverage — duplicating them here would be
# noise.
RSpec.describe 'Deploys index/show policy', type: :request do
  let(:app_name) { 'udoczcom' }
  let(:env_name) { 'production' }

  def auth_headers(grants:, sub: 'spec-user')
    token, = JwtService.encode(name: sub, grants: grants)
    { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' }
  end

  let(:default_grants) do
    [ { app: app_name, envs: [ env_name ], cmds: [ 'deploy' ] } ]
  end

  describe 'GET /deploys (index)' do
    it 'defaults to deploys triggered by the caller and surfaces the --all hint' do
      mine = Deploy.create!(
        app: app_name, env: env_name, branch: 'master',
        command: 'deploy', status: 'success',
        triggered_by: 'spec-user'
      )
      Deploy.create!(
        app: app_name, env: env_name, branch: 'master',
        command: 'deploy', status: 'success',
        triggered_by: 'teammate'
      )

      get '/deploys', headers: auth_headers(grants: default_grants)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      ids = body['deploys'].map { |d| d['id'] }
      expect(ids).to contain_exactly(mine.id)
      expect(body['scope']).to eq('mine')
      expect(body['hint']).to be_present
    end

    it 'with ?all=true returns deploys for every app the token can see' do
      mine = Deploy.create!(
        app: app_name, env: env_name, branch: 'master',
        command: 'deploy', status: 'success',
        triggered_by: 'spec-user'
      )
      teammate = Deploy.create!(
        app: app_name, env: env_name, branch: 'feature',
        command: 'deploy', status: 'running',
        triggered_by: 'teammate'
      )
      Deploy.create!(
        app: 'other-app', env: env_name, branch: 'master',
        command: 'deploy', status: 'success',
        triggered_by: 'teammate'
      )

      get '/deploys', params: { all: 'true' }, headers: auth_headers(grants: default_grants)

      body = response.parsed_body
      ids = body['deploys'].map { |d| d['id'] }
      expect(ids).to contain_exactly(mine.id, teammate.id)
      expect(body['scope']).to eq('all')
    end

    it 'wildcard tokens see every deploy on the box with --all' do
      Deploy.create!(
        app: 'app-a', env: env_name, branch: 'master',
        command: 'deploy', status: 'success', triggered_by: 'a'
      )
      Deploy.create!(
        app: 'app-b', env: env_name, branch: 'master',
        command: 'deploy', status: 'success', triggered_by: 'b'
      )

      get '/deploys', params: { all: 'true' },
                      headers: auth_headers(grants: [ { app: '*', envs: [ '*' ], cmds: [ '*' ] } ])

      ids = response.parsed_body['deploys'].map { |d| d['app'] }
      expect(ids).to contain_exactly('app-a', 'app-b')
    end
  end

  describe 'GET /deploys/:id (show)' do
    it 'returns 200 with logs to the original triggerer' do
      d = Deploy.create!(
        app: app_name, env: env_name, branch: 'master',
        command: 'deploy', status: 'success',
        triggered_by: 'spec-user', log: 'logged output'
      )

      get "/deploys/#{d.id}", headers: auth_headers(grants: default_grants)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['log']).to include('logged output')
    end

    it 'returns 200 with logs to a teammate that has any grant on the app' do
      d = Deploy.create!(
        app: app_name, env: env_name, branch: 'master',
        command: 'deploy', status: 'success',
        triggered_by: 'teammate', log: 'shared output'
      )

      get "/deploys/#{d.id}", headers: auth_headers(grants: default_grants)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['log']).to include('shared output')
    end

    it 'returns 403 to a token with no grant on the deploy app' do
      d = Deploy.create!(
        app: 'foreign-app', env: env_name, branch: 'master',
        command: 'deploy', status: 'success',
        triggered_by: 'teammate'
      )

      get "/deploys/#{d.id}", headers: auth_headers(grants: default_grants)

      expect(response).to have_http_status(:forbidden)
    end
  end
end
