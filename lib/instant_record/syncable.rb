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

      # Server-originated writes (jobs, console, seeds) are change-logged so
      # they stream to clients like any other change. Client mutations are
      # excluded — MutationApplier versions and logs those itself.
      before_create { self.server_version = 1 if instant_record_server_write? }
      before_update { self.server_version += 1 if instant_record_server_write? }
      after_create  { record_server_change("create") if instant_record_server_write? }
      after_update  { record_server_change("update") if instant_record_server_write? }
      after_destroy { record_server_change("destroy") if instant_record_server_write? }
    end

    class_methods do
      def instant_record_syncable? = true

      # Declare a bounded sync window: only the newest `limit` rows (per
      # `partition_by` value when given) sync to fresh clients; older rows
      # arrive on demand via InstantRecord.fetch_history and the browser
      # evicts beyond the window at boot. Models without a declaration keep
      # full sync.
      def sync_window(limit:, partition_by: nil)
        @instant_record_sync_window = InstantRecord::SyncWindow.new(self, limit: limit, partition_by: partition_by)
      end

      def instant_record_sync_window
        @instant_record_sync_window
      end

      # Observe a value from the server that last-write-wins threw away. The
      # block runs with the losing attribute hash at the moment it is dropped,
      # which is the only moment it exists in this runtime — the gem assigns
      # nothing, fires no callback, and keeps no copy.
      def on_discarded_change(&block)
        @instant_record_discarded_change_handler = block
      end

      def instant_record_discarded_change_handler
        @instant_record_discarded_change_handler
      end
    end

    private

    def instant_record_local_write?
      InstantRecord.browser? && !InstantRecord::Client.applying_remote?
    end

    def instant_record_server_write?
      !InstantRecord.browser? && !InstantRecord.applying_client_mutation?
    end

    def assign_instant_record_uuid
      self.id ||= SecureRandom.uuid
    end

    def record_outbox_mutation(operation)
      changes_payload =
        case operation
        when "create"  then InstantRecord.wire_attributes(attributes)
        when "update"  then InstantRecord.wire_attributes(saved_changes.transform_values(&:last))
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

    # Mirrors MutationApplier's log_change/log_destroy payload shapes.
    def record_server_change(operation)
      InstantRecord::Change.create!(
        record_type: self.class.name,
        record_id: id,
        operation: operation,
        version: operation == "destroy" ? 0 : self[:server_version],
        attributes_payload: operation == "destroy" ? {} : InstantRecord.wire_attributes(attributes)
      )
    end
  end
end
