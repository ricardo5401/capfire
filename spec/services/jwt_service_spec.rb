# frozen_string_literal: true

require 'rails_helper'

# JwtService needs Capfire.config.jwt_secret to encode/decode, so this
# loads the full Rails environment. RevokedToken (DB-backed) is exercised
# only through the encode/decode happy paths — revocation has its own
# integration coverage in tokens_command.
RSpec.describe JwtService do
  let(:secret) { 'spec-secret-very-long-enough' }

  before do
    allow(Capfire.config).to receive(:jwt_secret).and_return(secret)
    allow(Capfire.config).to receive(:jwt_algorithm).and_return('HS256')
    allow(RevokedToken).to receive(:revoked?).and_return(false)
  end

  def encode_token(grants:)
    described_class.encode(name: 'spec', grants: grants).first
  end

  describe '.authorize!' do
    context 'with explicit `cmds:` grants' do
      let(:claims) do
        described_class.decode!(
          encode_token(grants: [
            { app: 'pyworker', envs: [ 'production' ], cmds: [ 'deploy', 'task:reindex' ] }
          ])
        )
      end

      it 'allows the listed cmds' do
        expect { described_class.authorize!(claims: claims, app: 'pyworker', env: 'production', cmd: 'deploy') }
          .not_to raise_error
        expect { described_class.authorize!(claims: claims, app: 'pyworker', env: 'production', cmd: 'task:reindex') }
          .not_to raise_error
      end

      it 'rejects cmds not in the list' do
        expect { described_class.authorize!(claims: claims, app: 'pyworker', env: 'production', cmd: 'task:backfill') }
          .to raise_error(JwtService::Unauthorized)
      end
    end

    context 'with the `tasks:` shorthand' do
      let(:claims) do
        described_class.decode!(
          encode_token(grants: [
            { app: 'pyworker', envs: [ 'production' ], tasks: %w[sync reindex] }
          ])
        )
      end

      it 'allows task:<name> for every entry in tasks' do
        %w[sync reindex].each do |name|
          expect { described_class.authorize!(claims: claims, app: 'pyworker', env: 'production', cmd: "task:#{name}") }
            .not_to raise_error
        end
      end

      it 'does NOT grant deploy permissions' do
        expect { described_class.authorize!(claims: claims, app: 'pyworker', env: 'production', cmd: 'deploy') }
          .to raise_error(JwtService::Unauthorized)
      end

      it 'rejects tasks not listed' do
        expect { described_class.authorize!(claims: claims, app: 'pyworker', env: 'production', cmd: 'task:backfill') }
          .to raise_error(JwtService::Unauthorized)
      end
    end

    context 'when a grant mixes `cmds:` and `tasks:`' do
      let(:claims) do
        described_class.decode!(
          encode_token(grants: [
            { app: 'pyworker', envs: [ 'production' ], cmds: [ 'deploy' ], tasks: %w[sync] }
          ])
        )
      end

      it 'merges both into a single allow-list' do
        %w[deploy task:sync].each do |cmd|
          expect { described_class.authorize!(claims: claims, app: 'pyworker', env: 'production', cmd: cmd) }
            .not_to raise_error
        end
      end
    end

    context 'with the `task:*` wildcard' do
      let(:claims) do
        described_class.decode!(
          encode_token(grants: [
            { app: 'pyworker', envs: [ 'production' ], cmds: [ 'task:*' ] }
          ])
        )
      end

      it 'allows any task:<name>' do
        %w[task:sync task:reindex task:never_seen_before].each do |cmd|
          expect { described_class.authorize!(claims: claims, app: 'pyworker', env: 'production', cmd: cmd) }
            .not_to raise_error
        end
      end

      it 'does NOT allow non-task cmds' do
        %w[deploy restart rollback].each do |cmd|
          expect { described_class.authorize!(claims: claims, app: 'pyworker', env: 'production', cmd: cmd) }
            .to raise_error(JwtService::Unauthorized)
        end
      end
    end

    context 'with the global `*` wildcard' do
      let(:claims) do
        described_class.decode!(
          encode_token(grants: [
            { app: 'pyworker', envs: [ '*' ], cmds: [ '*' ] }
          ])
        )
      end

      it 'still allows tasks (regression: `*` covers task:<name> too)' do
        expect { described_class.authorize!(claims: claims, app: 'pyworker', env: 'production', cmd: 'task:reindex') }
          .not_to raise_error
      end
    end

    context 'with legacy claim shape (apps/envs/cmds at the top level)' do
      it 'translates to a grant on the fly and allows tasks listed in cmds' do
        token, = described_class.encode(
          name: 'spec', apps: [ 'pyworker' ], envs: [ 'production' ], cmds: [ 'task:reindex' ]
        )
        claims = described_class.decode!(token)

        expect { described_class.authorize!(claims: claims, app: 'pyworker', env: 'production', cmd: 'task:reindex') }
          .not_to raise_error
      end
    end
  end

  describe '.grants_from_claims' do
    it 'flattens `tasks:` shorthand into the `cmds:` array' do
      claims = described_class.decode!(
        encode_token(grants: [
          { app: 'pyworker', envs: [ 'production' ], cmds: [ 'deploy' ], tasks: %w[sync reindex] }
        ])
      )

      grants = described_class.grants_from_claims(claims)
      expect(grants.first['cmds']).to contain_exactly('deploy', 'task:sync', 'task:reindex')
    end

    it 'deduplicates when both `cmds:` and `tasks:` reference the same task' do
      claims = described_class.decode!(
        encode_token(grants: [
          { app: 'pyworker', envs: [ 'production' ], cmds: [ 'task:sync' ], tasks: %w[sync] }
        ])
      )

      grants = described_class.grants_from_claims(claims)
      expect(grants.first['cmds']).to eq([ 'task:sync' ])
    end
  end
end
