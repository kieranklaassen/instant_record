class CreateAssistantChats < ActiveRecord::Migration[8.1]
  def change
    create_table :assistant_chats, id: :string do |t|
      t.string :title, null: false
      t.integer :server_version, null: false, default: 0
      t.string :sync_state, null: false, default: "synced"
      t.timestamps
    end

    create_table :assistant_turns, id: :string do |t|
      t.string :assistant_chat_id, null: false
      t.text :prompt, null: false
      t.text :reply, null: false, default: ""
      # Who is asked: "server" (Rails, through RubyLLM) or "local" (the browser's own model).
      t.string :engine, null: false, default: "server"
      # Who answered, as the page shows it.
      t.string :author, null: false, default: ""
      t.integer :server_version, null: false, default: 0
      t.string :sync_state, null: false, default: "synced"
      t.timestamps
    end
    add_index :assistant_turns, [:assistant_chat_id, :created_at, :id]
  end
end
