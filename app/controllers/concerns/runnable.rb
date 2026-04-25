# frozen_string_literal: true

# Shared helpers for endpoints that drive a `DeployService` call:
#   - `run_streaming`: streams the lifecycle over SSE.
#   - `run_async`:     enqueues and returns 202 with a track URL.
#   - `render_busy`:   409 Conflict payload when another deploy is in-flight.
#
# Keeps `DeploysController` and `CommandsController` thin and identical in
# transport behavior. Concrete controllers only decide which params to pull
# and how to label the response.
module Runnable
  extend ActiveSupport::Concern

  private

  def run_streaming(service, subsystem:)
    prepare_sse_response!
    sse = SseWriter.new(response.stream)

    begin
      service.call { |event, payload| sse.event(event, payload) }
    rescue DeployService::Busy, TaskService::Busy
      sse.event(:error, message: 'another operation in progress for this app')
      sse.event(:done, exit_code: 1, status: 'failed', error: 'busy')
    rescue TaskService::DeployInFlight => e
      sse.event(:error, message: e.message)
      sse.event(:done, exit_code: 1, status: 'failed', error: 'deploy_in_flight')
    rescue StandardError => e
      Rails.logger.error("[#{subsystem}] #{e.class}: #{e.message}")
      sse.event(:error, message: "#{e.class}: #{e.message}")
      sse.event(:done, exit_code: 1, status: 'failed', error: e.message)
    ensure
      sse.close
    end
  end

  # `extra` is merged into the 202 JSON body. Callers pass app/env/branch/cmd
  # plus the human-readable `message` they want the caller to see.
  #
  # `resource:` selects whether the response uses `deploy_id` + `/deploys/:id`
  # tracking (default) or `task_run_id` + `/tasks/:id` tracking. Each
  # subsystem keeps its existing JSON contract — clients written for the
  # deploy endpoints don't need to learn the task vocabulary.
  def run_async(service, subsystem:, extra: {}, resource: :deploy)
    record = service.enqueue
    spawn_background(service, subsystem: subsystem)

    body = extra.merge(status: 'accepted', track_url: tracking_url(record.id, resource: resource))
    body[id_key_for(resource)] = record.id

    render(json: body, status: :accepted)
  end

  def spawn_background(service, subsystem:)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        service.call { |_event, _payload| }
      end
    rescue StandardError => e
      Rails.logger.error("[async-#{subsystem}] #{e.class}: #{e.message}")
    end
  end

  def tracking_url(record_id, resource: :deploy)
    base = ENV['CAPFIRE_PUBLIC_URL'].presence || request.base_url
    path = resource == :task ? 'tasks' : 'deploys'
    "#{base.sub(%r{/$}, '')}/#{path}/#{record_id}"
  end

  def id_key_for(resource)
    resource == :task ? :task_run_id : :deploy_id
  end

  def render_busy(active_deploy)
    render(json: {
      error: 'conflict',
      message: "another deploy is already in progress for #{active_deploy.app}:#{active_deploy.env}",
      active_deploy: {
        id: active_deploy.id,
        command: active_deploy.command,
        branch: active_deploy.branch,
        status: active_deploy.status,
        triggered_by: active_deploy.triggered_by,
        started_at: active_deploy.started_at
      },
      retry_after_seconds: 600
    }, status: :conflict)
  end
end
