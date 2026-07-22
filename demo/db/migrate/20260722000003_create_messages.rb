class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages, id: :string do |t|
      t.string :channel_id, null: false
      t.string :chat_user_id, null: false
      t.text :body, null: false
      t.integer :server_version, null: false, default: 0
      t.string :sync_state, null: false, default: "synced"
      t.timestamps
    end
    add_index :messages, :channel_id
  end
end
