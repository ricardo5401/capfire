class RevokedToken < ApplicationRecord
  validates :jti, presence: true, uniqueness: true
  validates :revoked_at, presence: true

  def self.revoked?(jti)
    return false if jti.blank?

    where(jti: jti).exists?
  end
end
