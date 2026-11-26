module InstantRecord
  # Idempotency ledger: one row per mutation id ever processed, storing the
  # result so replays return the original outcome without re-applying.
  class AppliedMutation < ActiveRecord::Base
    self.table_name = "instant_record_applied_mutations"

    serialize :result_payload, coder: JSON

    # create_or_find_by leans on the unique index: a concurrent duplicate
    # returns the already-recorded result instead of applying twice.
    def self.record(mutation_id, **result)
      payload = result.merge(mutation_id: mutation_id)
      applied = create_or_find_by(mutation_id: mutation_id) do |row|
        row.result_payload = payload
      end
      applied.result_payload.symbolize_keys
    end

    # Raises RecordNotUnique on a concurrent duplicate, for a caller whose
    # savepoint must then roll back.
    def self.record!(mutation_id, **result)
      payload = result.merge(mutation_id: mutation_id)
      create!(mutation_id: mutation_id, result_payload: payload).result_payload.symbolize_keys
    end
  end
end
