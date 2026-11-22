class CreateInstantRecordSyncNotices < ActiveRecord::Migration[8.1]
  def change
    create_table :instant_record_sync_notices, id: :string do |t|
      t.string :mutation_id
      t.string :kind, null: false
      t.string :record_type, null: false
      t.string :record_id, null: false
      t.string :operation, null: false
      t.string :reason, null: false, default: ""
      t.text :attempted_changes
      t.text :server_attributes
      t.integer :server_version, null: false, default: 0
      t.datetime :dismissed_at
      t.timestamps
    end

    add_index :instant_record_sync_notices, :mutation_id
    add_index :instant_record_sync_notices, [:dismissed_at, :created_at]
    add_index :instant_record_sync_notices, [:record_type, :record_id]
  end
end
