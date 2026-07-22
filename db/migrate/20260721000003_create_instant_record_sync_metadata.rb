class CreateInstantRecordSyncMetadata < ActiveRecord::Migration[8.1]
  def change
    create_table :instant_record_sync_metadata, id: false do |t|
      t.string :key, null: false, primary_key: true
      t.string :value
      t.timestamps
    end
  end
end
