module InstantRecord
  # Applies one client mutation authoritatively: record write, version bump,
  # change-log row, and idempotency-ledger row, in one transaction. This is
  # the server half of the sync protocol; the HTTP layer above it is thin.
  class MutationApplier
    # A write the sender may not make. Raised inside the transaction, so
    # whatever the write did is rolled back with it.
    NotPermitted = Class.new(StandardError)

    # `identity` is the sender (SyncScope.identity). `partition` is the active
    # multi-tenant partition (SyncScope.partition), required by models that
    # declare `sync_partition`.
    def self.apply(mutation, identity = nil, partition = nil)
      new(mutation, identity, partition).apply
    end

    def initialize(mutation, identity = nil, partition = nil)
      @mutation = mutation
      @changes = (mutation[:changes] || {}).to_h
      @identity = identity
      @scope = SyncScope.token(identity)
      @partition = partition
    end

    # Replayed mutation ids return their original result without re-applying.
    def apply
      model = InstantRecord.synced_model(@mutation[:record_type])
      if model && (part = model.instant_record_sync_partition)
        part_value = part.extract(@partition)
        return { mutation_id: @mutation[:id], status: "rejected", reason: "a partition is required" } unless part_value

        col = part.column
        if @changes.key?(col) && @changes[col].present? && @changes[col].to_s != part_value
          return { mutation_id: @mutation[:id], status: "rejected", reason: "record not in active partition" }
        end
        existing_row = model.find_by(id: @mutation[:record_id])
        if existing_row && existing_row[col].to_s != part_value
          return { mutation_id: @mutation[:id], status: "rejected", reason: "record not found" }
        end
      end

      if (existing = AppliedMutation.find_by(mutation_id: @mutation[:id]))
        return replayed(existing.result_payload.symbolize_keys)
      end

      return record_result(status: "rejected", reason: "unknown record type") unless model

      # Its own savepoint when a caller holds a transaction open, so a write
      # that is refused after it was made is undone either way.
      result = ActiveRecord::Base.transaction(requires_new: true) do
        InstantRecord.applying_client_mutation { perform(model) }
      end
      record_result(**result)
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

      case @mutation[:operation]
      when "create"
        # An id that belongs to a record the sender cannot see is answered as
        # any other create it may not make, before the database can say "id
        # already exists" about a row the client was never shown.
        raise NotPermitted if hidden?(model)

        record = model.new(@changes.merge("id" => @mutation[:record_id]))
        record.server_version = 1
        record.sync_state = "synced"
        record.save!
        permit!(model)
        log_change(record, "create")
        { status: "applied", version: record.server_version }
      when "update"
        record = model.find_by(id: @mutation[:record_id])
        return { status: "rejected", reason: "record not found" } if record.nil? || hidden?(model)

        permit!(model)

        if stale?(record)
          # Last-write-wins: an older concurrent write is acknowledged (there is
          # nothing to retry) but skipped. The row that won travels back with the
          # result, because a client told only "applied" badges the write it just
          # lost as synced. See Client#apply_results.
          { status: "applied", version: record.server_version, skipped: true,
            server_attributes: InstantRecord.wire_attributes(record.attributes) }
        else
          record.assign_attributes(@changes.except("id", "server_version"))
          record.server_version += 1
          record.sync_state = "synced"
          record.save!
          # Again after the write: a change of owner or audience must leave the
          # record somewhere the sender may still write.
          permit!(model)
          log_change(record, "update")
          { status: "applied", version: record.server_version }
        end
      when "destroy"
        record = model.find_by(id: @mutation[:record_id])
        # A hidden record answers as a missing one does, and is left alone. No
        # change is logged: a logged destroy would remove the record from the
        # browsers of the people who may see it.
        return { status: "applied" } if record && hidden?(model)

        permit!(model) if record
        record&.destroy!
        log_destroy(model, record)
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
        attributes_payload: InstantRecord.wire_attributes(record.attributes),
        scope: InstantRecord.scope_of(record),
        partition: InstantRecord.partition_of(record)
      )
    end

    def log_destroy(model, record)
      Change.create!(
        record_type: model.name,
        record_id: @mutation[:record_id],
        operation: "destroy",
        version: 0,
        attributes_payload: {},
        scope: record && InstantRecord.scope_of(record),
        partition: record && InstantRecord.partition_of(record)
      )
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
