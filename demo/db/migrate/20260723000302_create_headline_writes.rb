class CreateHeadlineWrites < ActiveRecord::Migration[8.1]
  def change
    # Append-only ledger of every write that reached the contested headline in
    # one runtime. Not syncable (see HeadlineWrite): each runtime keeps its own.
    create_table :headline_writes do |t|
      t.string :text, null: false
      t.string :writer, null: false
      # The row's updated_at as of this write — the value last-write-wins
      # actually compares, not when this ledger row was inserted.
      t.datetime :written_at, null: false
      t.boolean :arrived_from_server, null: false, default: false
      t.timestamps
    end
  end
end
