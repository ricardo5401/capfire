# frozen_string_literal: true

# Adds the `grants` column used by the new fine-grained claims model.
#
# A grant is a tuple `{ app, envs, cmds }`. A token carries a list of grants,
# and authorization succeeds if ANY grant matches the requested
# `{ app, env, cmd }`. This lets a single token grant
# `myapp-api: staging+production` AND `myapp: staging only` — impossible
# with the old cartesian `apps × envs × cmds` shape.
#
# Back-compat: `apps`, `envs`, `cmds` columns stay — tokens created before
# this migration keep working. `grants` is nullable and only set for new
# tokens.
class AddGrantsToApiTokens < ActiveRecord::Migration[7.1]
  def change
    add_column :api_tokens, :grants, :text
  end
end
