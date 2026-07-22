require "securerandom"

module InstantRecord
  # Makes a model local-first syncable. The same file loads in both runtimes:
  # in the browser (ruby.wasm) every write also records an outbox mutation in
  # the same local transaction; on the server the concern only provides the
  # shared column conventions (uuid ids, server_version, sync_state).
  module Syncable
    extend ActiveSupport::Concern

    included do
      extend InstantRecord::RuntimeScoped

      before_create :assign_instant_record_uuid

      # Guarded at call time, not include time, so the same class works in
      # both runtimes and tests can stub the runtime without re-including.
      # after_create/update/destroy run INSIDE the wrapping transaction
      # (unlike after_commit), which is what gives us write+outbox atomicity.
      before_save   { self.sync_state = "pending" if instant_record_local_write? }
      after_create  { record_outbox_mutation("create") if instant_record_local_write? }
      after_update  { record_outbox_mutation("update") if instant_record_local_write? }
      after_destroy { record_outbox_mutation("destroy") if instant_record_local_write? }
    end

    class_methods do
      def instant_record_syncable? = true
    end

    def sync_state
      self[:sync_state]
    end

    private

    def instant_record_local_write?
      InstantRecord.browser? && !InstantRecord::Client.applying_remote?
    end

    def assign_instant_record_uuid
      self.id ||= SecureRandom.uuid
    end

    def record_outbox_mutation(operation)
      changes_payload =
        case operation
        when "create"  then attributes.except("sync_state")
        when "update"  then saved_changes.transform_values(&:last).except("sync_state")
        when "destroy" then {}
        end

      InstantRecord::OutboxMutation.create!(
        record_type: self.class.name,
        record_id: id,
        operation: operation,
        changes_payload: changes_payload,
        base_version: self[:server_version] || 0
      )
    end
  end
end
