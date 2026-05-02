# frozen_string_literal: true

require 'rails_helper'

# End-to-end coverage of POST /deploys/:id/abort and POST /tasks/:id/abort.
# Both endpoints share the same auth model (owner OR cmd:abort) and the
# same response shape, so the specs are structured as a parameterized
# block over the two flavors.
#
# AbortService internals are exercised by the service spec — here we only
# care that the controller path:
#   - requires JWT,
#   - enforces owner-or-cmd:abort,
#   - dispatches to AbortService,
#   - returns the merged status payload.
#
# We stub Process.kill so no real signals are sent.
RSpec.describe 'Abort endpoints', type: :request do
  let(:app_name) { 'pyworker' }
  let(:env_name) { 'production' }
  let(:fake_pid) { 99_999 }

  before do
    # No real signals get through; default to "TERM lands, process gone".
    allow(Process).to receive(:kill).with('-TERM', fake_pid).and_return(1)
    allow(Process).to receive(:kill).with(0, fake_pid).and_raise(Errno::ESRCH)
  end

  def auth_headers(grants:, sub: 'spec-user')
    token, = JwtService.encode(name: sub, grants: grants)
    { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' }
  end

  shared_examples 'an abort endpoint' do |endpoint_path:, factory:|
    let(:record) { factory.call(app_name, env_name, fake_pid, 'someone-else') }
    let(:url) { "#{endpoint_path}/#{record.id}/abort" }

    context 'authorization' do
      it 'returns 401 without a token' do
        post url
        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns 404 when the record does not exist' do
        post "#{endpoint_path}/999999/abort",
             headers: auth_headers(grants: [ { app: app_name, envs: [ env_name ], cmds: [ '*' ] } ])
        expect(response).to have_http_status(:not_found)
      end

      it 'allows the owner to abort their own run without cmd:abort' do
        # Owner record uses a DIFFERENT app to dodge the per-app unique
        # index on active runs (`record` from the let block is already
        # there with status=running on `app_name`). Both must be active
        # so the abort actually has work to do.
        owner_record = factory.call('other-app', env_name, fake_pid, 'spec-user')
        post "#{endpoint_path}/#{owner_record.id}/abort",
             headers: auth_headers(grants: [ { app: 'other-app', envs: [ env_name ], cmds: [ 'deploy' ] } ])
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['abort_status']).to eq('canceled')
      end

      it 'rejects a token without cmd:abort that is not the owner' do
        post url,
             headers: auth_headers(grants: [ { app: app_name, envs: [ env_name ], cmds: [ 'deploy' ] } ])
        expect(response).to have_http_status(:forbidden)
      end

      it 'allows a non-owner with cmd:abort on the right app+env' do
        post url,
             headers: auth_headers(grants: [ { app: app_name, envs: [ env_name ], cmds: [ 'abort' ] } ])
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['abort_status']).to eq('canceled')
      end

      it 'allows the global wildcard cmd:*' do
        post url,
             headers: auth_headers(grants: [ { app: '*', envs: [ '*' ], cmds: [ '*' ] } ])
        expect(response).to have_http_status(:ok)
      end
    end

    context 'idempotency' do
      it 'returns abort_status=already_finished for a terminal record' do
        record.update!(status: 'success', exit_code: 0, finished_at: Time.current)
        post url,
             headers: auth_headers(grants: [ { app: app_name, envs: [ env_name ], cmds: [ 'abort' ] } ])
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['abort_status']).to eq('already_finished')
      end
    end

    context 'reason payload' do
      it 'is forwarded to the audit log' do
        post url,
             params: { reason: 'wrong branch' }.to_json,
             headers: auth_headers(grants: [ { app: app_name, envs: [ env_name ], cmds: [ 'abort' ] } ])
        expect(response).to have_http_status(:ok)
        expect(record.reload.log).to include('wrong branch')
      end
    end
  end

  describe 'POST /deploys/:id/abort' do
    include_examples 'an abort endpoint',
                     endpoint_path: '/deploys',
                     factory: ->(app, env, pid, by) {
                       Deploy.create!(
                         app: app, env: env, branch: 'master',
                         command: 'deploy', status: 'running',
                         pid: pid, started_at: 1.minute.ago,
                         triggered_by: by
                       )
                     }
  end

  describe 'POST /tasks/:id/abort' do
    include_examples 'an abort endpoint',
                     endpoint_path: '/tasks',
                     factory: ->(app, env, pid, by) {
                       TaskRun.create!(
                         app: app, env: env, branch: 'master',
                         task_name: 'reindex', status: 'running',
                         pid: pid, started_at: 1.minute.ago,
                         triggered_by: by
                       )
                     }
  end
end
