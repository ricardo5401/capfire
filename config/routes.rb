Rails.application.routes.draw do
  # Liveness probe — no auth, returns 200 if the process is up.
  get '/healthz', to: proc { [200, { 'Content-Type' => 'text/plain' }, ['ok']] }

  # Deploys
  resources :deploys, only: %i[create show]

  # One-shot commands: restart / rollback / status
  resources :commands, only: %i[create]
end
