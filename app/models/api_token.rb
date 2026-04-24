# frozen_string_literal: true

# Metadata for every JWT Capfire has emitted. We never store the token
# itself — only its claims in a queryable shape + the `jti` used by the
# revocation lookup.
#
# Two claim shapes coexist:
#   - Legacy: apps/envs/cmds (cartesian product semantics).
#   - Grants: list of `{ app, envs, cmds }` tuples with per-app granularity.
#
# `grants_list` hides the difference by always returning an Array<Hash>
# in the new shape — callers never have to branch on which form is in use.
class ApiToken < ApplicationRecord
  validates :jti, :name, presence: true
  validates :jti, uniqueness: true

  serialize :apps,   coder: JSON
  serialize :envs,   coder: JSON
  serialize :cmds,   coder: JSON
  serialize :grants, coder: JSON

  scope :active, -> { where(revoked_at: nil) }

  def revoked?
    revoked_at.present?
  end

  def revoke!(reason: nil)
    return false if revoked?

    transaction do
      update!(revoked_at: Time.current)
      RevokedToken.find_or_create_by!(jti: jti) do |rt|
        rt.revoked_at = Time.current
        rt.reason = reason
      end
    end
    true
  end

  # Returns the token's permissions as an Array<Hash> in the new shape,
  # regardless of which columns are populated. Use this everywhere you
  # need to render or reason about what the token can do.
  def grants_list
    if grants.present?
      Array(grants).map { |g| normalize_grant(g) }
    else
      legacy_to_grants
    end
  end

  def as_summary_json
    {
      id: id,
      jti: jti,
      name: name,
      grants: grants_list,
      issued_at: issued_at,
      expires_at: expires_at,
      revoked: revoked?,
      revoked_at: revoked_at
    }
  end

  private

  def normalize_grant(grant)
    hash = grant.respond_to?(:symbolize_keys) ? grant.symbolize_keys : grant.to_h.transform_keys(&:to_sym)
    {
      app: hash[:app].to_s,
      envs: Array(hash[:envs]).map(&:to_s),
      cmds: Array(hash[:cmds]).map(&:to_s)
    }
  end

  # Old shape: `apps: [a, b], envs: [staging, prod], cmds: [deploy]` means
  # the cartesian product of everything. Flatten it into one grant per app
  # so the UI can render a uniform table.
  def legacy_to_grants
    Array(apps).map do |app|
      {
        app: app.to_s,
        envs: Array(envs).map(&:to_s),
        cmds: Array(cmds).map(&:to_s)
      }
    end
  end
end
