# frozen_string_literal: true

require 'jwt'
require 'securerandom'

# Encodes, decodes and validates Capfire API tokens.
#
# New claim shape (preferred):
#   {
#     "sub":  "<human-readable token name>",
#     "jti":  "<uuid>",
#     "grants": [
#       { "app": "myapp",     "envs": ["staging"],               "cmds": ["deploy"] },
#       { "app": "myapp-api", "envs": ["staging", "production"], "cmds": ["deploy", "restart"] },
#       { "app": "pyworker",  "envs": ["production"],            "tasks": ["sync", "reindex"] }
#     ],
#     "iat": <unix>,
#     "exp": <unix> | nil
#   }
#
# `tasks:` is sugar for `cmds: ["task:sync", "task:reindex", ...]`. A grant
# can carry both `cmds:` and `tasks:` — they're merged. Authorization for a
# task always checks `cmd: "task:<name>"`, so writing `tasks: [...]` and
# `cmds: ["task:..."]` is exactly equivalent.
#
# Legacy claim shape (still accepted — tokens emitted before the redesign):
#   { "sub":..., "jti":..., "apps":[...], "envs":[...], "cmds":[...], "iat":..., "exp":... }
#
# When authorizing, the legacy shape is translated to grants on the fly
# (cartesian product semantics), so old tokens keep working unchanged.
class JwtService
  class Error < StandardError; end
  class InvalidToken < Error; end
  class RevokedToken < Error; end
  class ExpiredToken < Error; end
  class Unauthorized < Error; end

  WILDCARD = '*'

  class << self
    # Accepts EITHER `grants:` (new shape) OR `apps/envs/cmds` (legacy shape).
    # When both are given, `grants:` wins.
    def encode(name:, grants: nil, apps: nil, envs: nil, cmds: nil,
               expires_at: nil, jti: SecureRandom.uuid, issued_at: Time.current)
      payload_grants = coerce_grants(grants: grants, apps: apps, envs: envs, cmds: cmds)
      raise Error, 'token must have at least one grant' if payload_grants.empty?

      payload = {
        sub: name,
        jti: jti,
        grants: payload_grants,
        iat: issued_at.to_i
      }
      payload[:exp] = expires_at.to_i if expires_at

      token = ::JWT.encode(payload, secret, algorithm)
      [ token, payload.with_indifferent_access ]
    end

    # Returns a validated claims hash (with indifferent access) or raises.
    def decode!(token)
      raise InvalidToken, 'missing token' if token.blank?

      payload, = ::JWT.decode(token, secret, true, algorithms: [ algorithm ])
      claims = payload.with_indifferent_access

      if claims[:jti] && ::RevokedToken.revoked?(claims[:jti])
        raise RevokedToken, 'token is revoked'
      end

      claims
    rescue ::JWT::ExpiredSignature
      raise ExpiredToken, 'token has expired'
    rescue ::JWT::DecodeError => e
      raise InvalidToken, e.message
    end

    # Raises Unauthorized unless any grant in the claims permits
    # {app:, env:, cmd:}. Accepts new-shape `grants:` and legacy
    # `apps/envs/cmds` transparently.
    def authorize!(claims:, app:, env:, cmd:)
      raise Unauthorized, 'no claims' unless claims.is_a?(Hash)

      grants = grants_from_claims(claims)
      raise Unauthorized, 'token has no grants' if grants.empty?
      return true if grants.any? { |g| grant_matches?(g, app: app, env: env, cmd: cmd) }

      raise Unauthorized, "token not allowed for app=#{app} env=#{env} cmd=#{cmd}"
    end

    # Public helper used by TokensController#me and CLI listing so the
    # client sees the SAME grants shape no matter which encoding was used.
    def grants_from_claims(claims)
      return [] unless claims.is_a?(Hash)

      if claims[:grants].is_a?(Array)
        claims[:grants].filter_map { |g| normalize_grant(g) }
      else
        legacy_claims_to_grants(claims)
      end
    end

    private

    def coerce_grants(grants:, apps:, envs:, cmds:)
      return grants.map { |g| normalize_grant(g) }.compact if grants

      legacy_claims_to_grants('apps' => apps, 'envs' => envs, 'cmds' => cmds)
    end

    def legacy_claims_to_grants(claims)
      apps = Array(claims[:apps] || claims['apps'])
      envs = Array(claims[:envs] || claims['envs']).map(&:to_s)
      cmds = Array(claims[:cmds] || claims['cmds']).map(&:to_s)
      return [] if apps.empty? || envs.empty? || cmds.empty?

      apps.map { |app| normalize_grant('app' => app.to_s, 'envs' => envs, 'cmds' => cmds) }
    end

    def normalize_grant(grant)
      return nil if grant.blank?

      hash = grant.respond_to?(:with_indifferent_access) ? grant.with_indifferent_access : grant
      app  = hash['app'].to_s
      envs = Array(hash['envs']).map(&:to_s)
      cmds = combined_cmds(hash)
      return nil if app.empty? || envs.empty? || cmds.empty?

      { 'app' => app, 'envs' => envs, 'cmds' => cmds }
    end

    # Merges `cmds:` with the `tasks:` shorthand. Each entry in `tasks:`
    # expands to `task:<name>` so authorization (`cmd: "task:<name>"` from
    # the controller) finds it without having to know about the shorthand.
    # Duplicates are removed so a token using both forms doesn't end up
    # with redundant entries.
    def combined_cmds(hash)
      explicit = Array(hash['cmds']).map(&:to_s)
      tasks    = Array(hash['tasks']).map(&:to_s).reject(&:empty?).map { |t| "task:#{t}" }
      (explicit + tasks).uniq
    end

    def grant_matches?(grant, app:, env:, cmd:)
      grant = grant.with_indifferent_access if grant.respond_to?(:with_indifferent_access)
      grant_app  = grant['app'].to_s
      grant_envs = Array(grant['envs']).map(&:to_s)
      grant_cmds = Array(grant['cmds']).map(&:to_s)

      return false unless grant_app == WILDCARD || grant_app == app
      return false unless grant_envs.include?(WILDCARD) || grant_envs.include?(env)
      return false unless cmd_allowed?(grant_cmds, cmd)

      true
    end

    # `cmd` is allowed when:
    #   - the grant has the catch-all wildcard `*`, OR
    #   - the cmd is listed verbatim in the grant, OR
    #   - the cmd is a task (`task:<name>`) and the grant lists `task:*` —
    #     a useful "any task on this app/env" shorthand without granting
    #     deploy/restart/etc.
    TASK_WILDCARD = 'task:*'
    private_constant :TASK_WILDCARD

    def cmd_allowed?(grant_cmds, cmd)
      return true if grant_cmds.include?(WILDCARD)
      return true if grant_cmds.include?(cmd)
      return true if cmd.to_s.start_with?('task:') && grant_cmds.include?(TASK_WILDCARD)

      false
    end

    def secret
      Capfire.config.jwt_secret
    end

    def algorithm
      Capfire.config.jwt_algorithm
    end
  end
end
