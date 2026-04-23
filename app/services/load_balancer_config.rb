# frozen_string_literal: true

# Immutable per-app, per-environment Cloudflare Load Balancer configuration.
# Built by AppConfig from the app's capfire.yml. `api_token` is sourced from
# the global ENV (CF_API_TOKEN) because it is a secret and should not live in
# per-app yaml checked into the repo.
class LoadBalancerConfig
  attr_reader :pool_id, :account_id, :origin, :api_token

  def initialize(pool_id:, origin:, account_id: nil, api_token: nil)
    @pool_id = pool_id
    @account_id = account_id
    @origin = origin
    @api_token = api_token.presence || ENV['CF_API_TOKEN'].presence
  end

  # True when every required piece to hit the Cloudflare API is present.
  def configured?
    api_token.present? && pool_id.present? && origin.present?
  end

  def inspect
    token_state = api_token ? '[set]' : '[missing]'
    "#<LoadBalancerConfig pool=#{pool_id} origin=#{origin} account=#{account_id} token=#{token_state}>"
  end
end
