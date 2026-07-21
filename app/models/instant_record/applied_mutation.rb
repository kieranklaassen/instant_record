module InstantRecord
  # Idempotency ledger: one row per mutation id ever processed, storing the
  # result so replays return the original outcome without re-applying.
  class AppliedMutation < ActiveRecord::Base
    self.table_name = "instant_record_applied_mutations"

    serialize :result_payload, coder: JSON
  end
end
