class CreateChatUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_users, id: :string do |t|
      t.string :name, null: false
      t.string :handle, null: false
      t.boolean :bot, null: false, default: false
      t.integer :server_version, null: false, default: 0
      t.string :sync_state, null: false, default: "synced"
      t.timestamps
    end
  end
end
