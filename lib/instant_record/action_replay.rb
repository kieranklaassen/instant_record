require "instant_record/sync_actions"

module InstantRecord
  # Replays one client sync_action authoritatively: the action's writes and its
  # idempotency-ledger row in one transaction, with the sender's permissions,
  # jobs held until commit, and, when it is refused, the server's rows as the
  # sender may see them.
  class ActionReplay
    # The frame a replayed action runs in, where an update that found no row to
    # change is the action's record not being found.
    class Frame < SyncActions::ServerFrame
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

    # `mutation` is the sent hash, with symbol keys. The rest is the sender's, as
    # MutationApplier holds it.
    def initialize(mutation, mutation_id, identity:, scope:, partition:)
      @mutation = mutation
      @mutation_id = mutation_id
      @identity = identity
      @scope = scope
      @partition = partition
    end

    # Replayed mutation ids return their original result without re-applying.
    # An error not rescued here is the caller's to answer.
    def apply
      if (existing = AppliedMutation.find_by(mutation_id: @mutation_id))
        return replayed(existing.result_payload.symbolize_keys)
      end

      mutator_name = @mutation[:mutator].to_s
      entry = SyncActions.resolve(mutator_name)
      return reject("unknown mutator") unless entry && allowed?(entry[:klass])

      SyncActions.install_active_job_guard!
      @frame = Frame.new(
        mutation_id: @mutation_id.to_s,
        identity: @identity,
        scope: @scope,
        partition: @partition,
        enforcing: true
      )
      args = SyncActions.normalize_args(@mutation[:args] || {})

      ActiveRecord::Base.transaction(requires_new: true) do
        InstantRecord.applying_client_mutation do
          SyncActions.with_server_frame(@frame) do
            authorize!(entry, args)
            SyncActions.dispatch(mutator_name, args)
          end
        end
        # A concurrent duplicate raises here, so its writes and jobs roll back.
        AppliedMutation.record!(@mutation_id, status: "applied", records: @frame.applied_records)
      end
    rescue MutationApplier::NotPermitted => e
      reject((e.message.nil? || e.message == e.class.name) ? "not permitted" : e.message)
    rescue MutationRejected => e
      reject(e.message)
    rescue ActiveRecord::RecordInvalid => e
      refs = touched_refs
      if e.record&.class&.respond_to?(:instant_record_syncable?) && e.record.class.instant_record_syncable? && e.record.id.present?
        refs += [[e.record.class.name, e.record.id]]
      end
      reject(e.record.errors.full_messages.to_sentence, refs)
    rescue ActiveRecord::RecordNotFound => e
      refs = touched_refs
      refs += [[e.model, e.id]] if e.respond_to?(:model) && e.model.present? && e.respond_to?(:id) && e.id.present?
      reject(e.message, refs)
    rescue ActiveRecord::RecordNotUnique
      if (existing = AppliedMutation.find_by(mutation_id: @mutation_id))
        return replayed(existing.result_payload.symbolize_keys)
      end

      reject("id already exists")
    rescue ArgumentError, ActiveModel::UnknownAttributeError => e
      reject(e.message)
    end

    private

    def allowed?(klass)
      return true unless InstantRecord.synced_models.any?
      return true unless klass.respond_to?(:instant_record_syncable?) && klass.instant_record_syncable?

      !InstantRecord.synced_model(klass.name).nil?
    end

    def authorize!(entry, args)
      authorizer = entry[:klass].instant_record_action_authorizer(entry[:action])
      return unless authorizer

      permitted =
        if authorizer.arity == 3 || authorizer.arity < -2
          authorizer.call(entry[:action], @identity, args)
        else
          authorizer.call(@identity, args)
        end
      raise MutationApplier::NotPermitted unless permitted
    end

    # What the action had read or written; nothing before it started.
    def touched_refs
      @frame&.touched_refs || []
    end

    def reject(reason, refs = touched_refs)
      AppliedMutation.record(@mutation_id, status: "rejected", reason: reason, records: visible_records_for(refs))
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
    def replayed(result)
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
  end
end
