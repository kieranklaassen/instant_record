require "instant_record/client/transport"
require "instant_record/client/notifier"

module InstantRecord
  # Browser-side sync client. Ruby owns the whole sync loop — transport
  # included — via JS fetch interop; the service worker shim only schedules
  # `InstantRecord.tick` (wasm Ruby cannot sleep without blocking the VM).
  module Client
    class << self
      # Applying remote state must never enqueue new outbox mutations.
      def applying_remote? = @applying_remote
      def applying_remote(&block)
        @applying_remote = true
        block.call
      ensure
        @applying_remote = false
      end

      # Seams: real implementations are JS-interop-backed and browser-only;
      # tests inject doubles so the loop runs under CRuby.
      attr_writer :transport, :notifier

      def transport
        @transport ||= Transport::JsFetch.new
      end

      def notifier
        @notifier ||= Notifier::JsClients.new
      end

      # One full pass: outbox up, changes down, tabs notified when anything
      # moved. Called under InstantRecord.tick's single-flight guard. A client
      # that has never synced hydrates from the bootstrap snapshot instead of
      # replaying the whole change log from cursor 0.
      def sync_pass
        changed = drain
        changed = (bootstrapped? ? poll_changes : bootstrap) || changed
        notifier.records_changed if changed
        changed
      end

      def pending_count
        OutboxMutation.count
      end

      def pending_mutations
        OutboxMutation.ordered.map(&:as_mutation)
      end

      def cursor
        SyncMetadata.get("cursor").to_i
      end

      def cursor=(value)
        SyncMetadata.set("cursor", value)
      end

      # nil-aware on purpose: cursor 0 (bootstrapped against an empty change
      # log) and "never synced" must not be conflated — `cursor` alone would
      # report 0 for both.
      def bootstrapped?
        !SyncMetadata.get("cursor").nil?
      end

      # First-sync hydration: windowed current state + cursor in one response.
      # The server captures the cursor BEFORE reading rows, so any overlap
      # with subsequent events re-applies idempotently. Returns true when the
      # snapshot applied.
      def bootstrap
        body = transport.get_json("/bootstrap")
        Array(body["records"]).each { |record| apply_change(record) }

        # Cursor written last: a crash mid-apply leaves it nil, so the next
        # tick re-bootstraps; upserts make the retry idempotent. A failure
        # never falls through to a cursor-0 poll of the full change log.
        self.cursor = body["cursor"]
        true
      rescue Transport::Error => e
        log_failure("bootstrap", e)
        false
      end

      # Outbox up. Returns true when anything was sent and applied.
      def drain
        mutations = pending_mutations
        return false if mutations.empty?

        body = transport.post_json("/mutations", { mutations: mutations })
        apply_results(body["results"])
        true
      rescue Transport::Error => e
        log_failure("drain", e)
        false
      end

      # Changes down, catch-up style: window=0 asks the server to close the
      # stream right after catch-up instead of tailing a long window. The tick
      # cadence provides liveness; a long-held stream inside the single-flight
      # tick would starve outbox drains and defer notifications.
      # Returns true when any remote change was applied.
      def poll_changes
        changed = false
        last_cursor = nil

        transport.each_event("/events?after=#{cursor}&window=0") do |event|
          event = event.deep_stringify_keys
          apply_change(event)
          last_cursor = event["cursor"] || last_cursor
          changed = true
        end

        # One cursor write per poll, not per event. A crash before this line
        # re-applies the batch next poll; upserts + LWW make that idempotent.
        self.cursor = last_cursor if last_cursor
        changed
      rescue Transport::Error => e
        log_failure("poll", e)
        changed
      end

      # Server results for a posted batch.
      # applied  -> drop the outbox row, mark the record synced
      # rejected -> drop the outbox row, reconcile to server state
      def apply_results(results)
        Array(results).each do |result|
          result = result.deep_stringify_keys
          mutation = OutboxMutation.find_by(id: result["mutation_id"])
          next unless mutation

          applying_remote do
            case result["status"]
            when "applied"
              mark_synced(mutation, result["version"])
            when "rejected"
              reconcile_rejection(mutation, result)
            end
            mutation.destroy!
          end
        end
        nil
      end

      # Apply one remote change event (last-write-wins).
      def apply_change(event)
        event = event.deep_stringify_keys
        model = InstantRecord.synced_model(event["type"])
        return unless model

        applying_remote do
          case event["operation"]
          when "destroy"
            model.find_by(id: event["id"])&.destroy!
          else
            upsert_from_server(model, event["attributes"], event["version"])
          end
        end
        nil
      end

      private

      def mark_synced(mutation, version)
        model = InstantRecord.synced_model(mutation.record_type)
        record = model&.find_by(id: mutation.record_id)
        return unless record

        record.update_columns(sync_state: "synced", server_version: version || record.server_version)
      end

      def reconcile_rejection(mutation, result)
        model = InstantRecord.synced_model(mutation.record_type)
        return unless model

        server_attributes = result["server_attributes"]

        if server_attributes.present?
          upsert_from_server(model, server_attributes, result["version"])
        else
          # The server never accepted this record (rejected create): remove it.
          model.find_by(id: mutation.record_id)&.destroy!
        end
      end

      def upsert_from_server(model, attributes, version)
        return unless attributes

        record = model.find_or_initialize_by(id: attributes["id"])

        incoming_at = attributes["updated_at"] && Time.parse(attributes["updated_at"].to_s)
        local_at = record.persisted? ? record.updated_at : nil

        # Client-side LWW: never clobber a locally newer row.
        return if incoming_at && local_at && incoming_at < local_at

        record.assign_attributes(attributes.except("id", "server_version"))
        record.server_version = version || attributes["server_version"] || 0
        record.sync_state = "synced"
        record.save!(validate: false)
      end

      def log_failure(phase, error)
        warn "[instant_record] #{phase} failed (offline?): #{error.message}"
      end
    end
  end
end
