class CreateAuthNotes < ActiveRecord::Migration[8.1]
  # The Auth demo's notes. `audience` and `owner_id` are all the permission
  # rule reads (AuthNote's syncable_to and writable_by).
  def change
    create_table :auth_notes, id: :string do |t|
      t.string :title, null: false
      t.text :body, null: false, default: ""
      t.string :audience, null: false, default: "owner"
      t.string :owner_id, null: false
      t.integer :server_version, null: false, default: 0
      t.string :sync_state, null: false, default: "synced"
      t.timestamps
    end
  end
end
