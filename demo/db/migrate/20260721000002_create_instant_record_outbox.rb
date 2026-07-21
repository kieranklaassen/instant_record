class CreateInstantRecordOutbox < ActiveRecord::Migration[8.1]
  def change
    create_table :instant_record_outbox, id: :string do |t|
      t.string :record_type, null: false
      t.string :record_id, null: false
      t.string :operation, null: false
      t.text :changes_payload
      t.integer :base_version, null: false, default: 0
      t.timestamps
    end
  end
end
