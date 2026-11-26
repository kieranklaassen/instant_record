require "instant_record/action_replay"
require "instant_record/column_merge"
require "instant_record/outbox_upcaster"

module InstantRecord
  # Applies one client mutation authoritatively: record write, version bump,
  # change-log row, and idempotency-ledger row, in one transaction. This is
  # the server half of the sync protocol; the HTTP layer above it is thin.
  # A sync_action is replayed by ActionReplay instead.
  #
  # Conflict resolution uses server-anchored string-encoded HLCs (with extreme
  # forward clock skew clamped to server UTC) and 3-way column-level merging
  # (ColumnMerge): inspecting Change rows since `base_version` lets disjoint
  # concurrent column edits merge cleanly, while same-column collisions honor
  # declarative `sync_merge :col, :lww | :union | :server_wins` policies.
  class MutationApplier
    # A write the sender may not make. Raised inside the transaction, so
    # whatever the write did is rolled back with it.
    NotPermitted = Class.new(StandardError)

    # An update that found no row to change, as when a concurrent destroy
    # removed it. Active Record saves it without a complaint, and logging it
    # would bring the record back. Raised inside the transaction, as above.
    RowGone = Class.new(StandardError)

    # The flag Active Record decides its commit callbacks by: it stands until
    # the transaction the record was saved in ends.
    def self.row_updated?(record)
      record.send(:_trigger_update_callback)
    end

    ActionFrame = ActionReplay::Frame
    NON_DATA_COLUMNS = ColumnMerge::NON_DATA_COLUMNS
    MERGE_PREFIX = ColumnMerge::Notes::PREFIX

    # `identity` is the sender (SyncScope.identity). `partition` is the active
    # multi-tenant partition (SyncScope.partition), required by models that
    # declare `sync_partition`.
    def self.apply(mutation, identity = nil, partition = nil)
      new(mutation, identity, partition).apply
    end

    def initialize(mutation, identity = nil, partition = nil)
      @mutation = normalize_mutation(mutation)
      @mutation_id = @mutation[:mutation_id] || @mutation[:id]
      @changes = (@mutation[:changes] || {}).to_h
      @identity = identity
      @scope = SyncScope.token(identity)
      @partition = partition
    end

    # Replayed mutation ids return their original result without re-applying.
    def apply
      return replay_action if mutator_intent?

      @mutation, @changes = OutboxUpcaster.apply_global(@mutation, @changes)

      model = InstantRecord.synced_model(@mutation[:record_type])
      if model && (part = model.instant_record_sync_partition)
        part_value = part.extract(@partition)
        return { mutation_id: @mutation_id, status: "rejected", reason: "a partition is required" } unless part_value

        col = part.column
        if @changes.key?(col) && @changes[col].present? && @changes[col].to_s != part_value
          return { mutation_id: @mutation_id, status: "rejected", reason: "record not in active partition" }
        end
        existing_row = model.find_by(id: @mutation[:record_id])
        if existing_row && existing_row[col].to_s != part_value
          return { mutation_id: @mutation_id, status: "rejected", reason: "record not found" }
        end
      end

      if (existing = AppliedMutation.find_by(mutation_id: @mutation_id))
        return replayed(existing.result_payload.symbolize_keys)
      end

      return record_result(status: "rejected", reason: "unknown record type") unless model

      @changes = OutboxUpcaster.apply_for_model(model, @changes, @mutation)

      # Its own savepoint when a caller holds a transaction open, so a write
      # that is refused after it was made is undone either way.
      result = ActiveRecord::Base.transaction(requires_new: true) do
        InstantRecord.applying_client_mutation { perform(model) }
      end
      record_result(**result)
    rescue RowGone
      record_result(status: "rejected", reason: "record not found")
    rescue NotPermitted
      record_result(status: "rejected", reason: "not permitted", server_attributes: server_attributes_for(model))
    rescue ActiveRecord::RecordInvalid => e
      record_result(status: "rejected", reason: e.record.errors.full_messages.to_sentence,
        server_attributes: server_attributes_for(model))
    rescue ActiveRecord::RecordNotUnique
      # A create whose id already exists (e.g. a client replaying rows the
      # server already has). Rejecting lets the client roll back its local
      # copy instead of retrying the poisoned mutation forever; the server's
      # row comes back down through the change stream.
      record_result(status: "rejected", reason: "id already exists",
        server_attributes: server_attributes_for(model))
    rescue ActiveModel::UnknownAttributeError => e
      # Schema skew: this client is a migration ahead of this server and sent a
      # column that does not exist here. Rejecting is the only outcome that
      # cannot jam the queue.
      record_result(status: "rejected", reason: e.message,
        server_attributes: server_attributes_for(model))
    end

    private

    def normalize_mutation(mutation)
      hash = mutation.respond_to?(:to_unsafe_h) ? mutation.to_unsafe_h : mutation.to_h
      hash.symbolize_keys
    end

    def mutator_intent?
      @mutation[:mutator].present? || @mutation[:operation].to_s == "mutator"
    end

    def replay_action
      ActionReplay.new(@mutation, @mutation_id, identity: @identity, scope: @scope, partition: @partition).apply
    end

    def perform(model)
      # Partition ownership was verified before replay; stamp the column on
      # create and prevent moving it on update.
      if (part = model.instant_record_sync_partition)
        part_value = part.extract(@partition)
        col = part.column
        if @mutation[:operation] == "create"
          @changes = @changes.merge(col => part_value)
        else
          @changes = @changes.except(col)
        end
      end

      # A scoped model's rows are the sender's own: the scope column is never
      # taken from the client, and another scope's row is as good as absent.
      if (column = model.instant_record_sync_scope)
        return { status: "rejected", reason: "a scope is required" } unless @scope
        @changes = @changes.except(column)
        @changes[column] = @scope if @mutation[:operation] == "create"
        existing = model.find_by(id: @mutation[:record_id])
        return { status: "rejected", reason: "record not found" } if existing && existing[column] != @scope
      end

      # Enforce model-declared allowed mutation operations (e.g. append-only models).
      if (allowed_ops = model.instant_record_writable_operations)
        raise NotPermitted unless allowed_ops.include?(@mutation[:operation].to_s)
      end

      server_now = HLC.wall_now

      case @mutation[:operation]
      when "create"
        # An id that belongs to a record the sender cannot see is answered as
        # any other create it may not make, before the database can say "id
        # already exists" about a row the client was never shown.
        raise NotPermitted if hidden?(model)

        applied_hlc = resolve_incoming_hlc(server_now)
        safe_changes = clamp_updated_at(@changes, server_now, applied_hlc)

        record = model.new(safe_changes.merge("id" => @mutation[:record_id]))
        record.server_version = 1
        record.sync_state = "synced"
        record.save!
        permit!(model)
        HLC.receive(applied_hlc, now: server_now, node: HLC::SERVER_NODE)
        log_change(record, "create", hlc: applied_hlc)
        { status: "applied", version: record.server_version, hlc: applied_hlc }
      when "update"
        record = model.find_by(id: @mutation[:record_id])
        return { status: "rejected", reason: "record not found" } if record.nil? || hidden?(model)

        permit!(model)
        perform_update(model, record, server_now)
      when "destroy"
        record = model.find_by(id: @mutation[:record_id])
        # A hidden record answers as a missing one does, and is left alone. No
        # change is logged: a logged destroy would remove the record from the
        # browsers of the people who may see it.
        return { status: "applied" } if record && hidden?(model)

        permit!(model) if record
        applied_hlc = resolve_incoming_hlc(server_now)
        cascaded = record ? cascaded_destroys(record) { record.destroy! } : []
        cascaded.each { |other| other.send(:record_server_change, "destroy") }
        HLC.receive(applied_hlc, now: server_now, node: HLC::SERVER_NODE)
        log_destroy(model, record, hlc: applied_hlc)
        { status: "applied" }
      else
        { status: "rejected", reason: "unknown operation" }
      end
    end

    def perform_update(model, record, server_now)
      # Reject schema skew loudly before conflict filtering can mask an unknown column.
      candidate_attrs = @changes.except("id", "server_version")
      unknown = candidate_attrs.keys.reject { |attr| record.respond_to?("#{attr}=") }
      raise ActiveModel::UnknownAttributeError.new(record, unknown.first) if unknown.any?

      incoming_hlc = resolve_incoming_hlc(server_now)
      record_hlc = record_current_hlc(record)
      base_version = mutation_base_version
      user_columns = candidate_attrs.keys - NON_DATA_COLUMNS

      # Concurrent edits exist on the server since the client's base_version:
      # run 3-way column-level merging against the Change log.
      if base_version && base_version < record.server_version && user_columns.any?
        return perform_three_way_merge(model, record, user_columns, base_version, incoming_hlc, record_hlc, server_now)
      end

      # No concurrent version bump (or legacy caller with no base_version /
      # metadata-only touch): compare clamped HLCs.
      known_hlc = base_version && base_version >= record.server_version ? record_hlc : ColumnMerge::Notes.merge_clock(record, record_hlc, incoming_hlc)
      if known_hlc.present? && HLC.compare(incoming_hlc, known_hlc) < 0
        return skipped_result(record, record_hlc)
      end

      safe_changes = clamp_updated_at(candidate_attrs, server_now, incoming_hlc)
      record.assign_attributes(safe_changes)
      record.server_version += 1
      record.sync_state = "synced"
      save_update!(record)
      # Again after the write: a change of owner or audience must leave the
      # record somewhere the sender may still write.
      permit!(model)
      HLC.receive(incoming_hlc, now: server_now, node: HLC::SERVER_NODE)
      log_change(record, "update", hlc: incoming_hlc)
      { status: "applied", version: record.server_version, hlc: incoming_hlc }
    end

    def perform_three_way_merge(model, record, user_columns, base_version, incoming_hlc, record_hlc, server_now)
      merge = ColumnMerge.new(model, record, @changes, user_columns,
        base_version: base_version, incoming_hlc: incoming_hlc, record_hlc: record_hlc).resolve
      return skipped_result(record, record_hlc) if merge.winning.empty?

      merged_hlc = HLC.advance_past(record_hlc, incoming_hlc, now: server_now, node: HLC::SERVER_NODE)
      # The next edit of a client's own run keeps the client's clock, as the first
      # did: a server clock would outrank the edits still queued behind it.
      applied_hlc = merge.own_run? ? incoming_hlc : merged_hlc
      applied_time = HLC.physical_time(applied_hlc) || server_now

      record.assign_attributes(merge.winning)
      record.updated_at = [record.updated_at, applied_time].compact.max if record.respond_to?(:updated_at=)
      record.server_version += 1
      record.sync_state = "synced"
      save_update!(record)
      permit!(model)
      log_change(record, "update", hlc: applied_hlc)
      ColumnMerge::Notes.write(record, applied_hlc, from: incoming_hlc, merged: merged_hlc, columns: merge.uncontested)

      {
        status: "applied",
        version: record.server_version,
        merged: true,
        hlc: applied_hlc,
        server_attributes: InstantRecord.wire_attributes(record.attributes)
      }
    end

    # In a transaction of the model's own, which the save joins: a model in
    # another database would otherwise end its transaction with the save.
    def save_update!(record)
      record.transaction do
        record.save!
        raise RowGone unless self.class.row_updated?(record)
      end
    end

    def skipped_result(record, record_hlc)
      result = {
        status: "applied",
        version: record.server_version,
        skipped: true,
        server_attributes: InstantRecord.wire_attributes(record.attributes)
      }
      result[:hlc] = record_hlc if HLC.valid?(record_hlc)
      result
    end

    def mutation_base_version
      raw = @mutation[:base_version]
      return nil if raw.nil? || raw == ""

      raw.to_i
    end

    def resolve_incoming_hlc(server_now)
      if HLC.valid?(@mutation[:hlc])
        HLC.clamp(@mutation[:hlc], now: server_now)
      elsif @changes["updated_at"].present?
        parsed = parse_timestamp(@changes["updated_at"])
        if parsed
          HLC.clamp(HLC.from_time(parsed, node: HLC::LEGACY_NODE), now: server_now)
        else
          HLC.tick(now: server_now, node: HLC::SERVER_NODE)
        end
      else
        HLC.tick(now: server_now, node: HLC::SERVER_NODE)
      end
    end

    def record_current_hlc(record)
      stored = HLC.record_hlc(record.class.name, record.id)
      return stored if HLC.valid?(stored)

      HLC.from_time(record.updated_at, node: HLC::SERVER_NODE) if record.updated_at.present?
    end

    def clamp_updated_at(changes, server_now, reference_hlc)
      return changes unless changes["updated_at"].present?

      parsed = parse_timestamp(changes["updated_at"])
      return changes unless parsed

      if (parsed.utc - server_now) > HLC.max_drift
        clamped_time = HLC.physical_time(reference_hlc) || server_now
        changes.merge("updated_at" => clamped_time.utc.iso8601(InstantRecord::TIME_PRECISION))
      else
        changes
      end
    end

    def parse_timestamp(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def log_change(record, operation, hlc:)
      change = Change.create!(
        record_type: record.class.name,
        record_id: record.id,
        operation: operation,
        version: record.server_version,
        attributes_payload: InstantRecord.wire_attributes(record.attributes),
        scope: InstantRecord.scope_of(record),
        partition: InstantRecord.partition_of(record)
      )
      HLC.set_change_hlc(change.id, hlc)
      HLC.set_record_hlc(record.class.name, record.id, hlc)
    end

    def log_destroy(model, record, hlc:)
      change = Change.create!(
        record_type: model.name,
        record_id: @mutation[:record_id],
        operation: "destroy",
        version: 0,
        attributes_payload: {},
        scope: record && InstantRecord.scope_of(record),
        partition: record && InstantRecord.partition_of(record)
      )
      HLC.set_change_hlc(change.id, hlc)
      HLC.delete_record_hlc(model.name, @mutation[:record_id])
    end

    # The other synced records that destroying `target` took with it
    # (`dependent: :destroy`), in the order they went. They are logged once all
    # are gone, not as each one goes: the log takes the server clock's row, and
    # an edit of a later child would hold that child while it waits for it.
    def cascaded_destroys(target)
      previous = ActiveSupport::IsolatedExecutionState[:instant_record_cascaded_destroys]
      events = []
      ActiveSupport::IsolatedExecutionState[:instant_record_cascaded_destroys] = events
      yield
      # A callback may destroy a row in a savepoint it undoes, or create it
      # again: the last event that stands says whether the row is gone.
      last = events.reject { |event| event[:undone] }.reverse.uniq { |event| [event[:row].class, event[:row].id] }.reverse
      last.filter_map { |event| event[:row] if event[:gone] && event[:row] != target }
    ensure
      ActiveSupport::IsolatedExecutionState[:instant_record_cascaded_destroys] = previous
    end

    # The server's row as the sender may see it, for a client to roll back to.
    # Every rejection reads through here, so none carries a hidden record.
    def server_attributes_for(model)
      record = model && SyncScope.visible(model, @identity, partition: @partition).find_by(id: @mutation[:record_id])
      InstantRecord.wire_attributes(record.attributes) if record
    end

    # A stored answer, for whoever is asking now. The ledger knows a mutation
    # by its id alone, so a row it kept for the first sender is read again
    # through what this one may see.
    def replayed(result)
      model = InstantRecord.synced_model(@mutation[:record_type])
      return result unless result[:server_attributes] && model && SyncScope.scoped?(model)

      result.merge(server_attributes: server_attributes_for(model))
    end

    # The record exists and a `syncable_to` rule keeps it from the sender.
    def hidden?(model)
      model.instant_record_visibility && model.exists?(id: @mutation[:record_id]) &&
        !SyncScope.visible(model, @identity, partition: @partition).exists?(id: @mutation[:record_id])
    end

    # The record, as it stands inside this transaction, is one the sender may
    # write. A `sync_scope` / `sync_partition` column is settled before the write (see perform).
    def permit!(model)
      return unless model.instant_record_writability

      raise NotPermitted unless SyncScope.writable(model, @identity, partition: @partition).exists?(id: @mutation[:record_id])
    end

    def record_result(**result)
      AppliedMutation.record(@mutation_id, **result)
    end
  end
end
