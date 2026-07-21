class CreateIssues < ActiveRecord::Migration[8.1]
  def change
    create_table :issues, id: :string do |t|
      t.string :title, null: false
      t.string :state, null: false, default: "open"
      t.integer :server_version, null: false, default: 0
      t.string :sync_state, null: false, default: "synced"
      t.timestamps
    end
  end
end
