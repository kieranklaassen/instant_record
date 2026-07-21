class CreateInstantRecordAppliedMutations < ActiveRecord::Migration[8.1]
  def change
    create_table :instant_record_applied_mutations do |t|
      t.string :mutation_id, null: false
      t.text :result_payload
      t.datetime :created_at, null: false
    end
    add_index :instant_record_applied_mutations, :mutation_id, unique: true
  end
end
