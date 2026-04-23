class ApiToken < ApplicationRecord
  validates :jti, :name, presence: true
  validates :jti, uniqueness: true

  serialize :apps, coder: JSON
  serialize :envs, coder: JSON
  serialize :cmds, coder: JSON

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

  def as_summary_json
    {
      id: id,
      jti: jti,
      name: name,
      apps: apps,
      envs: envs,
      cmds: cmds,
      issued_at: issued_at,
      expires_at: expires_at,
      revoked: revoked?,
      revoked_at: revoked_at
    }
  end
end
