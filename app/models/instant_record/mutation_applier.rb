module InstantRecord
  # Applies one client mutation authoritatively: record write, version bump,
  # change-log row, and idempotency-ledger row, in one transaction. This is
  # the server half of the sync protocol; the HTTP layer above it is thin.
  class MutationApplier
    def self.apply(mutation)
      new(mutation).apply
    end

    def initialize(mutation)
      @mutation = mutation
      @changes = (mutation[:changes] || {}).to_h
    end

    # Replayed mutation ids return their original result without re-applying.
    def apply
      if (existing = AppliedMutation.find_by(mutation_id: @mutation[:id]))
        return existing.result_payload.symbolize_keys
      end

      model = InstantRecord.synced_model(@mutation[:record_type])
      return record_result(status: "rejected", reason: "unknown record type") unless model

      result = ActiveRecord::Base.transaction do
        InstantRecord.applying_client_mutation { perform(model) }
      end
      record_result(**result)
    rescue ActiveRecord::RecordInvalid => e
      record_result(status: "rejected", reason: e.record.errors.full_messages.to_sentence,
        server_attributes: server_attributes_for(model))
    end

    private

    def perform(model)
      case @mutation[:operation]
      when "create"
        record = model.new(@changes.merge("id" => @mutation[:record_id]))
        record.server_version = 1
        record.sync_state = "synced"
        record.save!
        log_change(record, "create")
        { status: "applied", version: record.server_version }
      when "update"
        record = model.find_by(id: @mutation[:record_id])
        return { status: "rejected", reason: "record not found" } unless record

        if stale?(record)
          # Last-write-wins: an older concurrent write is acknowledged but skipped.
          { status: "applied", version: record.server_version, skipped: true }
        else
          record.assign_attributes(@changes.except("id", "server_version"))
          record.server_version += 1
          record.sync_state = "synced"
          record.save!
          log_change(record, "update")
          { status: "applied", version: record.server_version }
        end
      when "destroy"
        record = model.find_by(id: @mutation[:record_id])
        record&.destroy!
        log_destroy(model)
        { status: "applied" }
      else
        { status: "rejected", reason: "unknown operation" }
      end
    end

    def stale?(record)
      incoming = @changes["updated_at"]
      incoming.present? && record.updated_at.present? && Time.zone.parse(incoming.to_s) < record.updated_at
    end

    def log_change(record, operation)
      Change.create!(
        record_type: record.class.name,
        record_id: record.id,
        operation: operation,
        version: record.server_version,
        attributes_payload: record.attributes.except("sync_state")
      )
    end

    def log_destroy(model)
      Change.create!(
        record_type: model.name,
        record_id: @mutation[:record_id],
        operation: "destroy",
        version: 0,
        attributes_payload: {}
      )
    end

    def server_attributes_for(model)
      model&.find_by(id: @mutation[:record_id])&.attributes&.except("sync_state")
    end

    # create_or_find_by leans on the unique index: a concurrent duplicate
    # returns the already-recorded result instead of applying twice.
    def record_result(**result)
      payload = result.merge(mutation_id: @mutation[:id])
      record = AppliedMutation.create_or_find_by(mutation_id: @mutation[:id]) do |applied|
        applied.result_payload = payload
      end
      record.result_payload.symbolize_keys
    end
  end
end
