module InstantRecord
  # Browser-local durable outbox. One row per write, created in the same
  # transaction as the record change. Drained in insertion order on sync.
  class OutboxMutation < ActiveRecord::Base
    self.table_name = "instant_record_outbox"

    serialize :changes_payload, coder: JSON

    before_create { self.id ||= SecureRandom.uuid }
    after_destroy { InstantRecord::HLC.delete_mutation_hlc(id) }

    scope :ordered, -> { order(:created_at, :id) }

    def hlc
      InstantRecord::HLC.mutation_hlc(id)
    end

    def mutator?
      operation == "mutator"
    end

    def mutator_name
      changes_payload["mutator"] || record_id
    end

    def mutator_args
      changes_payload["args"] || {}
    end

    def touched_records
      Array(changes_payload["touched"])
    end

    def as_mutation
      if mutator?
        {
          id: id,
          mutation_id: id,
          operation: "mutator",
          record_type: record_type,
          mutator: mutator_name,
          args: mutator_args
        }
      else
        payload = {
          id: id,
          record_type: record_type,
          record_id: record_id,
          operation: operation,
          changes: changes_payload,
          base_version: base_version
        }
        if (stamp = hlc)
          payload[:hlc] = stamp
        end
        payload
      end
    end
  end
end
