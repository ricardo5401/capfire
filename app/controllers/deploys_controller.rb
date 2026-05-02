# frozen_string_literal: true

# Endpoint for deploy lifecycle operations.
#
# Two modes:
#   - Streaming (default): returns text/event-stream with log lines in real
#     time. Connection stays open until the deploy finishes.
#   - Async (`async: true`): returns 202 Accepted with the deploy_id
#     immediately. The deploy runs in a background thread. Status can be
#     polled via GET /deploys/:id and Slack notifies on completion (if
#     enabled in the app's capfire.yml).
#
# Concurrency: only one active deploy (pending or running) is allowed per
# `app+env`. A second concurrent POST returns 409 Conflict with info about
# the in-flight deploy.
class DeploysController < ApplicationController
  include Runnable
  include Paginatable

  SUBSYSTEM = 'deploys#create'

  # GET /deploys
  #
  # By default, lists deploys triggered by the current token holder (`sub`
  # claim) — same posture the endpoint had before the team-visibility
  # change, so existing clients see no behavior diff.
  #
  # With `?all=true`, lists every deploy the token has visibility on: any
  # deploy whose `app` is in the token's `visible_apps` set (i.e. the app
  # appears in at least one grant, regardless of env or cmd). This is what
  # powers "I want to see what my teammate is deploying right now" without
  # us baking team rosters into Capfire.
  #
  # Filters:
  #   ?all=true       => switch from "mine only" to "anything I have access to"
  #   ?active=true    => only status in (pending, running)
  #   ?app=NAME       => filter by app (validated against visible_apps when
  #                      ?all=true; ignored otherwise — owners see their
  #                      deploys regardless of current grants)
  #   ?env=NAME       => filter by env
  #   ?status=NAME    => one of Deploy::STATUSES
  #   ?page=N         => 1-based page number (default 1)
  #   ?per_page=N     => rows per page (default 20, max 100)
  #   ?limit=N        => deprecated alias for `per_page`; honored when
  #                      `per_page` is missing so legacy curl scripts
  #                      keep working unchanged
  #
  # Response includes `scope` ("mine" or "all"), an optional `hint` and a
  # `pagination` object with page/per_page/total_count/total_pages so the
  # client can render "page 3 of 13" without a second request.
  def index
    all_mode = truthy?(params[:all])
    scope = build_index_scope(all_mode: all_mode)
    scope = apply_index_filters(scope, all_mode: all_mode)

    page_params = pagination_params
    paginated, meta = paginate(scope, **page_params)

    render(json: index_payload(paginated, all_mode: all_mode, meta: meta))
  end

  def create
    params.require(:app)
    params.require(:env)
    app    = safe_identifier!(params[:app], as: 'app', pattern: APP_PATTERN)
    env    = safe_identifier!(params[:env], as: 'env', pattern: ENV_PATTERN)
    branch = safe_branch!(params[:branch].presence || 'main')
    skip_lb = ActiveModel::Type::Boolean.new.cast(params[:skip_lb])
    async   = ActiveModel::Type::Boolean.new.cast(params[:async])

    authorize_action!(app: app, env: env, cmd: 'deploy')

    service = build_service(app: app, env: env, branch: branch, skip_lb: skip_lb)

    if async
      run_async(service, subsystem: SUBSYSTEM, extra: async_payload(app, env, branch))
    else
      run_streaming(service, subsystem: SUBSYSTEM)
    end
  rescue DeployService::Busy => e
    render_busy(e.active_deploy)
  end

  # GET /deploys/:id
  #
  # Returns the deploy record + its log when:
  #   - the caller is the original triggerer, OR
  #   - the caller's token has any grant on the deploy's app (visible_apps).
  #
  # The privacy posture is intentional: anyone with rights over the app
  # also sees the deploy logs, including secrets that might have leaked
  # into stack traces. Callers who don't want this should mint scoped
  # tokens (no grant on the noisy app) rather than rely on per-deploy
  # privacy. See the docs/server/permissions.md reasoning.
  def show
    deploy = Deploy.find_by(id: params[:id])
    return render(json: { error: 'not_found' }, status: :not_found) unless deploy
    return render_forbidden_visibility unless can_view?(deploy)

    render(json: deploy.as_status_json.merge(log: deploy.log))
  end

  # POST /deploys/:id/abort
  #
  # Cancels the deploy. Owner can always abort; others need `cmd: abort`
  # on the deploy's app+env. The actual kill protocol lives in
  # AbortService — this action only authorizes, dispatches, and renders.
  #
  # Returns 200 with the (possibly already-terminal) deploy payload plus
  # `abort_status` ("canceled" or "already_finished"). 404 when the deploy
  # doesn't exist; 403 when the caller can't abort it.
  def abort
    deploy = Deploy.find_by(id: params[:id])
    return render(json: { error: 'not_found' }, status: :not_found) unless deploy

    authorize_abort!(deploy)

    result = AbortService.new(
      record: deploy,
      requested_by: current_claims[:sub],
      reason: params[:reason].presence
    ).call

    render_abort_result(result)
  end

  private

  # Owner always sees their own deploy. Otherwise the deploy's app must
  # appear in the caller's visible_apps set (or the wildcard).
  def can_view?(deploy)
    return true if deploy.triggered_by.present? && deploy.triggered_by == current_claims[:sub]

    visible = JwtService.visible_apps(current_claims)
    visible.include?(JwtService::WILDCARD) || visible.include?(deploy.app)
  end

  def render_forbidden_visibility
    render(
      json: { error: 'forbidden', message: 'token has no access to this app' },
      status: :forbidden
    )
  end

  # Builds the base scope based on whether the caller asked for "mine" (the
  # default) or "everything I can see". The ?all flag is what powers the
  # team-visibility feature; without it the endpoint behaves exactly like
  # before.
  def build_index_scope(all_mode:)
    return Deploy.recent.where(triggered_by: current_claims[:sub]) unless all_mode

    visible = JwtService.visible_apps(current_claims)
    return Deploy.recent if visible.include?(JwtService::WILDCARD)

    Deploy.recent.where(app: visible.to_a)
  end

  # Applies optional filters. The `app` filter is validated against
  # visible_apps in `?all=true` mode so a caller can't poke at apps they
  # have no grant on. In "mine" mode the filter is also accepted (you can
  # always filter your own deploys) without the visibility check — owners
  # see their deploys regardless of current grants, since the deploy was
  # legitimately triggered with whatever permissions existed at that time.
  def apply_index_filters(scope, all_mode:)
    scope = scope.active if truthy?(params[:active])

    if params[:app].present?
      app = safe_identifier!(params[:app], as: 'app', pattern: APP_PATTERN)
      raise_if_app_not_visible!(app) if all_mode
      scope = scope.where(app: app)
    end

    if params[:env].present?
      scope = scope.where(env: safe_identifier!(params[:env], as: 'env', pattern: ENV_PATTERN))
    end

    if params[:status].present?
      raise InvalidParameter, 'invalid status' unless Deploy::STATUSES.include?(params[:status])

      scope = scope.where(status: params[:status])
    end

    scope
  end

  def raise_if_app_not_visible!(app)
    visible = JwtService.visible_apps(current_claims)
    return if visible.include?(JwtService::WILDCARD) || visible.include?(app)

    raise JwtService::Unauthorized, "token has no access to app=#{app}"
  end

  def index_payload(scope, all_mode:, meta:)
    payload = {
      deploys: scope.map(&:as_status_json),
      scope: all_mode ? 'all' : 'mine',
      pagination: meta
    }
    unless all_mode
      payload[:hint] = 'showing only your deploys; pass `all=true` to see ' \
                       'every deploy on apps you have access to'
    end
    payload
  end

  def build_service(app:, env:, branch:, skip_lb:)
    DeployService.new(
      app: app, env: env, branch: branch,
      command: 'deploy', skip_lb: skip_lb,
      triggered_by: current_claims[:sub],
      token_jti: current_claims[:jti]
    )
  end

  def async_payload(app, env, branch)
    {
      app: app,
      env: env,
      branch: branch,
      message: 'Deploy queued. Slack will notify on completion if enabled; poll the track_url for status.'
    }
  end

  def truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end
end
