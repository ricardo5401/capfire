# frozen_string_literal: true

# Enforces at the DB layer that at most ONE deploy is `pending` or `running`
# for a given (app, env) combo at any time. Second concurrent attempts hit
# a unique violation and the controller translates that to HTTP 409 Conflict.
#
# Different apps or different envs deploy in parallel freely.
class AddUniqueActiveDeployIndex < ActiveRecord::Migration[7.1]
  def change
    add_index :deploys, %i[app env],
              unique: true,
              where: "status IN ('pending', 'running')",
              name: 'idx_deploys_active_per_app_env'
  end
end
