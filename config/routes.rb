# frozen_string_literal: true

Rails.application.routes.draw do
  # Liveness probe — no auth, returns 200 if the process is up.
  get '/healthz', to: proc { [ 200, { 'Content-Type' => 'text/plain' }, [ 'ok' ] ] }

  # Deploys
  resources :deploys, only: %i[index create show]

  # One-shot commands: restart / rollback / status
  resources :commands, only: %i[create]

  # Token introspection — used by `capfire permission` to show the logged-in
  # user which apps/envs/cmds their token can act on.
  get '/tokens/me', to: 'tokens#me'

  # Standalone Load Balancer operations (no deploy attached).
  post '/lb/drain',   to: 'lb#drain'
  post '/lb/restore', to: 'lb#restore'
end
