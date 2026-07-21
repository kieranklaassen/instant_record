module InstantRecord
  class MutationsController < ActionController::API
    before_action :set_cors_headers

    def preflight
      head :no_content
    end

    # Accepts a batch of client mutations. Each mutation is applied in its own
    # transaction: record write + version bump + change-log row + ledger row.
    # Replayed mutation ids return their original result (R7).
    def create
      results = Array(params.require(:mutations)).map do |raw|
        apply_mutation(raw.permit(:id, :record_type, :record_id, :operation, :base_version, changes: {}))
      end

      render json: { results: results }
    end

    private

    # The demo PWA is served from a different origin (Vite dev server) than
    # the Rails sync server; auth is out of scope for the spike.
    def set_cors_headers
      headers["Access-Control-Allow-Origin"] = "*"
      headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
      headers["Access-Control-Allow-Headers"] = "Content-Type, Last-Event-ID"
    end

    def apply_mutation(mutation)
      if (existing = AppliedMutation.find_by(mutation_id: mutation[:id]))
        return existing.result_payload.symbolize_keys
      end

      model = InstantRecord.synced_model(mutation[:record_type])
      return record_result(mutation, status: "rejected", reason: "unknown record type") unless model

      result = ActiveRecord::Base.transaction do
        perform(model, mutation)
      end
      record_result(mutation, **result)
    rescue ActiveRecord::RecordInvalid => e
      record_result(mutation, status: "rejected", reason: e.record.errors.full_messages.to_sentence,
        server_attributes: server_attributes_for(model, mutation))
    end

    def perform(model, mutation)
      changes = (mutation[:changes] || {}).to_h

      case mutation[:operation]
      when "create"
        record = model.new(changes.merge("id" => mutation[:record_id]))
        record.server_version = 1
        record.sync_state = "synced"
        record.save!
        log_change(record, "create")
        { status: "applied", version: record.server_version }
      when "update"
        record = model.find_by(id: mutation[:record_id])
        return { status: "rejected", reason: "record not found" } unless record

        if stale?(record, changes)
          # Last-write-wins: an older concurrent write is acknowledged but skipped (R11).
          { status: "applied", version: record.server_version, skipped: true }
        else
          record.assign_attributes(changes.except("id", "server_version"))
          record.server_version += 1
          record.sync_state = "synced"
          record.save!
          log_change(record, "update")
          { status: "applied", version: record.server_version }
        end
      when "destroy"
        record = model.find_by(id: mutation[:record_id])
        record&.destroy!
        log_change_destroy(model, mutation[:record_id])
        { status: "applied" }
      else
        { status: "rejected", reason: "unknown operation" }
      end
    end

    def stale?(record, changes)
      incoming = changes["updated_at"]
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

    def log_change_destroy(model, record_id)
      Change.create!(
        record_type: model.name,
        record_id: record_id,
        operation: "destroy",
        version: 0,
        attributes_payload: {}
      )
    end

    def server_attributes_for(model, mutation)
      model&.find_by(id: mutation[:record_id])&.attributes&.except("sync_state")
    end

    def record_result(mutation, **result)
      payload = result.merge(mutation_id: mutation[:id])
      AppliedMutation.create!(mutation_id: mutation[:id], result_payload: payload)
      payload
    rescue ActiveRecord::RecordNotUnique
      AppliedMutation.find_by(mutation_id: mutation[:id]).result_payload.symbolize_keys
    end
  end
end
