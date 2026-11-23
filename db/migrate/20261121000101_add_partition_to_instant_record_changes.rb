class AddPartitionToInstantRecordChanges < ActiveRecord::Migration[8.1]
  # Which tenant/account partition this change belongs to, for models that
  # declare `sync_partition`. NULL is an unpartitioned model's change.
  def change
    add_column :instant_record_changes, :partition, :string
    add_index :instant_record_changes, [:partition, :id]
  end
end
