require "uri"
require "time"
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
        changed = evict_beyond_windows
        changed = drain || changed
        changed = (bootstrapped? ? poll_changes : bootstrap) || changed
        notifier.records_changed if changed
        changed
      end

      # Arm the boot-time trim; InstantRecord.start sets this on cold boots
      # only. Runs once, on the next sync pass.
      def request_eviction
        @eviction_pending = true
      end

      # Trim every windowed model back to its declared window. delete_all
      # under applying_remote: no callbacks, no outbox rows. Pending rows are
      # excluded in the WHERE — an unsynced write is never evicted. Returns
      # true when anything was deleted.
      def evict_beyond_windows
        return false unless @eviction_pending

        @eviction_pending = false
        evicted = false
        InstantRecord.syncable_models.each do |model|
          window = model.instant_record_sync_window
          next unless window

          applying_remote do
            evicted = true if window.beyond_window(model.where.not(sync_state: "pending")).delete_all.positive?
          end
        end
        evicted
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

      # Set while something outside the VM holds a tailing stream and feeds
      # events in through apply_events (the service worker does this). Ruby
      # cannot hold that stream itself: each chunk it awaited would suspend the
      # single-flight tick, starving outbox drains for the length of the window.
      attr_writer :streaming

      def streaming? = !!@streaming

      # Feeds one chunk of the change stream through the same SseParser the poll
      # path uses, and applies whatever complete events it yields. The worker owns
      # the socket — Ruby awaiting chunks would suspend the sync guard — but the
      # wire format is parsed here, so there is one implementation of it and it is
      # the tested one. A frame split across chunks is buffered until it is whole.
      # Returns the number applied.
      def consume_stream(chunk)
        stream_parser.feed(chunk.to_s)
        return 0 if stream_events.empty?

        applied = apply_events(stream_events)
        stream_events.clear
        applied
      end

      # A reconnect starts a new stream: drop any half-received frame from the
      # old one rather than letting its prefix corrupt the first new frame.
      def reset_stream
        @stream_parser = nil
        stream_events.clear
        nil
      end

      # Applies events delivered from outside — a stream the worker is holding.
      # Idempotent by the same upsert + last-write-wins path a poll uses, so a
      # replayed or overlapping batch is harmless. Returns the number applied.
      def apply_events(events)
        applied = 0
        newest_cursor = nil

        Array(events).each do |event|
          event = event.deep_stringify_keys
          applied += 1 if apply_change(event)
          # The cursor advances for every event, changed or not: an echo we chose
          # to ignore must not be handed to us again.
          newest_cursor = event["cursor"] || newest_cursor
        end

        # One cursor write per batch, as poll_changes does: a crash before this
        # re-applies the batch, which the upserts make safe.
        self.cursor = newest_cursor if newest_cursor
        notifier.records_changed if applied.positive?
        applied
      end

      # Changes down, catch-up style: window=0 asks the server to close the
      # stream right after catch-up instead of tailing a long window. The tick
      # cadence provides liveness; a long-held stream inside the single-flight
      # tick would starve outbox drains and defer notifications.
      #
      # Skipped entirely while a stream is live — that stream is already
      # delivering, and re-polling would only re-fetch what it just applied.
      # Returns true when any remote change was applied.
      def poll_changes
        return false if streaming?

        changed = false
        last_cursor = nil

        transport.each_event("/events?after=#{cursor}&window=0") do |event|
          event = event.deep_stringify_keys
          changed = true if apply_change(event)
          last_cursor = event["cursor"] || last_cursor
        end

        # One cursor write per poll, not per event. A crash before this line
        # re-applies the batch next poll; upserts + LWW make that idempotent.
        self.cursor = last_cursor if last_cursor
        changed
      rescue Transport::Error => e
        log_failure("poll", e)
        changed
      end

      # On-demand history page for a windowed model. Serves from the local
      # database when the requested page is known-contiguous (see the
      # per-partition low-water mark below); otherwise fetches a keyset page
      # from the server and applies it under applying_remote — idempotent
      # upserts, no outbox rows, no records_changed (the requesting page
      # refreshes itself). Returns {ok:, applied:, has_more:} or an error hash.
      # Callers enter through InstantRecord.fetch_history, which shares the
      # tick's single-flight guard.
      def fetch_history(model, before:, partition: nil, limit: nil)
        window = model.instant_record_sync_window
        raise ArgumentError, "#{model.name} declares no sync_window; fetch_history needs one" unless window
        raise ArgumentError, "#{model.name} windows by #{window.partition_by}; pass partition:" if window.partition_by && partition.nil?

        limit ||= window.limit
        before_at = Time.parse(before[:created_at].to_s)
        before_id = before[:id].to_s

        unless InstantRecord.browser?
          return { ok: true, applied: 0, has_more: local_page(window, partition, before_at, before_id, limit + 1).size > limit }
        end

        if (mark = history_mark(model, partition)) && page_local?(mark, window, partition, before_at, before_id, limit)
          # has_more from the served page, not the partition-wide mark: rows
          # remain below this page when the local probe overflows `limit`, or
          # when the page reaches the contiguity frontier and the server still
          # has older rows (mark[:has_more]). Echoing the mark alone reports
          # "beginning reached" for any mid-history page after the true
          # beginning was loaded.
          local = local_page(window, partition, before_at, before_id, limit + 1)
          return { ok: true, applied: 0, has_more: local.size > limit || mark[:has_more] }
        end

        body = transport.get_json(history_path(model, partition, before_at, before_id, limit))
        records = Array(body["records"])
        records.each { |record| apply_change(record) }
        extend_history_mark(model, partition, records, has_more: !!body["has_more"])
        { ok: true, applied: records.size, has_more: !!body["has_more"] }
      rescue Transport::Error => e
        log_failure("fetch_history", e)
        { ok: false, applied: 0, has_more: nil, error: e.message }
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

      # Apply one remote change event (last-write-wins). Returns whether it
      # actually changed anything here — see upsert_from_server.
      def apply_change(event)
        event = event.deep_stringify_keys
        model = InstantRecord.synced_model(event["type"])
        return false unless model

        applying_remote do
          if event["operation"] == "destroy"
            !!model.find_by(id: event["id"])&.destroy!
          else
            upsert_from_server(model, event["attributes"], event["version"])
          end
        end
      end

      private

      # Where the parser drops finished events, drained by consume_stream.
      def stream_events
        @stream_events ||= []
      end

      def stream_parser
        @stream_parser ||= Transport::SseParser.new { |event| stream_events << event }
      end

      # Contiguity low-water marks, one per (model, partition), held in
      # VM-session memory only. Row count alone cannot prove a local page has
      # no holes (live updates re-create evicted rows as strays); the mark
      # tracks the oldest boundary of contiguously fetched history plus the
      # server's last has_more answer.
      def history_marks
        @history_marks ||= {}
      end

      def history_mark(model, partition)
        history_marks[[model.name, partition]]
      end

      def extend_history_mark(model, partition, records, has_more:)
        key = [model.name, partition]
        oldest = records.map { |r| [Time.parse(r.dig("attributes", "created_at").to_s), r["id"].to_s] }.min
        mark = history_marks[key] ||= { oldest_at: nil, oldest_id: nil }
        mark[:has_more] = has_more
        return unless oldest
        return if mark[:oldest_at] && ([mark[:oldest_at], mark[:oldest_id]] <=> oldest) <= 0

        mark[:oldest_at], mark[:oldest_id] = oldest
      end

      # A page is fully local when the beginning of history was already
      # reached, or when `limit` rows older than `before` exist locally within
      # the contiguous region above the mark.
      def page_local?(mark, window, partition, before_at, before_id, limit)
        return true if mark[:has_more] == false

        rows = local_page(window, partition, before_at, before_id, limit)
        rows.size >= limit && rows.all? { |at, id| ([at, id] <=> [mark[:oldest_at], mark[:oldest_id]]) >= 0 }
      end

      # Keyset page below (before_at, before_id), newest first, as
      # [created_at, id] tuples.
      def local_page(window, partition, before_at, before_id, limit)
        window
          .keyset_below(at: before_at, id: before_id, partition: partition)
          .limit(limit)
          .pluck(:created_at, window.model.primary_key)
          .map { |at, id| [at.to_time, id.to_s] }
      end

      def history_path(model, partition, before_at, before_id, limit)
        params = { type: model.name, before_created_at: before_at.utc.iso8601(6), before_id: before_id, limit: limit }
        params[:partition] = partition if partition
        "/records?#{URI.encode_www_form(params)}"
      end

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

      # Returns whether the row actually moved. Every accepted write comes back
      # down the change stream, so a client is constantly re-applying its own
      # rows; treating those as changes would announce them, and an announcement
      # reloads any page without an in-place refresh.
      def upsert_from_server(model, attributes, version)
        return false unless attributes

        record = model.find_or_initialize_by(id: attributes["id"])

        incoming_at = attributes["updated_at"] && Time.parse(attributes["updated_at"].to_s)
        local_at = record.persisted? ? record.updated_at : nil

        # Client-side LWW: never clobber a locally newer row.
        return false if incoming_at && local_at && incoming_at < local_at

        record.assign_attributes(attributes.except("id", "server_version"))
        record.server_version = version || attributes["server_version"] || 0
        record.sync_state = "synced"
        return false unless record.changed?

        record.save!(validate: false)
        true
      end

      def log_failure(phase, error)
        warn "[instant_record] #{phase} failed (offline?): #{error.message}"
      end
    end
  end
end
