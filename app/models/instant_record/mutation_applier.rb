require "json"
require "instant_record/outbox_upcaster"

module InstantRecord
  # Applies one client mutation authoritatively: record write, version bump,
  # change-log row, and idempotency-ledger row, in one transaction. This is
  # the server half of the sync protocol; the HTTP layer above it is thin.
  #
  # Conflict resolution uses server-anchored string-encoded HLCs (with extreme
  # forward clock skew clamped to server UTC) and 3-way column-level merging:
  # inspecting Change rows since `base_version` lets disjoint concurrent column
  # edits merge cleanly, while same-column collisions honor declarative
  # `sync_merge :col, :lww | :union | :server_wins` policies.
  class MutationApplier
    # A write the sender may not make. Raised inside the transaction, so
    # whatever the write did is rolled back with it.
    NotPermitted = Class.new(StandardError)

    # An update that found no row to change, as when a concurrent destroy
    # removed it. Active Record saves it without a complaint, and logging it
    # would bring the record back. Raised inside the transaction, as above.
    RowGone = Class.new(StandardError)

    # A replayed sync_action's frame, where such an update is the action's
    # record not being found.
    class ActionFrame < SyncActions::ServerFrame
      def finalize_update!(record)
        unless MutationApplier.row_updated?(record)
          model = record.class
          raise ActiveRecord::RecordNotFound.new(
            "Couldn't find #{model.name} with '#{model.primary_key}'=#{record.id.inspect}", model.name, model.primary_key, record.id
          )
        end

        super
      end
    end

    # The flag Active Record decides its commit callbacks by: it stands until
    # the transaction the record was saved in ends.
    def self.row_updated?(record)
      record.send(:_trigger_update_callback)
    end

    # Columns that carry bookkeeping/timestamps rather than user-edited fields.
    NON_DATA_COLUMNS = %w[id server_version sync_state created_at updated_at].freeze

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
      return apply_mutator if mutator_intent?

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

    # Authoritatively replay a custom sync_action inside one transaction with
    # AppliedMutation idempotency, unified auth, commit-guarded ActiveJob
    # enqueueing, and visible post-rollback server records on rejection.
    def apply_mutator
      if (existing = AppliedMutation.find_by(mutation_id: @mutation_id))
        return replayed_mutator(existing.result_payload.symbolize_keys)
      end

      mutator_name = @mutation[:mutator].to_s
      entry = SyncActions.resolve(mutator_name)
      unless entry && mutator_allowed?(entry[:klass])
        return record_result(status: "rejected", reason: "unknown mutator", records: [])
      end

      SyncActions.install_active_job_guard!
      frame = ActionFrame.new(
        mutation_id: @mutation_id.to_s,
        identity: @identity,
        scope: @scope,
        partition: @partition,
        enforcing: true
      )
      args = SyncActions.normalize_args(@mutation[:args] || {})

      ActiveRecord::Base.transaction(requires_new: true) do
        InstantRecord.applying_client_mutation do
          SyncActions.with_server_frame(frame) do
            authorize_action!(entry, args)
            SyncActions.dispatch(mutator_name, args)
          end
        end
        record_applied_mutator!(status: "applied", records: frame.applied_records)
      end
    rescue NotPermitted => e
      reason = (e.message.nil? || e.message == e.class.name) ? "not permitted" : e.message
      record_result(status: "rejected", reason: reason, records: visible_records_for(frame&.touched_refs || []))
    rescue MutationRejected => e
      record_result(status: "rejected", reason: e.message, records: visible_records_for(frame&.touched_refs || []))
    rescue ActiveRecord::RecordInvalid => e
      refs = (frame&.touched_refs || []).dup
      if e.record&.class&.respond_to?(:instant_record_syncable?) && e.record.class.instant_record_syncable? && e.record.id.present?
        refs << [e.record.class.name, e.record.id]
      end
      record_result(status: "rejected", reason: e.record.errors.full_messages.to_sentence,
        records: visible_records_for(refs))
    rescue ActiveRecord::RecordNotFound => e
      refs = (frame&.touched_refs || []).dup
      refs << [e.model, e.id] if e.respond_to?(:model) && e.model.present? && e.respond_to?(:id) && e.id.present?
      record_result(status: "rejected", reason: e.message, records: visible_records_for(refs))
    rescue ActiveRecord::RecordNotUnique
      if (existing = AppliedMutation.find_by(mutation_id: @mutation_id))
        return replayed_mutator(existing.result_payload.symbolize_keys)
      end

      record_result(status: "rejected", reason: "id already exists", records: visible_records_for(frame&.touched_refs || []))
    rescue ArgumentError, ActiveModel::UnknownAttributeError => e
      record_result(status: "rejected", reason: e.message, records: visible_records_for(frame&.touched_refs || []))
    end

    # Raises RecordNotUnique on concurrent duplicate mutation_id so the
    # wrapping savepoint rolls back duplicate domain writes and jobs.
    def record_applied_mutator!(**result)
      payload = result.merge(mutation_id: @mutation_id)
      record = AppliedMutation.create!(mutation_id: @mutation_id, result_payload: payload)
      record.result_payload.symbolize_keys
    end

    def mutator_allowed?(klass)
      return true unless InstantRecord.synced_models.any?
      return true unless klass.respond_to?(:instant_record_syncable?) && klass.instant_record_syncable?

      !InstantRecord.synced_model(klass.name).nil?
    end

    def authorize_action!(entry, args)
      authorizer = entry[:klass].instant_record_action_authorizer(entry[:action])
      return unless authorizer

      permitted =
        if authorizer.arity == 3 || authorizer.arity < -2
          authorizer.call(entry[:action], @identity, args)
        else
          authorizer.call(@identity, args)
        end
      raise NotPermitted unless permitted
    end

    # Authoritative post-rollback rows visible to the requester, so a rejected
    # mutator never leaks hidden records and gives the client exact server state.
    def visible_records_for(refs)
      seen = {}
      records = []
      refs.each do |type, id|
        next if type.nil? || id.nil?

        key = "#{type}:#{id}"
        next if seen[key]

        seen[key] = true
        model = InstantRecord.synced_model(type.to_s)
        next unless model

        record = SyncScope.visible(model, @identity, partition: @partition).find_by(id: id)
        records << InstantRecord.record_payload(record) if record
      end
      records
    end

    # Re-filter stored mutator result records through what this requester may
    # see, matching row-level replay privacy guarantees.
    def replayed_mutator(result)
      stored = result[:records]
      return result unless stored.is_a?(Array)

      filtered = stored.filter_map do |entry|
        rec = entry.stringify_keys
        model = InstantRecord.synced_model(rec["type"])
        next rec unless model && SyncScope.scoped?(model)

        if rec["operation"] == "destroy"
          nil
        else
          record = SyncScope.visible(model, @identity, partition: @partition).find_by(id: rec["id"])
          next unless record

          payload = InstantRecord.record_payload(record).deep_stringify_keys
          payload["operation"] = rec["operation"] if rec["operation"]
          payload
        end
      end

      result.merge(records: filtered)
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
      if record_hlc.present? && HLC.compare(incoming_hlc, record_hlc) < 0
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
      base_attrs, server_touched = inspect_changes_since(record, base_version, record_hlc)
      incoming_node = HLC.node(incoming_hlc)

      winning = {}
      user_columns.each do |col|
        col_info = server_touched[col]

        # Not a conflict when the server did not touch this column since base_version
        # (a disjoint concurrent edit), or when only this client node did and this write
        # is strictly newer: its sequential offline mutations share the same base_version
        # until the first one lands.
        if col_info.nil? || same_node_sequential?(incoming_node, incoming_hlc, col_info)
          winning[col] = @changes[col]
          next
        end

        incoming_wins = col_info[:hlc].nil? || HLC.compare(incoming_hlc, col_info[:hlc]) >= 0

        case model.instant_record_merge_policy(col)
        when :server_wins
          # Server's already-committed value wins on same-column collision.
        when :lww
          winning[col] = @changes[col] if incoming_wins
        when :union
          merged_val = merge_union(base_attrs[col], record.public_send(col), @changes[col], incoming_wins: incoming_wins)
          winning[col] = merged_val if merged_val != record.public_send(col)
        end
      end

      return skipped_result(record, record_hlc) if winning.empty?

      applied_hlc = HLC.advance_past(record_hlc, incoming_hlc, now: server_now, node: HLC::SERVER_NODE)
      applied_time = HLC.physical_time(applied_hlc) || server_now

      record.assign_attributes(winning)
      record.updated_at = [record.updated_at, applied_time].compact.max if record.respond_to?(:updated_at=)
      record.server_version += 1
      record.sync_state = "synced"
      save_update!(record)
      permit!(model)
      log_change(record, "update", hlc: applied_hlc)

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

    # Inspect Change rows since `base_version` to determine the base snapshot
    # and every column modified on the server since that version, along with
    # the HLC and contributing writer nodes for each modified column.
    def inspect_changes_since(record, base_version, record_hlc)
      record_changes = Change.where(record_type: record.class.name, record_id: record.id)
      base_change = record_changes.where(version: base_version).order(:id).last if base_version.positive?
      return [{}, every_column_touched(record, record_hlc)] unless base_change

      base_attrs = change_attributes(base_change)
      changes_since = record_changes
        .where("version > ?", base_version)
        .where.not(operation: "destroy")
        .order(:version, :id)
        .to_a

      hlc_map = HLC.change_hlcs(changes_since.map(&:id))
      server_touched = {}
      prev_attrs = base_attrs

      changes_since.each do |change|
        curr_attrs = change_attributes(change)
        c_hlc = hlc_map[change.id] || HLC.from_time(curr_attrs["updated_at"] || change.created_at, node: HLC::SERVER_NODE)
        touch_changed_columns(server_touched, prev_attrs, curr_attrs, hlc: c_hlc, node: HLC.node(c_hlc))
        prev_attrs = curr_attrs
      end

      # Catch any unlogged direct server column update (e.g. update_columns).
      live_attrs = InstantRecord.wire_attributes(record.attributes)
      touch_changed_columns(server_touched, prev_attrs, live_attrs, hlc: record_hlc, node: HLC::SERVER_NODE)

      [base_attrs, server_touched]
    end

    # Without a base to compare with, any column may have changed, and the
    # record's own clock is the only one known: the same answer for any column.
    def every_column_touched(record, record_hlc)
      # Read for its effect on the save: Rails looks for in-place changes only
      # in columns that have been read.
      record.attributes

      Hash.new({ hlc: record_hlc, nodes: [HLC.node(record_hlc)].compact })
    end

    def change_attributes(change)
      change.attributes_payload.is_a?(Hash) ? change.attributes_payload : {}
    end

    def touch_changed_columns(server_touched, prev_attrs, curr_attrs, hlc:, node:)
      ((curr_attrs.keys | prev_attrs.keys) - NON_DATA_COLUMNS).each do |col|
        next if curr_attrs[col] == prev_attrs[col]

        entry = (server_touched[col] ||= { nodes: [] })
        entry[:hlc] = hlc
        entry[:nodes] << node if node && !entry[:nodes].include?(node)
      end
    end

    def same_node_sequential?(incoming_node, incoming_hlc, col_info)
      return false if incoming_node.nil? || incoming_node == HLC::SERVER_NODE || incoming_node == HLC::LEGACY_NODE

      col_info[:nodes] == [incoming_node] &&
        col_info[:hlc].present? &&
        HLC.compare(incoming_hlc, col_info[:hlc]) > 0
    end

    # 3-way collection union for `sync_merge :col, :union`:
    #   - Arrays (native Postgres arrays, JSON/serialized arrays)
    #   - JSON-encoded array strings (e.g. '["a","b"]' in SQLite text columns)
    #   - Hashes / JSON objects (3-way key merge; LWW on colliding keys)
    #   - Comma-separated strings (e.g. "bug, urgent")
    def merge_union(base_val, server_val, client_val, incoming_wins:)
      if server_val.is_a?(Array) || client_val.is_a?(Array)
        return merge_array_union(base_val.is_a?(Array) ? base_val : [], Array(server_val), Array(client_val))
      end

      if server_val.is_a?(Hash) || client_val.is_a?(Hash)
        return merge_hash_union(
          base_val.is_a?(Hash) ? base_val : nil,
          server_val.is_a?(Hash) ? server_val : {},
          client_val.is_a?(Hash) ? client_val : {},
          incoming_wins: incoming_wins
        )
      end

      if json_string?(server_val, Array) || json_string?(client_val, Array)
        s_arr = parse_json(server_val, Array) || []
        c_arr = parse_json(client_val, Array) || []
        b_arr = parse_json(base_val, Array) || []
        return JSON.generate(merge_array_union(b_arr, s_arr, c_arr))
      end

      if json_string?(server_val, Hash) || json_string?(client_val, Hash)
        s_hash = parse_json(server_val, Hash) || {}
        c_hash = parse_json(client_val, Hash) || {}
        b_hash = parse_json(base_val, Hash)
        return JSON.generate(merge_hash_union(b_hash, s_hash, c_hash, incoming_wins: incoming_wins))
      end

      separator = server_val.to_s.include?(", ") || client_val.to_s.include?(", ") ? ", " : ","
      merged = merge_array_union(split_csv(base_val), split_csv(server_val), split_csv(client_val))
      merged.join(separator)
    end

    # An unknown base is an empty one: nothing can have been removed from it.
    def merge_array_union(base_arr, server_arr, client_arr)
      client_added = client_arr - base_arr
      client_removed = base_arr - client_arr
      (server_arr - client_removed) | client_added
    end

    def merge_hash_union(base_hash, server_hash, client_hash, incoming_wins:)
      merged = server_hash.dup
      if base_hash.nil?
        client_hash.each do |k, v|
          merged[k] = v if !merged.key?(k) || incoming_wins
        end
      else
        (base_hash.keys | client_hash.keys).each do |k|
          c_present = client_hash.key?(k)
          b_present = base_hash.key?(k)
          next if c_present == b_present && client_hash[k] == base_hash[k]

          s_changed = server_hash.key?(k) != b_present || server_hash[k] != base_hash[k]
          if !s_changed || incoming_wins
            c_present ? merged[k] = client_hash[k] : merged.delete(k)
          end
        end
      end
      merged
    end

    # A string that spells out a JSON Array or Hash.
    def json_string?(value, type)
      opening = type == Array ? "[" : "{"
      value.is_a?(String) && value.lstrip.start_with?(opening) && !parse_json(value, type).nil?
    end

    # The Array or Hash that `value` is or spells out in JSON, else nil.
    def parse_json(value, type)
      return nil if value.nil? || value == ""
      return value if value.is_a?(type)

      parsed = JSON.parse(value.to_s)
      parsed if parsed.is_a?(type)
    rescue JSON::ParserError
      nil
    end

    def split_csv(value)
      value.to_s.split(",").map(&:strip).reject(&:empty?)
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

    # create_or_find_by leans on the unique index: a concurrent duplicate
    # returns the already-recorded result instead of applying twice.
    def record_result(**result)
      payload = result.merge(mutation_id: @mutation_id)
      record = AppliedMutation.create_or_find_by(mutation_id: @mutation_id) do |applied|
        applied.result_payload = payload
      end
      record.result_payload.symbolize_keys
    end
  end
end
