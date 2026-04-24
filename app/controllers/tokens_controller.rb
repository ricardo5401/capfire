# frozen_string_literal: true

# Endpoints for introspecting the token that authenticated the current request.
#
# Used by the Go client's `capfire permission` subcommand to show the logged-in
# user WHAT they can do (per-app grants) without the user having to decode the
# JWT by hand.
#
# We never return the token itself or anything reversible — only the claims
# already present inside the JWT payload, enriched with DB metadata
# (`revoked_at`, `issued_at`) when available.
class TokensController < ApplicationController
  # GET /tokens/me
  def me
    record = ApiToken.find_by(jti: current_claims[:jti])

    render(json: {
      name: current_claims[:sub],
      jti: current_claims[:jti],
      grants: JwtService.grants_from_claims(current_claims),
      issued_at: timestamp_or(current_claims[:iat]),
      expires_at: timestamp_or(current_claims[:exp]),
      revoked: record&.revoked? || false,
      revoked_at: record&.revoked_at,
      known_locally: record.present?
    })
  end

  private

  # `authenticate_request!` from ApplicationController already validated the
  # JWT. `/tokens/me` intentionally does NOT call `authorize_action!` because
  # there is no app/env/cmd tuple to check — introspecting your own token is
  # available to any holder of a valid JWT.
  def timestamp_or(value)
    return nil if value.blank?

    Time.at(value.to_i).utc.iso8601
  end
end
