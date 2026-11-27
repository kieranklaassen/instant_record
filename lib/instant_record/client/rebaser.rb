require "json"
require "time"

module InstantRecord
  module Client
    # GGPO-style dirty-row state manager.
    #
    # Persists a lightweight server-confirmed snapshot in SyncMetadata STRICTLY
    # for rows that currently have unacked outbox mutations. Clean rows carry
    # zero snapshot rows. When server truth arrives (via SSE/poll delta, ack,
    # LWW skip, 3-way column merge, rejection, or poison-pill quarantine), a
    # dirty row is rewound in memory to its confirmed server state, updated with
    # server truth, and deterministically replayed through its remaining unacked
    # mutations (or custom replay mutators). Once a row's last outbox mutation
    # clears, its confirmed snapshot is immediately deleted.
    module Rebaser
      CONFIRMED_PREFIX = "confirmed_row:".freeze
      SKIP_REPLAY_COLUMNS = %w[id server_version sync_state created_at updated_at].freeze

      class << self
        def snapshot_key(record_type, record_id)
          "#{CONFIRMED_PREFIX}#{record_type}:#{record_id}"
        end

        def confirmed_snapshot(record_type, record_id)
          raw = SyncMetadata.get(snapshot_key(record_type, record_id))
          return nil if raw.nil? || raw.empty?

          JSON.parse(raw)
        rescue JSON::ParserError
          nil
        end

        def write_confirmed_snapshot(record_type, record_id, snapshot)
          SyncMetadata.set(snapshot_key(record_type, record_id), JSON.generate(snapshot))
        end

        def clear_confirmed_snapshot(record_type, record_id)
          SyncMetadata.delete(snapshot_key(record_type, record_id))
        end

        def confirmed_snapshot_count
          count = 0
          SyncMetadata.all.each do |entry|
            count += 1 if entry.key.start_with?(CONFIRMED_PREFIX)
          end
          count
        end

        def pending_for(record_type, record_id)
          OutboxMutation.where(record_type: record_type, record_id: record_id).ordered.to_a
        end

        def dirty?(record_type, record_id)
          OutboxMutation.where(record_type: record_type, record_id: record_id).limit(1).to_a.any?
        end

        # Capture the server-confirmed row state right before a clean row
        # transitions to dirty. Called inside the same transaction as the local
        # record write and outbox insert, so rollbacks undo it atomically.
        # +creating+ is positional here and in Syncable's callbacks: as a keyword on a
        # concern's method, the browser's compiler types it as a Hash and every local
        # write raises TypeError.
        def capture_before_local_write(model, record_id, creating)
          record_type = model.name
          return if dirty?(record_type, record_id) && confirmed_snapshot(record_type, record_id)

          snapshot =
            if creating
              { "exists" => false, "version" => 0, "hlc" => nil, "attributes" => nil, "initial_attributes" => nil }
            else
              existing = model.find_by(id: record_id)
              if existing
                wire = InstantRecord.wire_attributes(existing.attributes)
                {
                  "exists" => true,
                  "version" => existing[:server_version] || 0,
                  "hlc" => HLC.row_hlc(record_type, record_id),
                  "attributes" => wire,
                  "initial_attributes" => wire
                }
              else
                { "exists" => false, "version" => 0, "hlc" => nil, "attributes" => nil, "initial_attributes" => nil }
              end
            end

          write_confirmed_snapshot(record_type, record_id, snapshot)
        end

        # Reconcile one resolved outbox mutation against its row without
        # clobbering newer unacked local edits on the same row.
        def reconcile_mutation_result(mutation, result, record_delta: false)
          record_type = mutation.record_type
          record_id = mutation.record_id
          model = InstantRecord.synced_model(record_type)
          snapshot = confirmed_snapshot(record_type, record_id)

          HLC.receive(result["hlc"]) if HLC.valid?(result["hlc"])
          authoritative = result["skipped"] || result["merged"] || result["status"] == "rejected" || result["server_attributes"].present?

          # A server change that came in before this result with a later version was
          # made after it: the snapshot is the server's newer word on the row.
          overtaken = overtaken?(snapshot, result)
          plain = result["status"] == "applied" && !authoritative

          updated_snapshot =
            case result["status"]
            when "applied"
              if overtaken
                plain ? acknowledge_in_snapshot(snapshot, mutation, result["hlc"], model) : snapshot
              elsif authoritative
                authoritative_snapshot(snapshot, result)
              else
                advance_confirmed_snapshot(snapshot, mutation, result["version"], model, hlc: result["hlc"])
              end
            when "rejected"
              overtaken ? snapshot : authoritative_snapshot(snapshot, result, fallback_missing: true)
            else
              snapshot
            end

          mutation_hlc = mutation.hlc
          mutation.destroy!
          remaining = pending_for(record_type, record_id)

          if remaining.empty?
            clear_confirmed_snapshot(record_type, record_id)
            return false unless model

            if plain && !overtaken
              if mutation.operation == "destroy"
                HLC.delete_row_hlc(record_type, record_id)
              else
                record = model.find_by(id: record_id)
                record&.update_columns(sync_state: "synced", server_version: result["version"] || record.server_version)
                # The server may have clamped this write's clock. A row still carrying the
                # clock the write was made with takes the server's, or later server changes
                # would look stale. A server change that came in before this ack is in the
                # row too, so its clock in the snapshot counts; one of this client's own,
                # never clamped, does not. A newer clock the row got since is kept.
                own_stamp = HLC.row_hlc(record_type, record_id) == mutation_hlc
                server_hlc = result["hlc"]
                if own_stamp && updated_snapshot
                  confirmed_hlc = updated_snapshot["hlc"]
                  server_hlc = confirmed_hlc if HLC.valid?(confirmed_hlc) && HLC.node(confirmed_hlc) != HLC.node(mutation_hlc)
                end
                HLC.set_row_hlc(record_type, record_id, server_hlc, force: own_stamp) if HLC.valid?(result["hlc"])
              end
              false
            else
              return false unless updated_snapshot

              !!materialize_state(model, record_id, updated_snapshot, remaining: [], force_hlc: true, record_delta: record_delta)
            end
          else
            write_confirmed_snapshot(record_type, record_id, updated_snapshot) if updated_snapshot
            return false unless model && updated_snapshot

            rebased = replay_onto_confirmed(model, record_id, updated_snapshot, remaining)
            !!materialize_state(model, record_id, rebased, remaining: remaining, force_hlc: authoritative, record_delta: record_delta)
          end
        end

        # Reconcile a poison-pilled or cancelled mutation removed from the
        # outbox. Rewinds to the last confirmed snapshot and replays any
        # remaining unacked mutations on that row. Returns whether visible
        # local record data changed.
        def reconcile_quarantined_mutation(mutation, record_delta: false)
          record_type = mutation.record_type
          record_id = mutation.record_id
          model = InstantRecord.synced_model(record_type)
          snapshot = confirmed_snapshot(record_type, record_id)

          mutation.destroy!
          remaining = pending_for(record_type, record_id)

          if remaining.empty?
            clear_confirmed_snapshot(record_type, record_id)
            return false unless model && snapshot

            !!materialize_state(model, record_id, snapshot, remaining: [], force_hlc: true, record_delta: record_delta)
          else
            return false unless model && snapshot

            rebased = replay_onto_confirmed(model, record_id, snapshot, remaining)
            !!materialize_state(model, record_id, rebased, remaining: remaining, force_hlc: true, record_delta: record_delta)
          end
        end

        # Apply an incoming server delta (from SSE, poll, bootstrap, or
        # history) to a currently dirty row: update its confirmed snapshot with
        # server truth, rewind in memory, and deterministically replay all
        # remaining unacked local mutations. Returns whether the visible local
        # row changed.
        def apply_server_delta(model, record_id, operation:, attributes:, version:, hlc: nil, record_delta: false)
          record_type = model.name
          HLC.receive(hlc) if HLC.valid?(hlc)
          incoming_hlc = HLC.valid?(hlc) ? hlc : nil

          remaining = pending_for(record_type, record_id)
          snapshot = confirmed_snapshot(record_type, record_id) ||
            { "exists" => false, "version" => 0, "hlc" => nil, "attributes" => nil, "initial_attributes" => nil }

          if operation == "destroy"
            updated_snapshot = {
              "exists" => false,
              "version" => 0,
              "hlc" => nil,
              "attributes" => nil,
              "initial_attributes" => snapshot["initial_attributes"]
            }
            write_confirmed_snapshot(record_type, record_id, updated_snapshot)
            rebased = replay_onto_confirmed(model, record_id, updated_snapshot, remaining)
            return materialize_state(model, record_id, rebased, remaining: remaining, force_hlc: true, record_delta: record_delta)
          end

          return false unless attributes

          sliced = attributes.deep_stringify_keys.slice(*model.column_names)
          incoming_at = parse_timestamp(sliced["updated_at"])
          confirmed_at = parse_timestamp(snapshot["attributes"] && snapshot["attributes"]["updated_at"])
          confirmed_hlc = snapshot["hlc"]

          if snapshot["exists"] && stale_against?(incoming_hlc, confirmed_hlc, incoming_at, confirmed_at)
            notify_discarded_if_different(model, record_id, sliced)
            return false
          end

          updated_snapshot = {
            "exists" => true,
            "version" => version || sliced["server_version"] || snapshot["version"] || 0,
            "hlc" => incoming_hlc || confirmed_hlc,
            "attributes" => sliced,
            "initial_attributes" => snapshot["initial_attributes"],
            "delivered" => true
          }
          write_confirmed_snapshot(record_type, record_id, updated_snapshot)

          rebased = replay_onto_confirmed(model, record_id, updated_snapshot, remaining)
          changed = materialize_state(model, record_id, rebased, remaining: remaining, force_hlc: true, record_delta: record_delta)

          # Preserve on_discarded_change semantics when a newer local unacked
          # edit shadowed incoming remote values.
          final_at = parse_timestamp(rebased["attributes"] && rebased["attributes"]["updated_at"])
          final_hlc = rebased["hlc"]
          if stale_against?(incoming_hlc, final_hlc, incoming_at, final_at) && shadowed_by_local?(sliced, rebased["attributes"])
            model.instant_record_discarded_change_handler&.call(sliced)
          end

          changed
        end

        def reset_types(types)
          return if types.empty?

          SyncMetadata.all.each do |entry|
            next unless entry.key.start_with?(CONFIRMED_PREFIX)

            rest = entry.key[CONFIRMED_PREFIX.length..]
            record_type = rest.split(":", 2).first
            entry.destroy if types.include?(record_type)
          end
        end

        private

        def overtaken?(snapshot, result)
          return false unless snapshot && snapshot["exists"] == true && snapshot["delivered"] == true

          # A rejection gives its version in the attributes only.
          version = result["version"]
          version = result["server_attributes"]["server_version"] if version.nil? && result["server_attributes"].present?
          return false if version.nil?

          snapshot["version"].to_i > version.to_i
        end

        # The snapshot holds the acknowledged write already. Its columns count as known
        # from here on, so the edits still queued on them replay as they did before. Its
        # clock may be this client's own, never clamped: the acknowledgement's counts then.
        def acknowledge_in_snapshot(snapshot, mutation, result_hlc, model)
          changes = (mutation.changes_payload || {}).deep_stringify_keys.except("id", "server_version", "sync_state")
          initial = (snapshot["initial_attributes"] || {}).deep_stringify_keys.merge(changes)
          initial = initial.slice(*model.column_names) if model
          hlc = max_valid_hlc(snapshot["hlc"], result_hlc)
          hlc = result_hlc if HLC.valid?(result_hlc) && HLC.node(hlc) == HLC.node(mutation.hlc)
          {
            "exists" => true,
            "version" => snapshot["version"],
            "hlc" => hlc,
            "attributes" => snapshot["attributes"],
            "initial_attributes" => initial,
            "delivered" => true
          }
        end

        def advance_confirmed_snapshot(snapshot, mutation, version, model, hlc: nil)
          next_hlc = max_valid_hlc(snapshot && snapshot["hlc"], hlc)
          case mutation.operation
          when "destroy"
            { "exists" => false, "version" => 0, "hlc" => nil, "attributes" => nil, "initial_attributes" => nil }
          when "create"
            attrs = (mutation.changes_payload || {}).deep_stringify_keys.merge("id" => mutation.record_id)
            attrs = attrs.slice(*model.column_names) if model
            existing_initial = snapshot && snapshot["initial_attributes"]
            {
              "exists" => true,
              "version" => version || 1,
              "hlc" => next_hlc,
              "attributes" => attrs,
              "initial_attributes" => existing_initial || attrs
            }
          when "update"
            base =
              if snapshot && snapshot["exists"] && snapshot["attributes"]
                snapshot["attributes"].deep_stringify_keys
              elsif model && (existing = model.find_by(id: mutation.record_id))
                InstantRecord.wire_attributes(existing.attributes)
              else
                { "id" => mutation.record_id }
              end
            changes = (mutation.changes_payload || {}).deep_stringify_keys.except("id", "server_version", "sync_state")
            base_at = parse_timestamp(base["updated_at"])
            mut_at = parse_timestamp(changes["updated_at"])
            merged = base.merge(changes)
            # Never rewind confirmed updated_at backwards below a newer concurrent server delta.
            merged["updated_at"] = base["updated_at"] if base_at && mut_at && mut_at < base_at
            merged = merged.slice(*model.column_names) if model
            # Preserve initial_attributes on untouched columns so a concurrent server delta
            # on another column stays recognized while remaining local mutations replay.
            initial =
              if snapshot && snapshot["initial_attributes"]
                updated_initial = snapshot["initial_attributes"].deep_stringify_keys.merge(changes)
                model ? updated_initial.slice(*model.column_names) : updated_initial
              else
                merged
              end
            {
              "exists" => true,
              "version" => version || (snapshot && snapshot["version"]) || 0,
              "hlc" => next_hlc,
              "attributes" => merged,
              "initial_attributes" => initial
            }
          else
            snapshot
          end
        end

        def authoritative_snapshot(snapshot, result, fallback_missing: false)
          if result["server_attributes"].present?
            attrs = result["server_attributes"].deep_stringify_keys
            hlc = HLC.valid?(result["hlc"]) ? result["hlc"] : (snapshot && snapshot["hlc"])
            {
              "exists" => true,
              "version" => result["version"] || attrs["server_version"] || (snapshot && snapshot["version"]) || 0,
              "hlc" => hlc,
              "attributes" => attrs,
              "initial_attributes" => snapshot ? snapshot["initial_attributes"] : nil
            }
          elsif fallback_missing
            {
              "exists" => false,
              "version" => 0,
              "hlc" => nil,
              "attributes" => nil,
              "initial_attributes" => snapshot ? snapshot["initial_attributes"] : nil
            }
          else
            snapshot
          end
        end

        # Pure in-memory GGPO replay: start from server-confirmed state and
        # deterministically apply each remaining unacked mutation in order.
        def replay_onto_confirmed(model, record_id, confirmed, remaining)
          exists = confirmed["exists"] == true
          confirmed_attrs = exists ? (confirmed["attributes"] || {}).deep_stringify_keys.slice(*model.column_names) : nil
          state_attrs = confirmed_attrs ? confirmed_attrs.dup : nil
          initial_attrs = confirmed["initial_attributes"] ? confirmed["initial_attributes"].deep_stringify_keys.slice(*model.column_names) : nil
          confirmed_version = confirmed["version"].to_i
          confirmed_hlc = HLC.valid?(confirmed["hlc"]) ? confirmed["hlc"] : nil
          state_hlc = confirmed_hlc
          confirmed_at = parse_timestamp(confirmed_attrs && confirmed_attrs["updated_at"])
          replay_handler = model.instant_record_replay_mutation_handler

          remaining.each do |mutation|
            mut_hlc = mutation.hlc
            if replay_handler
              record = build_in_memory_record(model, record_id, exists ? state_attrs : nil, confirmed_version)
              handled = replay_handler.call(record, mutation)
              if handled == :destroy
                exists = false
                state_attrs = nil
                state_hlc = nil
                next
              elsif handled && handled != :default
                exists = true
                updated = InstantRecord.wire_attributes(record.attributes).slice(*model.column_names)
                updated.delete("created_at") if updated["created_at"].nil?
                state_attrs = (state_attrs || {}).merge(updated)
                state_hlc = max_valid_hlc(state_hlc, mut_hlc)
                next
              end
            end

            changes = (mutation.changes_payload || {}).deep_stringify_keys.slice(*model.column_names)
            mut_at = parse_timestamp(changes["updated_at"])

            case mutation.operation
            when "destroy"
              exists = false
              state_attrs = nil
              state_hlc = nil
            when "create"
              if !exists
                exists = true
                state_attrs = changes.merge("id" => record_id)
                state_hlc = max_valid_hlc(state_hlc, mut_hlc)
              else
                replayed = apply_replayed_columns!(state_attrs, changes,
                  mut_hlc: mut_hlc, confirmed_hlc: confirmed_hlc,
                  mut_at: mut_at, confirmed_at: confirmed_at,
                  confirmed_attrs: confirmed_attrs, initial_attrs: initial_attrs)
                state_hlc = max_valid_hlc(state_hlc, mut_hlc) if replayed
              end
            when "update"
              if exists
                replayed = apply_replayed_columns!(state_attrs, changes,
                  mut_hlc: mut_hlc, confirmed_hlc: confirmed_hlc,
                  mut_at: mut_at, confirmed_at: confirmed_at,
                  confirmed_attrs: confirmed_attrs, initial_attrs: initial_attrs)
                state_hlc = max_valid_hlc(state_hlc, mut_hlc) if replayed
              end
            end
          end

          { "exists" => exists, "version" => confirmed_version, "hlc" => state_hlc, "attributes" => state_attrs }
        end

        def apply_replayed_columns!(state_attrs, changes, mut_hlc:, confirmed_hlc:, mut_at:, confirmed_at:, confirmed_attrs:, initial_attrs:)
          server_newer = strictly_newer?(confirmed_hlc, mut_hlc, confirmed_at, mut_at)
          applied_any = false

          changes.each do |col, val|
            next if SKIP_REPLAY_COLUMNS.include?(col)

            server_changed_col = initial_attrs.nil? || confirmed_attrs.nil? ||
              normalized_value(confirmed_attrs[col]) != normalized_value(initial_attrs[col])
            next if server_newer && server_changed_col

            state_attrs[col] = val
            applied_any = true
          end

          if strictly_newer?(mut_hlc, confirmed_hlc, mut_at, confirmed_at)
            state_attrs["updated_at"] = changes["updated_at"] if changes["updated_at"]
          end

          applied_any
        end

        def build_in_memory_record(model, record_id, attrs, version)
          record = model.new
          record.id = record_id
          record.assign_attributes(attrs.except("id", "server_version", "sync_state")) if attrs
          record.server_version = version
          record
        end

        # Materialize the computed state onto SQLite in a single write (only if
        # needed). Returns true when visible user attributes (or row existence)
        # actually changed.
        def materialize_state(model, record_id, state, remaining:, force_hlc: false, record_delta: false)
          existing = model.find_by(id: record_id)
          before_visible = existing ? visible_attributes(existing) : nil

          unless state["exists"]
            HLC.delete_row_hlc(model.name, record_id)
            return false unless existing

            Client.note_record_change(existing, "destroy") if record_delta
            existing.destroy!
            return true
          end

          attrs = (state["attributes"] || {}).deep_stringify_keys.slice(*model.column_names)
          record = existing || model.new(id: record_id)
          assignable = attrs.except("id", "server_version", "sync_state")
          assignable.delete("created_at") if existing && assignable["created_at"].nil?
          record.assign_attributes(assignable)
          record.server_version = state["version"].to_i
          record.sync_state = remaining.empty? ? "synced" : "pending"

          after_visible = visible_attributes(record)
          visible_changed = (before_visible != after_visible)
          was_new = record.new_record?
          changed_cols = record.changed.map(&:to_s)

          if was_new || visible_changed
            preserve_timestamps = record.respond_to?(:record_timestamps=) &&
              assignable["updated_at"].present? &&
              (!was_new || !model.column_names.include?("created_at") || assignable["created_at"].present?)
            if preserve_timestamps
              previous = record.record_timestamps
              record.record_timestamps = false
              begin
                record.save!(validate: false)
              ensure
                record.record_timestamps = previous
              end
            else
              record.save!(validate: false)
            end
            Client.note_record_change(record, was_new ? "create" : "update", changed_columns: changed_cols) if record_delta
          elsif record.changed?
            record.update_columns(server_version: record.server_version, sync_state: record.sync_state)
          end

          if HLC.valid?(state["hlc"])
            HLC.set_row_hlc(model.name, record_id, state["hlc"], force: force_hlc)
          end
          visible_changed
        end

        def visible_attributes(record)
          InstantRecord.wire_attributes(record.attributes)
            .except(*Client::BOOKKEEPING_COLUMNS)
            .transform_values { |v| normalized_value(v) }
        end

        def shadowed_by_local?(incoming_attrs, final_attrs)
          return false unless final_attrs

          incoming_attrs.each do |col, val|
            next if SKIP_REPLAY_COLUMNS.include?(col)
            return true if normalized_value(final_attrs[col]) != normalized_value(val)
          end
          false
        end

        def notify_discarded_if_different(model, record_id, incoming_attrs)
          handler = model.instant_record_discarded_change_handler
          return unless handler

          existing = model.find_by(id: record_id)
          return unless existing

          current = visible_attributes(existing)
          differs = incoming_attrs.any? do |col, val|
            next false if SKIP_REPLAY_COLUMNS.include?(col)

            current[col] != normalized_value(val)
          end
          handler.call(incoming_attrs) if differs
        end

        def stale_against?(incoming_hlc, reference_hlc, incoming_at, reference_at)
          if HLC.valid?(incoming_hlc) && HLC.valid?(reference_hlc)
            HLC.compare(incoming_hlc, reference_hlc) <= 0
          elsif HLC.valid?(incoming_hlc) && reference_at
            pt = HLC.physical_time(incoming_hlc)
            pt ? pt <= reference_at : false
          elsif incoming_at && reference_at
            incoming_at <= reference_at
          else
            false
          end
        end

        def strictly_newer?(candidate_hlc, baseline_hlc, candidate_at, baseline_at)
          if HLC.valid?(candidate_hlc) && HLC.valid?(baseline_hlc)
            HLC.compare(candidate_hlc, baseline_hlc) > 0
          elsif candidate_at && baseline_at
            candidate_at > baseline_at
          elsif HLC.valid?(candidate_hlc) && baseline_at
            pt = HLC.physical_time(candidate_hlc)
            pt ? pt > baseline_at : false
          elsif candidate_at && HLC.valid?(baseline_hlc)
            pt = HLC.physical_time(baseline_hlc)
            pt ? candidate_at > pt : false
          else
            false
          end
        end

        def max_valid_hlc(a, b)
          a_valid = HLC.valid?(a)
          b_valid = HLC.valid?(b)
          return b unless a_valid
          return a unless b_valid

          HLC.compare(a, b) >= 0 ? a : b
        end

        def normalized_value(val)
          if val.respond_to?(:usec)
            val.utc.iso8601(InstantRecord::TIME_PRECISION)
          else
            val
          end
        end

        def parse_timestamp(raw)
          return nil if raw.nil? || raw.to_s.empty?
          return raw.to_time.utc if raw.respond_to?(:to_time) && !raw.is_a?(String)

          Time.parse(raw.to_s).utc
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
