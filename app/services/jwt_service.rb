# frozen_string_literal: true

require 'jwt'
require 'securerandom'

# Encodes, decodes and validates Capfire API tokens.
#
# Claims layout:
#   {
#     "sub":  "<human-readable token name>",
#     "jti":  "<uuid>",
#     "apps": ["app-a", "app-b"] | ["*"],
#     "envs": ["staging", "production"],
#     "cmds": ["deploy", "restart"],
#     "iat":  <unix timestamp>,
#     "exp":  <unix timestamp> | nil
#   }
class JwtService
  class Error < StandardError; end
  class InvalidToken < Error; end
  class RevokedToken < Error; end
  class ExpiredToken < Error; end
  class Unauthorized < Error; end

  WILDCARD = '*'

  class << self
    def encode(name:, apps:, envs:, cmds:, expires_at: nil, jti: SecureRandom.uuid, issued_at: Time.current)
      payload = {
        sub: name,
        jti: jti,
        apps: Array(apps),
        envs: Array(envs),
        cmds: Array(cmds),
        iat: issued_at.to_i
      }
      payload[:exp] = expires_at.to_i if expires_at

      token = ::JWT.encode(payload, secret, algorithm)
      [ token, payload.with_indifferent_access ]
    end

    # Returns a validated claims hash (with indifferent access) or raises.
    def decode!(token)
      raise InvalidToken, 'missing token' if token.blank?

      payload, _ = ::JWT.decode(token, secret, true, algorithms: [ algorithm ])
      claims = payload.with_indifferent_access

      raise RevokedToken, 'token is revoked' if claims[:jti] && ::RevokedToken.revoked?(claims[:jti])

      claims
    rescue ::JWT::ExpiredSignature
      raise ExpiredToken, 'token has expired'
    rescue ::JWT::DecodeError => e
      raise InvalidToken, e.message
    end

    # Raises Unauthorized if the claims do not permit {app:, env:, cmd:}.
    def authorize!(claims:, app:, env:, cmd:)
      raise Unauthorized, 'no claims' unless claims.is_a?(Hash)

      unless includes?(claims[:apps], app)
        raise Unauthorized, "token not allowed for app=#{app}"
      end

      unless includes?(claims[:envs], env)
        raise Unauthorized, "token not allowed for env=#{env}"
      end

      unless includes?(claims[:cmds], cmd)
        raise Unauthorized, "token not allowed for command=#{cmd}"
      end

      true
    end

    private

    def includes?(list, value)
      arr = Array(list)
      arr.include?(WILDCARD) || arr.include?(value)
    end

    def secret
      Capfire.config.jwt_secret
    end

    def algorithm
      Capfire.config.jwt_algorithm
    end
  end
end
