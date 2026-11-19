class CreateSharedInboxes < ActiveRecord::Migration[8.1]
  def change
    create_table :mailboxes, id: :string do |t|
      t.integer :revision, default: 0, null: false
    end
    create_table :mail_entries, id: :string do |t|
      t.string :mailbox_id, null: false
      t.string :author, null: false
      t.string :kind, null: false
      t.string :parent_id
      t.string :address
      t.string :subject
      t.text :body
      t.integer :server_version, default: 0, null: false
      t.string :sync_state, default: "synced", null: false
      t.timestamps
    end
    add_index :mail_entries, [:mailbox_id, :server_version]
    add_index :mail_entries, :parent_id
  end
end
