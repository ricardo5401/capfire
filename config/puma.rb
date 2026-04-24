# frozen_string_literal: true

# Puma config tuned for SSE streaming.
# Single worker, multiple threads — avoids buffering issues across workers.

max_threads = ENV.fetch('RAILS_MAX_THREADS', 16).to_i
min_threads = ENV.fetch('RAILS_MIN_THREADS', 4).to_i
threads min_threads, max_threads

port ENV.fetch('PORT', 3000)
environment ENV.fetch('RAILS_ENV', 'development')
pidfile ENV.fetch('PIDFILE', 'tmp/pids/server.pid')

# Keep workers at 1 — deploys are long-running and we don't want them
# balanced across workers (the in-memory Deploy stream dies with its worker).
workers ENV.fetch('WEB_CONCURRENCY', 1).to_i

# Generous timeout — deploys routinely exceed 5 minutes.
worker_timeout 3600

plugin :tmp_restart
