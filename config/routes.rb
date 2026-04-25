# frozen_string_literal: true

Rails.application.routes.draw do
  # Liveness probe — no auth, returns 200 if the process is up.
  get '/healthz', to: proc { [ 200, { 'Content-Type' => 'text/plain' }, [ 'ok' ] ] }

  # Deploys
  resources :deploys, only: %i[index create show]

  # One-shot commands: restart / rollback / status
  resources :commands, only: %i[create]

  # User-defined tasks (capfire.yml `tasks:` section) + reserved built-in
  # `sync`. Independent per-app concurrency lock from /deploys, except that
  # `sync` cross-checks the deploy lock because it mutates git.
  resources :tasks, only: %i[index create show]

  # Token introspection — used by `capfire permission` to show the logged-in
  # user which apps/envs/cmds their token can act on.
  get '/tokens/me', to: 'tokens#me'

  # Standalone Load Balancer operations (no deploy attached).
  post '/lb/drain',   to: 'lb#drain'
  post '/lb/restore', to: 'lb#restore'
end
