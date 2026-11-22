class AddDelayLineToInstantRecordOutbox < ActiveRecord::Migration[8.1]
  # Optional delay-line fields for durable local undo windows: release_at holds
  # an outbox mutation from draining until it matures, and rollback_payload keeps
  # the pre-mutation local row snapshot for compensating restore on cancel.
  def change
    add_column :instant_record_outbox, :release_at, :datetime
    add_column :instant_record_outbox, :rollback_payload, :text
    add_index :instant_record_outbox, :release_at
  end
end
