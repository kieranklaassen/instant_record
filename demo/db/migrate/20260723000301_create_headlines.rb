class CreateHeadlines < ActiveRecord::Migration[8.1]
  def change
    create_table :headlines, id: :string do |t|
      t.string :text, null: false
      # Who claims the value the row currently holds. Part of the contested
      # row on purpose: it travels with the value over sync, so a client can
      # tell whose write it is looking at.
      t.string :writer, null: false
      t.integer :server_version, null: false, default: 0
      t.string :sync_state, null: false, default: "synced"
      t.timestamps
    end
  end
end
