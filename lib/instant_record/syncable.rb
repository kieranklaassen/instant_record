require "securerandom"

module InstantRecord
  # Makes a model local-first syncable. The same file loads in both runtimes:
  # in the compiled browser app every write also records an outbox mutation in
  # the same local transaction; on the server the concern only provides the
  # shared column conventions (uuid ids, server_version, sync_state).
  module Syncable
    extend ActiveSupport::Concern

    included do
      extend InstantRecord::RuntimeScoped
      extend InstantRecord::SyncActions::ClassMethods

      attr_accessor :hold_for
      attr_reader :last_outbox_mutation_id

      before_create :assign_instant_record_uuid

      # Guarded at call time, not include time, so the same class works in
      # both runtimes and tests can stub the runtime without re-including.
      # after_create/update/destroy run INSIDE the wrapping transaction
      # (unlike after_commit), which is what gives us write+outbox atomicity.
      before_save do
        if instant_record_local_write?
          if persisted? && InstantRecord::SyncActions.recording_client_mutator?
            InstantRecord::SyncActions.client_frame.capture_before(self, "update")
          end
          self.sync_state = "pending"
        end
      end
      before_destroy do
        if instant_record_local_write? && InstantRecord::SyncActions.recording_client_mutator?
          InstantRecord::SyncActions.client_frame.capture_before(self, "destroy")
        end
      end
      after_create do
        if instant_record_local_write?
          if InstantRecord::SyncActions.recording_client_mutator?
            InstantRecord::SyncActions.client_frame.record_create(self)
          else
            record_outbox_mutation("create")
          end
        end
      end
      after_update     { record_outbox_mutation("update") if instant_record_local_write? && !InstantRecord::SyncActions.recording_client_mutator? }
      after_destroy    { record_outbox_mutation("destroy") if instant_record_local_write? && !InstantRecord::SyncActions.recording_client_mutator? }
      after_validation { @hold_for = nil if errors.any? } if respond_to?(:after_validation)
      after_save       { @hold_for = nil }
      after_destroy    { @hold_for = nil }
      after_rollback   { @hold_for = nil } if respond_to?(:after_rollback)

      # Server-originated writes (jobs, console, seeds) are change-logged so
      # they stream to clients like any other change. Client row mutations are
      # excluded — MutationApplier versions and logs those itself. Server-replayed
      # sync_actions enforce SyncScope, bump versions, and log changes through
      # InstantRecord::SyncActions server hooks (no-ops in compiled builds).
      before_create do
        if instant_record_server_mutator_write?
          InstantRecord::SyncActions.server_authorize_create!(self)
          self.server_version = 1
          self.sync_state = "synced"
        elsif instant_record_server_write?
          self.server_version = 1
        end
      end
      before_update do
        if instant_record_server_mutator_write?
          InstantRecord::SyncActions.server_authorize_update_before!(self)
          self.server_version += 1
          self.sync_state = "synced"
        elsif instant_record_server_write?
          self.server_version += 1
        end
      end
      before_destroy do
        if instant_record_server_mutator_write?
          InstantRecord::SyncActions.server_authorize_destroy!(self)
        end
      end
      after_create do
        if instant_record_server_mutator_write?
          InstantRecord::SyncActions.server_finalize_create!(self)
        elsif instant_record_server_write?
          record_server_change("create")
        end
      end
      after_update do
        if instant_record_server_mutator_write?
          InstantRecord::SyncActions.server_finalize_update!(self)
        elsif instant_record_server_write?
          record_server_change("update")
        end
      end
      after_destroy do
        if instant_record_server_mutator_write?
          InstantRecord::SyncActions.server_finalize_destroy!(self)
        elsif instant_record_server_write?
          record_server_change("destroy")
        end
      end

      server_only do
        after_find do
          InstantRecord::SyncActions.server_note_read(self) if instant_record_server_mutator_write?
        end
      end
    end

    def destroy(hold_for: nil)
      return super() if hold_for.nil?

      @hold_for = nil
      previous = InstantRecord::Client.enter_hold(hold_for)
      begin
        super()
      ensure
        InstantRecord::Client.leave_hold(previous)
      end
    end

    def destroy!(hold_for: nil)
      return super() if hold_for.nil?

      @hold_for = nil
      previous = InstantRecord::Client.enter_hold(hold_for)
      begin
        super()
      ensure
        InstantRecord::Client.leave_hold(previous)
      end
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

      # Keep a model's rows to the client they belong to. `column` holds the
      # owner's scope, the value InstantRecord.config.scope_from reads off each
      # sync request: a client is sent the rows whose column equals its scope
      # and the rows where it is NULL, which belong to everyone. A create is
      # stamped with the sender's scope, and a row of another scope cannot be
      # changed or removed. Models without a declaration sync to every client.
      def sync_scope(column)
        @instant_record_sync_scope = column.to_s
      end

      def instant_record_sync_scope
        @instant_record_sync_scope
      end

      # The rows of this model a client with `scope` may be sent.
      def instant_record_visible_to(scope)
        column = instant_record_sync_scope
        column ? where(column => [nil, scope.presence].uniq) : all
      end

      # This record carries a file: bytes too large for a column, kept beside
      # the record and never inside it. In the browser they are written first
      # to the origin's private file system (frontend/files.js), so they are
      # there with no connection. They reach the server in the background, and
      # another device fetches them when it asks. The record is what syncs,
      # and its sync rules are the file's: who may be sent the record may read
      # its bytes, who may write it may send them. A file never changes: new
      # bytes are a new record. `max_size` is the most bytes the server takes
      # for one.
      def sync_file(max_size: nil, chunk_size: nil)
        @instant_record_sync_file = true
        @instant_record_file_max_size = max_size
        @instant_record_file_chunk_size = chunk_size
      end

      def instant_record_sync_file
        @instant_record_sync_file
      end

      def instant_record_file_max_size
        @instant_record_file_max_size
      end

      def instant_record_file_chunk_size
        @instant_record_file_chunk_size
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

      # Declare how same-column concurrent collisions resolve on this column:
      #   :lww         - last-write-wins by server-anchored HLC (default)
      #   :union       - 3-way set/collection union (arrays, JSON arrays, CSV, hashes)
      #   :server_wins - server's already-committed value wins on collision
      def sync_merge(column, policy)
        policy = policy.to_sym
        unless %i[lww union server_wins].include?(policy)
          raise ArgumentError, "Unknown sync_merge policy #{policy.inspect}; expected :lww, :union, or :server_wins"
        end

        @instant_record_merge_policies ||= {}
        @instant_record_merge_policies[column.to_s] = policy
      end

      def instant_record_merge_policies
        parent = superclass.respond_to?(:instant_record_merge_policies) ? superclass.instant_record_merge_policies : {}
        @instant_record_merge_policies ? parent.merge(@instant_record_merge_policies) : parent
      end

      def instant_record_merge_policy(column)
        instant_record_merge_policies[column.to_s] || :lww
      end
    end

    private

    def instant_record_local_write?
      InstantRecord.browser? && !InstantRecord::Client.applying_remote?
    end

    def instant_record_server_write?
      !InstantRecord.browser? && !InstantRecord.applying_client_mutation?
    end

    def instant_record_server_mutator_write?
      !InstantRecord.browser? && InstantRecord::SyncActions.enforcing_server_mutator?
    end

    def assign_instant_record_uuid
      return unless InstantRecord::Host.blank_id?(id)

      frame = InstantRecord::SyncActions.active_frame
      self.id = frame ? frame.next_uuid : SecureRandom.uuid
    end

    def record_outbox_mutation(operation)
      changes_payload =
        case operation
        when "create"  then InstantRecord.wire_attributes(attributes)
        when "update"  then InstantRecord.wire_attributes(saved_changes.transform_values(&:last))
        when "destroy" then {}
        end

      hlc = InstantRecord::HLC.tick
      hold = consume_hold_for
      release_at = hold ? Time.now.utc + hold : nil
      rollback_payload = release_at ? capture_rollback_payload(operation) : nil

      mutation = InstantRecord::OutboxMutation.create!(
        record_type: self.class.name,
        record_id: id,
        operation: operation,
        changes_payload: changes_payload,
        base_version: self[:server_version] || 0,
        release_at: release_at,
        rollback_payload: rollback_payload
      )
      InstantRecord::HLC.set_mutation_hlc(mutation.id, hlc)
      if operation == "destroy"
        InstantRecord::HLC.delete_row_hlc(self.class.name, id)
      else
        InstantRecord::HLC.set_row_hlc(self.class.name, id, hlc, force: true)
      end
      @last_outbox_mutation_id = mutation.id
    end

    def consume_hold_for
      raw = @hold_for
      @hold_for = nil
      raw = InstantRecord::Client.current_hold_for if raw.nil?
      return nil if raw.nil?

      seconds = raw.to_f
      raise ArgumentError, "hold_for must be non-negative" if seconds < 0.0
      return nil if seconds == 0.0

      seconds
    end

    def capture_rollback_payload(operation)
      case operation
      when "create"
        nil
      when "update"
        previous = attributes.merge(saved_changes.transform_values(&:first))
        InstantRecord.snapshot_attributes(previous)
      when "destroy"
        InstantRecord.snapshot_attributes(attributes)
      end
    end

    # Mirrors MutationApplier's log_change/log_destroy payload shapes.
    def record_server_change(operation)
      hlc = InstantRecord::HLC.tick(node: InstantRecord::HLC::SERVER_NODE)
      change = InstantRecord::Change.create!(
        record_type: self.class.name,
        record_id: id,
        operation: operation,
        version: operation == "destroy" ? 0 : self[:server_version],
        attributes_payload: operation == "destroy" ? {} : InstantRecord.wire_attributes(attributes),
        scope: InstantRecord.scope_of(self)
      )
      InstantRecord::HLC.set_change_hlc(change.id, hlc)
      if operation == "destroy"
        InstantRecord::HLC.delete_record_hlc(self.class.name, id)
      else
        InstantRecord::HLC.set_record_hlc(self.class.name, id, hlc)
      end
    end
  end
end
