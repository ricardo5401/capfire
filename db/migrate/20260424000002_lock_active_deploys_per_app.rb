# frozen_string_literal: true

# Replaces the (app, env) lock with a stricter (app) lock.
#
# Why: the cockpit is ONE git checkout per app. Even if two operations target
# different envs (production vs staging), they share the working directory —
# a concurrent `git checkout <branch>` would corrupt the other deploy.
# Different apps are fine: each has its own cockpit under /srv/apps/<app>.
class LockActiveDeploysPerApp < ActiveRecord::Migration[7.1]
  def change
    remove_index :deploys, name: 'idx_deploys_active_per_app_env', if_exists: true

    add_index :deploys, :app,
              unique: true,
              where: "status IN ('pending', 'running')",
              name: 'idx_deploys_active_per_app'
  end
end
