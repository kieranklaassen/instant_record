class CreateChannels < ActiveRecord::Migration[8.1]
  def change
    create_table :channels, id: :string do |t|
      t.string :name, null: false
      t.string :kind, null: false, default: "channel"
      t.string :dm_user_id
      t.integer :server_version, null: false, default: 0
      t.string :sync_state, null: false, default: "synced"
      t.timestamps
    end
  end
end
