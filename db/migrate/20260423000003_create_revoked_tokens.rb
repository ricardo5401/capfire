class CreateRevokedTokens < ActiveRecord::Migration[7.1]
  def change
    create_table :revoked_tokens do |t|
      t.string :jti, null: false
      t.datetime :revoked_at, null: false
      t.string :reason
      t.timestamps
    end

    add_index :revoked_tokens, :jti, unique: true
  end
end
