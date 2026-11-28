# frozen_string_literal: true

require "digest"
require "instant_record/syncable"
require "instant_record/sync_partition"
require "instant_record/sync_shape"
require "instant_record/payload_batch"
require "instant_record/read_tracker_scan"

module InstantRecord
  module Syncable
    class_methods do
      # Which records the asker may be sent, for rules a single column cannot
      # say (`sync_scope` is the short form for "its owner's, or everyone's").
      # The block runs on the model, on the server only, with whatever
      # `InstantRecord.config.scope_from` returned for the request, and returns
      # a relation. Declare it inside `server_only`.
      #
      #   server_only do
      #     syncable_to { |user| user ? where(team_id: user.team_ids) : none }
      #   end
      def syncable_to(&block)
        @instant_record_visibility = block
      end

      # Which records the asker may create, change and delete. Without it,
      # what may be seen may be written. Pass `only:` (e.g. `only: :create`) to
      # restrict allowed mutation operations.
      def writable_by(only: nil, &block)
        @instant_record_writability = block if block
        sync_operations(*Array(only)) if only
      end

      # Restrict which mutation operations clients may apply to this model
      # (e.g. `sync_operations :create` for append-only models).
      def sync_operations(*operations)
        @instant_record_writable_operations = operations.flatten.map(&:to_s).freeze
      end

      # Declare a server-side query shape for windowed bootstrap, keyset history
      # paging, related rows, search widening, single-record lookup, and
      # background history-fill. Declare inside `server_only`.
      def sync_shape(**options)
        @instant_record_sync_shape = InstantRecord::SyncShape.new(self, **options)
      end

      # Authorize (and optionally prepare) a client-selected partition for this
      # model on the server. Runs with `(partition_value, identity)` or
      # `(partition_value, identity, request)`. Return falsey to forbid (403)
      # or raise `InstantRecord::Unauthorized` / `InstantRecord::Forbidden`.
      def authorize_partition(&block)
        @instant_record_partition_authorizer = block
      end

      def instant_record_visibility = @instant_record_visibility
      def instant_record_writability = @instant_record_writability || @instant_record_visibility
      def instant_record_writable_operations = @instant_record_writable_operations
      def instant_record_sync_shape = @instant_record_sync_shape
      def instant_record_partition_authorizer = @instant_record_partition_authorizer
    end
  end

  # Who may be sent what, and who may write what, on the four sync endpoints.
  # A model says so with `sync_scope :column`, `sync_partition :column`, or
  # `syncable_to` and `writable_by`; all are read through here. Server only:
  # none of this is in the browser build, which holds whatever the server chose
  # to send.
  module SyncScope
    RESET = "reset".freeze

    class << self
      # Run the host app's optional request authenticator (may raise
      # Unauthorized or Forbidden).
      def authenticate!(request)
        InstantRecord.config.authenticate_request&.call(request)
      end

      # Whoever `config.scope_from` says is asking. A string or nil suits
      # `sync_scope` columns; `syncable_to` blocks are handed it as it is.
      def identity(request)
        InstantRecord.config.scope_from.call(request)
      end

      # Which multi-tenant partition the request targets, or nil for an
      # unpartitioned sync session.
      def partition(request, identity = nil)
        resolver = InstantRecord.config.partition_from
        return nil unless resolver

        value = resolver.arity == 1 ? resolver.call(request) : resolver.call(request, identity)
        value.is_a?(String) ? value.presence : value
      end

      # The asker as a `sync_scope` column holds it.
      def token(identity)
        identity.to_s.presence
      end

      # A name for the asker that changes when the person behind a browser
      # does (sign in, sign out) or when the active partition changes.
      # Not a secret and not a credential: the server always scopes by the
      # request's own identity and partition.
      def key(identity, partition: nil)
        name =
          if identity.respond_to?(:sync_identity_key) then identity.sync_identity_key
          elsif identity.respond_to?(:id) then "#{identity.class.name}:#{identity.id}"
          else identity
          end
        base = name.to_s.presence || "anonymous"
        base = "#{base}|partition=#{partition}" if partition.present?
        Digest::SHA256.hexdigest(base)[0, 16]
      end

      # Whether the key a client bootstrapped under is no longer this request's
      # identity. A request that names no key is judged by who it is now: it is
      # a client that synced before keys existed, or no sync client at all.
      def stale?(sent_key, identity, partition: nil)
        sent_key.present? && sent_key != key(identity, partition: partition)
      end

      def partitioned?(model)
        !model.instant_record_sync_partition.nil?
      end

      def partition_value(model, partition_spec)
        model.instant_record_sync_partition&.extract(partition_spec)
      end

      def scoped?(model)
        !model.instant_record_sync_scope.nil? || !model.instant_record_visibility.nil? || partitioned?(model)
      end

      # Models participating in a sync pass for `partition_spec`:
      # - Unpartitioned session (nil): all models without `sync_partition`.
      # - Partitioned session: only `sync_partition` models matching `partition_spec`.
      def models_for(partition_spec)
        if partition_spec.nil?
          InstantRecord.syncable_models.reject { |model| partitioned?(model) }
        else
          InstantRecord.syncable_models.select do |model|
            partitioned?(model) && !partition_value(model, partition_spec).nil?
          end
        end
      end

      # Authorize a client's access to `partition_value` on `model`.
      # Raises `InstantRecord::Forbidden` when the model's `authorize_partition`
      # block returns falsey.
      def authorize_partition!(model, partition_value, identity, request = nil)
        authorizer = model.instant_record_partition_authorizer
        return true unless authorizer

        allowed =
          case authorizer.arity
          when 1 then model.instance_exec(partition_value, &authorizer)
          when 2 then model.instance_exec(partition_value, identity, &authorizer)
          else model.instance_exec(partition_value, identity, request, &authorizer)
          end
        raise InstantRecord::Forbidden, "partition not permitted" unless allowed

        true
      end

      # Authorize all partitioned models in `models` for `partition_spec`.
      def authorize_models!(models, partition_spec, identity, request = nil)
        return true if partition_spec.nil?

        models.each do |model|
          next unless partitioned?(model)

          value = partition_value(model, partition_spec)
          raise InstantRecord::Forbidden, "partition not permitted" if value.nil?

          authorize_partition!(model, value, identity, request)
        end
        true
      end

      # Change-log partition keys for `models` under `partition_spec`.
      # Empty array (or nil) selects unpartitioned changes (`partition IS NULL`).
      def change_partitions_for(models, partition_spec)
        return nil if partition_spec.nil?

        models.filter_map do |model|
          part = model.instant_record_sync_partition
          next unless part

          value = part.extract(partition_spec)
          part.change_key(value) if value
        end
      end

      def visible(model, identity, partition: nil)
        if model.instant_record_sync_scope.nil? && model.instant_record_sync_partition.nil? &&
           (visibility = model.instant_record_visibility)
          return model.instance_exec(identity, &visibility)
        end

        rows = model.instant_record_visible_to(token(identity))
        rows = apply_partition(model, rows, partition)
        both(model, rows, model.instant_record_visibility, identity)
      end

      def writable(model, identity, partition: nil)
        column = model.instant_record_sync_scope
        rows = column ? model.where(column => token(identity)) : model.all
        rows = apply_partition(model, rows, partition)
        both(model, rows, model.instant_record_writability, identity)
      end

      def scoped_types
        InstantRecord.syncable_models.select { |model| scoped?(model) }.map(&:name)
      end

      # The models a change of this identity's key empties in a browser: every
      # scoped one, unless the identity names them. An identity whose key
      # leaves part of itself out (the demo's leaves out the browser's own
      # token) says which models the rest decides.
      def reset_types(identity, partition: nil)
        return models_for(partition).map(&:name) if partition.present?

        identity.respond_to?(:sync_reset_types) ? identity.sync_reset_types : scoped_types
      end

      # The one event a stale client is sent. It names the types because the
      # browser build cannot know them.
      def reset_event(identity, partition: nil)
        { operation: RESET, types: reset_types(identity, partition: partition), identity: key(identity, partition: partition) }
      end

      # Change-log rows as the events one asker may receive, as [id, event]
      # pairs. The log already keeps a `sync_scope` model's changes to their
      # owner (Change.visible_to) and `sync_partition` changes to their
      # partition (Change.in_partition). A `syncable_to` model's rule can
      # depend on anything, so it is asked now: a change is sent with the
      # record's state as it stands, never the logged payload, which may
      # predate the record being shared. A record the asker may not see is sent
      # as an empty destroy: nothing to a client that never held it, a
      # revocation to one that did. Each event is a hash of its own, the
      # caller's to add to.
      def events_for(changes, identity, partition: nil)
        rows = changes.is_a?(Array) ? changes : changes.to_a
        len = rows.size
        return [] if len == 0

        # Each logged type is looked up once per batch, and never kept past it:
        # a reload, a new rule or InstantRecord.sync shows in the next one.
        models = {}
        last_type = nil
        last_model = false

        ids = Array.new(len)
        ops = Array.new(len)
        types = Array.new(len)
        record_ids = nil
        logged_ids = nil
        all_logged = true
        ruled_ids = nil

        i = 0
        while i < len
          change = rows[i]
          id = change.id
          op = change.operation
          type = change.record_type
          ids[i] = id
          ops[i] = op
          types[i] = type

          if op == "destroy"
            (logged_ids ||= []) << id unless all_logged
          else
            if type == last_type
              model = last_model
            else
              model = models[type]
              if model.nil?
                model = ruled_model(type) || false
                models[type] = model
              end
              last_type = type
              last_model = model
            end

            if model
              if all_logged
                all_logged = false
                logged_ids = ids[0, i] if i > 0
                record_ids = Array.new(len)
                ruled_ids = {}
              end
              rid = change.record_id
              record_ids[i] = rid
              (ruled_ids[type] ||= []) << rid
            elsif !all_logged
              (logged_ids ||= []) << id
            end
          end

          i += 1
        end

        if all_logged
          stamps = PayloadBatch.change_stamps_for_ids(ids)
          has_stamps = !stamps.empty?
          out = Array.new(len)
          i = 0
          while i < len
            change = rows[i]
            id = ids[i]
            event = {
              type: types[i],
              id: change.record_id,
              operation: ops[i],
              version: change.version,
              attributes: change.attributes_payload
            }
            if has_stamps && (stamp = stamps[id])
              event[:hlc] = stamp
            end
            out[i] = [id, event]
            i += 1
          end
          return out
        end

        payloads_by_type = visible_payloads(ruled_ids, models, identity, partition: partition)
        stamps = logged_ids ? PayloadBatch.change_stamps_for_ids(logged_ids) : nil
        has_stamps = stamps && !stamps.empty?

        out = Array.new(len)
        last_payload_type = nil
        last_payload_map = nil
        i = 0
        while i < len
          id = ids[i]
          op = ops[i]
          type = types[i]

          if op == "destroy" || !models[type]
            change = rows[i]
            event = {
              type: type,
              id: change.record_id,
              operation: op,
              version: change.version,
              attributes: change.attributes_payload
            }
            if has_stamps && (stamp = stamps[id])
              event[:hlc] = stamp
            end
          else
            if type == last_payload_type
              by_id = last_payload_map
            else
              by_id = payloads_by_type[type]
              last_payload_type = type
              last_payload_map = by_id
            end

            rid = record_ids[i]
            payload = by_id && by_id[rid]
            event =
              if payload
                if payload.frozen? || payload.key?(:operation)
                  copy = payload.dup
                  copy[:operation] = op
                  copy
                else
                  payload[:operation] = op
                  payload
                end
              else
                { type: type, id: rid, operation: "destroy", version: 0, attributes: {} }
              end
          end

          out[i] = [id, event]
          i += 1
        end
        out
      end

      private

      def apply_partition(model, rows, partition_spec)
        part = model.instant_record_sync_partition
        return rows unless part

        value = part.extract(partition_spec)
        return model.none if value.nil?

        part.scope_relation(rows, value)
      end

      # A column rule and a block rule both hold. As a subquery, since merging
      # two conditions on one column keeps only the second.
      def both(model, rows, block, identity)
        return rows unless block

        ruled = model.instance_exec(identity, &block)
        if model.instant_record_sync_scope || model.instant_record_sync_partition
          rows.where(model.primary_key => ruled.select(model.arel_table[model.primary_key]))
        else
          ruled
        end
      end

      # The model behind a logged type, when it has a `syncable_to` rule. Asked
      # of the class itself too: a model left out of `InstantRecord.sync` still
      # logs its changes, and its rule still decides who reads them.
      def ruled_model(type)
        model = InstantRecord.synced_model(type) || type.to_s.safe_constantize
        model if model.respond_to?(:instant_record_visibility) && model.instant_record_visibility
      end

      # One query per `syncable_to` model in the batch, routed through
      # `InstantRecord.record_payloads(relation)` so plain relations use the
      # direct result-row path without instantiating Active Record objects.
      def visible_payloads(ruled_ids, models, identity, partition: nil)
        found = {}
        ruled_ids.each do |type, rids|
          model = models[type]
          rids.uniq!
          list = nil
          model.connection_pool.with_connection do
            model.uncached do
              relation = visible(model, identity, partition: partition).where(model.primary_key => rids)
              list = InstantRecord.record_payloads(relation)
            end
          end
          next if list.empty?

          by_id = {}
          j = 0
          llen = list.size
          while j < llen
            payload = list[j]
            by_id[payload[:id]] = payload
            j += 1
          end
          found[type] = by_id
        end
        found
      end
    end
  end
end
