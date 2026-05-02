# frozen_string_literal: true

Rails.application.routes.draw do
  # Liveness probe — no auth, returns 200 if the process is up.
  get '/healthz', to: proc { [ 200, { 'Content-Type' => 'text/plain' }, [ 'ok' ] ] }

  # Deploys.
  #
  # The `abort` member action signals the running shell (process group) and
  # transitions the deploy to `canceled`. See AbortService for the kill
  # protocol (SIGTERM -> 10s grace -> SIGKILL) and authorization rules
  # (owner can always abort; others need `cmd: abort` on the app+env).
  resources :deploys, only: %i[index create show] do
    member do
      post :abort
    end
  end

  # One-shot commands: restart / rollback / status
  resources :commands, only: %i[create]

  # User-defined tasks (capfire.yml `tasks:` section) + reserved built-in
  # `sync`. Independent per-app concurrency lock from /deploys, except that
  # `sync` cross-checks the deploy lock because it mutates git.
  #
  # `abort` works the same way as the deploys version: same service, same
  # auth rules, same payload shape — clients can implement a single abort
  # path that just varies the URL.
  resources :tasks, only: %i[index create show] do
    member do
      post :abort
    end
  end

  # Token introspection — used by `capfire permission` to show the logged-in
  # user which apps/envs/cmds their token can act on.
  get '/tokens/me', to: 'tokens#me'

  # Standalone Load Balancer operations (no deploy attached).
  post '/lb/drain',   to: 'lb#drain'
  post '/lb/restore', to: 'lb#restore'
end
