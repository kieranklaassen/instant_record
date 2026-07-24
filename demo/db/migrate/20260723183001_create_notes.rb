class CreateNotes < ActiveRecord::Migration[8.1]
  # v1 of the notes table — the shape both runtimes start from. It lands in
  # db/schema.rb, which is what a fresh browser loads at boot, so this is the
  # only definition of "before" that the local database can ever have.
  def change
    create_table :notes, id: :string do |t|
      t.string :title, null: false
      t.text :body, null: false, default: ""
      t.integer :server_version, null: false, default: 0
      t.string :sync_state, null: false, default: "synced"
      t.timestamps
    end
  end
end
