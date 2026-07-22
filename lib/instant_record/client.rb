require "json"
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

      # Outbox up. Returns true when anything was sent and applied.
      def drain
        mutations = JSON.parse(InstantRecord.pending_mutations_json)
        return false if mutations.empty?

        body = transport.post_json("/mutations", { mutations: mutations })
        InstantRecord.apply_results(JSON.generate(body["results"]))
        true
      rescue Transport::Error => e
        InstantRecord.log_sync_failure("drain", e)
        false
      end

      # Changes down. Returns true when any remote change was applied.
      def poll_changes
        changed = false

        transport.each_event("/events?after=#{InstantRecord.cursor}") do |event|
          InstantRecord.apply_change(JSON.generate(event))
          changed = true
        end

        changed
      rescue Transport::Error => e
        InstantRecord.log_sync_failure("poll", e)
        changed || false
      end

      def notify_records_changed
        notifier.records_changed
      end
    end
  end

  class << self
    def pending_count
      OutboxMutation.count
    end

    def log_sync_failure(phase, error)
      warn "[instant_record] #{phase} failed (offline?): #{error.message}"
    end

    def cursor
      SyncMetadata.get("cursor").to_i
    end

    def cursor=(value)
      SyncMetadata.set("cursor", value)
    end

    # Outbox drain, step 1: everything pending, oldest first.
    def pending_mutations_json
      OutboxMutation.ordered.map(&:as_mutation).to_json
    end

    # Outbox drain, step 2: server results for a posted batch.
    # applied  -> drop the outbox row, mark the record synced
    # rejected -> drop the outbox row, reconcile to server state (KTD4)
    def apply_results(json)
      Array(JSON.parse(json)).each do |result|
        mutation = OutboxMutation.find_by(id: result["mutation_id"])
        next unless mutation

        Client.applying_remote do
          case result["status"]
          when "applied"
            mark_synced(mutation, result["version"])
          when "rejected"
            reconcile_rejection(mutation, result)
          end
          mutation.destroy!
        end
      end
      pending_count
    end

    # SSE change stream: apply one remote change event (last-write-wins).
    def apply_change(json)
      event = JSON.parse(json)
      model = synced_model(event["type"])
      return cursor unless model

      Client.applying_remote do
        case event["operation"]
        when "destroy"
          model.find_by(id: event["id"])&.destroy!
        else
          upsert_from_server(model, event["attributes"], event["version"])
        end
      end

      event["cursor"].then { |c| self.cursor = c if c }
      cursor
    end

    private

    def mark_synced(mutation, version)
      model = synced_model(mutation.record_type)
      record = model&.find_by(id: mutation.record_id)
      return unless record

      record.update_columns(sync_state: "synced", server_version: version || record.server_version)
    end

    def reconcile_rejection(mutation, result)
      model = synced_model(mutation.record_type)
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

      # Client-side LWW: never clobber a locally newer row (R11).
      return if incoming_at && local_at && incoming_at < local_at

      record.assign_attributes(attributes.except("id", "server_version"))
      record.server_version = version || attributes["server_version"] || 0
      record.sync_state = "synced"
      record.save!(validate: false)
    end
  end
end
