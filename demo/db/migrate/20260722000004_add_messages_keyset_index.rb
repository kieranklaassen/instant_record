class AddMessagesKeysetIndex < ActiveRecord::Migration[8.1]
  def change
    # Keyset pagination and the sync window both order by
    # (channel_id, created_at, id); with thousands of backfill rows the
    # bare channel_id index no longer carries the sort.
    add_index :messages, [:channel_id, :created_at, :id]
  end
end
