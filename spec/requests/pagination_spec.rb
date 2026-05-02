# frozen_string_literal: true

require 'rails_helper'

# Pagination contract for the listing endpoints.
#
# These tests sit at the request layer (not the controller-or-concern
# layer) because pagination affects more than the SQL slice — it also
# changes the response shape (`pagination` block, page/per_page metadata),
# the back-compat alias for `?limit`, and the interplay with the
# pre-existing `?all` filter. Anything that touches the shape belongs
# at the wire boundary.
RSpec.describe 'Listing pagination', type: :request do
  let(:app_name) { 'pyworker' }
  let(:env_name) { 'production' }

  def auth_headers(grants:, sub: 'spec-user')
    token, = JwtService.encode(name: sub, grants: grants)
    { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' }
  end

  let(:default_grants) do
    [ { app: app_name, envs: [ env_name ], cmds: %w[deploy task:* abort] } ]
  end

  # Helper: bulk-create N deploys for the current `sub`. Used to walk
  # multiple pages without writing 47 lines of factory code per spec.
  def seed_deploys(count, app: app_name, env: env_name, triggered_by: 'spec-user')
    Array.new(count) do |i|
      Deploy.create!(
        app: app, env: env, branch: 'master',
        command: 'deploy', status: 'success',
        exit_code: 0,
        triggered_by: triggered_by,
        # Slight stagger so `recent` order is deterministic — without
        # this two rows can share `created_at` and the page slice
        # becomes ambiguous.
        created_at: Time.current - i.seconds
      )
    end
  end

  def seed_task_runs(count, app: app_name, env: env_name, triggered_by: 'spec-user')
    Array.new(count) do |i|
      TaskRun.create!(
        app: app, env: env, branch: 'master',
        task_name: 'reindex', status: 'success',
        exit_code: 0,
        triggered_by: triggered_by,
        created_at: Time.current - i.seconds
      )
    end
  end

  describe 'GET /deploys' do
    it 'returns the pagination block with sensible defaults on the first page' do
      seed_deploys(5)

      get '/deploys', headers: auth_headers(grants: default_grants)

      expect(response).to have_http_status(:ok)
      pagination = response.parsed_body['pagination']
      expect(pagination).to include(
        'page' => 1,
        'per_page' => 20,
        'total_count' => 5,
        'total_pages' => 1
      )
    end

    it 'slices results by page + per_page' do
      seeded = seed_deploys(25)

      get '/deploys', params: { per_page: 10 }, headers: auth_headers(grants: default_grants)
      page1_ids = response.parsed_body['deploys'].map { |d| d['id'] }
      expect(page1_ids).to eq(seeded.first(10).map(&:id))

      get '/deploys', params: { page: 2, per_page: 10 }, headers: auth_headers(grants: default_grants)
      page2_ids = response.parsed_body['deploys'].map { |d| d['id'] }
      expect(page2_ids).to eq(seeded[10, 10].map(&:id))

      get '/deploys', params: { page: 3, per_page: 10 }, headers: auth_headers(grants: default_grants)
      page3_ids = response.parsed_body['deploys'].map { |d| d['id'] }
      # Last page is short — only 5 left.
      expect(page3_ids).to eq(seeded[20, 5].map(&:id))
    end

    it 'reports total_pages computed from total_count and per_page' do
      seed_deploys(25)

      get '/deploys', params: { per_page: 10 }, headers: auth_headers(grants: default_grants)
      expect(response.parsed_body['pagination']).to include(
        'total_count' => 25,
        'total_pages' => 3
      )
    end

    it 'returns total_pages=1 even when there are zero results' do
      get '/deploys', headers: auth_headers(grants: default_grants)
      expect(response.parsed_body['pagination']).to include(
        'total_count' => 0,
        'total_pages' => 1
      )
    end

    it 'tolerates out-of-range pages with an empty list (not a 4xx)' do
      seed_deploys(5)

      get '/deploys', params: { page: 99, per_page: 10 }, headers: auth_headers(grants: default_grants)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['deploys']).to be_empty
      expect(response.parsed_body['pagination']).to include('page' => 99)
    end

    it 'clamps per_page above 100 to the server cap' do
      seed_deploys(150)

      get '/deploys', params: { per_page: 999 }, headers: auth_headers(grants: default_grants)
      expect(response.parsed_body['pagination']['per_page']).to eq(100)
      expect(response.parsed_body['deploys'].length).to eq(100)
    end

    it 'honors the legacy ?limit alias when ?per_page is not provided' do
      seed_deploys(15)

      get '/deploys', params: { limit: 5 }, headers: auth_headers(grants: default_grants)
      expect(response.parsed_body['pagination']['per_page']).to eq(5)
      expect(response.parsed_body['deploys'].length).to eq(5)
    end

    it 'prefers ?per_page over ?limit when both are sent' do
      seed_deploys(15)

      get '/deploys',
          params: { per_page: 7, limit: 3 },
          headers: auth_headers(grants: default_grants)
      expect(response.parsed_body['pagination']['per_page']).to eq(7)
      expect(response.parsed_body['deploys'].length).to eq(7)
    end

    it 'falls back to defaults on garbage input' do
      seed_deploys(5)

      get '/deploys',
          params: { page: 'banana', per_page: '-3' },
          headers: auth_headers(grants: default_grants)
      expect(response.parsed_body['pagination']).to include(
        'page' => 1,
        'per_page' => 20
      )
    end

    it 'respects the active filter when computing pagination metadata' do
      # 10 finished + 3 active. Pagination should reflect the FILTERED
      # total, not the entire table — that's the only sane behavior for
      # a "page X of Y" footer over a filtered listing.
      #
      # Active deploys live on different apps because the per-app unique
      # index forbids two active rows on the same app at once. The grant
      # uses a wildcard for `app` so all three are visible.
      seed_deploys(10)
      %w[app-a app-b app-c].each_with_index do |app, i|
        Deploy.create!(
          app: app, env: env_name, branch: 'master',
          command: 'deploy', status: 'running',
          triggered_by: 'spec-user',
          created_at: Time.current + i.seconds
        )
      end
      wildcard = [ { app: '*', envs: [ '*' ], cmds: [ '*' ] } ]

      get '/deploys', params: { active: 'true' }, headers: auth_headers(grants: wildcard)
      expect(response.parsed_body['pagination']['total_count']).to eq(3)
      expect(response.parsed_body['deploys'].length).to eq(3)
    end

    it 'composes with ?all=true so the team-wide listing is paginated too' do
      seed_deploys(5, triggered_by: 'spec-user')
      seed_deploys(7, triggered_by: 'teammate')

      get '/deploys',
          params: { all: 'true', per_page: 5 },
          headers: auth_headers(grants: default_grants)

      body = response.parsed_body
      expect(body['scope']).to eq('all')
      expect(body['pagination']).to include(
        'page' => 1,
        'per_page' => 5,
        'total_count' => 12,
        'total_pages' => 3
      )
      expect(body['deploys'].length).to eq(5)
    end
  end

  describe 'GET /tasks' do
    # These pagination specs are deliberately a thin mirror of the
    # /deploys block — same shape, same defaults, same edge cases.
    # Anything that diverges here would mean the two endpoints lied to
    # the same client. We leverage seed_task_runs to keep them short.
    it 'returns the pagination block with sensible defaults' do
      seed_task_runs(3)

      get '/tasks', headers: auth_headers(grants: default_grants)
      expect(response.parsed_body['pagination']).to include(
        'page' => 1,
        'per_page' => 20,
        'total_count' => 3,
        'total_pages' => 1
      )
    end

    it 'slices results by page + per_page' do
      seeded = seed_task_runs(15)

      get '/tasks', params: { page: 2, per_page: 5 }, headers: auth_headers(grants: default_grants)
      ids = response.parsed_body['task_runs'].map { |t| t['id'] }
      expect(ids).to eq(seeded[5, 5].map(&:id))
    end

    it 'honors the legacy ?limit alias' do
      seed_task_runs(10)

      get '/tasks', params: { limit: 4 }, headers: auth_headers(grants: default_grants)
      expect(response.parsed_body['pagination']['per_page']).to eq(4)
      expect(response.parsed_body['task_runs'].length).to eq(4)
    end
  end
end
