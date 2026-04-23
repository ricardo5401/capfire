class CreateDeploys < ActiveRecord::Migration[7.1]
  def change
    create_table :deploys do |t|
      t.string :app, null: false
      t.string :env, null: false
      t.string :branch, null: false
      t.string :command, null: false, default: 'deploy'
      t.string :status, null: false, default: 'pending'
      t.integer :exit_code
      t.string :triggered_by
      t.string :token_jti
      t.datetime :started_at
      t.datetime :finished_at
      t.text :log, default: ''
      t.timestamps
    end

    add_index :deploys, %i[app env]
    add_index :deploys, :status
    add_index :deploys, :created_at
  end
end
