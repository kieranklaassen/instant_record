class CreateInstantRecordChanges < ActiveRecord::Migration[8.1]
  def change
    create_table :instant_record_changes do |t|
      t.string :record_type, null: false
      t.string :record_id, null: false
      t.string :operation, null: false
      t.integer :version, null: false, default: 0
      t.text :attributes_payload
      t.datetime :created_at, null: false
    end
    add_index :instant_record_changes, [:record_type, :record_id]
  end
end
