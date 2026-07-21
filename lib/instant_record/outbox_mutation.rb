module InstantRecord
  # Browser-local durable outbox. One row per write, created in the same
  # transaction as the record change. Drained in insertion order on sync.
  class OutboxMutation < ActiveRecord::Base
    self.table_name = "instant_record_outbox"

    serialize :changes_payload, coder: JSON

    before_create { self.id ||= SecureRandom.uuid }

    scope :ordered, -> { order(:created_at, :id) }

    def as_mutation
      {
        id: id,
        record_type: record_type,
        record_id: record_id,
        operation: operation,
        changes: changes_payload,
        base_version: base_version
      }
    end
  end
end
