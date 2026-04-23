class CreateApiTokens < ActiveRecord::Migration[7.1]
  def change
    create_table :api_tokens do |t|
      t.string :jti, null: false
      t.string :name, null: false
      t.text :apps, null: false, default: ''
      t.text :envs, null: false, default: ''
      t.text :cmds, null: false, default: ''
      t.datetime :issued_at, null: false
      t.datetime :expires_at
      t.datetime :revoked_at
      t.timestamps
    end

    add_index :api_tokens, :jti, unique: true
    add_index :api_tokens, :name
  end
end
