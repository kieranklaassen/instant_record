require "uri"
require "time"
require "active_support/notifications"
require "instant_record/client/transport"
require "instant_record/client/notifier"

module InstantRecord
  # Ruby reconciles local records and queued mutations. The worker handles network I/O.
  module Client
    # Columns the gem keeps for its own bookkeeping. A remote value that differs
    # in these alone is not a change to the row, it is our own write being
    # acknowledged twice.
    BOOKKEEPING_COLUMNS = %w[server_version sync_state].freeze

    # More changes than this in one notice are not listed one by one.
    MAX_LISTED_CHANGES = 200

    class << self
      # Applying remote state must never enqueue new outbox mutations.
      def applying_remote? = @applying_remote
      def applying_remote(&block)
        @applying_remote = true
        block.call
      ensure
        @applying_remote = false
      end

      # Seams: real implementations are worker-backed and browser-only;
      # tests inject doubles so the loop runs under CRuby.
      attr_writer :transport, :notifier

      def transport
        @transport ||= Transport::WorkerFetch.new
      end

      def notifier
        @notifier ||= Notifier::Worker.new
      end

      # One full pass: outbox up, changes down, tabs notified when anything
      # moved. Called under InstantRecord.tick's single-flight guard. A client
      # that has never synced hydrates from the bootstrap snapshot instead of
      # replaying the whole change log from cursor 0.
      def sync_pass
        changed = evict_beyond_windows
        changed = drain || changed
        # Evictions and acknowledged writes are not listed one by one, and
        # neither is a bootstrap: the page is told that anything may have changed.
        unlisted_changes if changed || !bootstrapped?
        changed = (bootstrapped? ? poll_changes : bootstrap) || changed
        notify_changed if changed
        changed
      end

      # Which records changed since the page was last told, as "Type:id"
      # lines after the notice itself. The notice alone means anything may have.
      def changes_notice
        return "records_changed" if @unlisted_changes || changed_records.empty?

        "records_changed\n" + changed_records.join("\n")
      end

      def changed_records
        @changed_records ||= []
      end

      def unlisted_changes
        @unlisted_changes = true
      end

      def note_change(type, id)
        if changed_records.size >= MAX_LISTED_CHANGES
          unlisted_changes
        else
          changed_records << "#{type}:#{id}"
        end
      end

      def notify_changed
        notifier.records_changed
        changed_records.clear
        @unlisted_changes = false
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

      # The name the server gave the person this browser synced as, when the
      # server tells people apart. It is sent back with every request so the
      # server can say when that person has changed.
      def identity_key
        SyncMetadata.get("identity")
      end

      # The body of an outbox drain. The compiled worker prepares the same
      # request ahead of the pass, so both build it here.
      def mutations_payload(mutations)
        key = identity_key
        key.nil? ? { mutations: mutations } : { mutations: mutations, identity: key }
      end

      # The server says this browser synced as someone else. Everything it was
      # sent for that person goes, with the writes they had queued to those
      # models, and the next pass starts again from a bootstrap as whoever is
      # here now. Models every client may see keep their queued writes.
      def reset(event)
        types = Array(event["types"])
        applying_remote do
          types.each do |type|
            model = InstantRecord.synced_model(type)
            model.delete_all if model
          end
        end
        OutboxMutation.all.each do |mutation|
          mutation.destroy if types.include?(mutation.record_type)
        end
        # The rows that stay were last brought up to date at this cursor. The
        # bootstrap to come only adds and changes rows, so the poll after it
        # starts here again and a destroy made in between is not missed.
        SyncMetadata.set("replay_from", cursor) if bootstrapped? && SyncMetadata.get("replay_from").nil?
        SyncMetadata.all.each do |entry|
          entry.destroy if entry.key == "cursor" || entry.key == "identity" || entry.key.start_with?("history:") ||
            types.any? { |type| entry.key.start_with?("#{HLC::ROW_PREFIX}#{type}:") }
        end
        history_marks.clear
        unlisted_changes
        instrument("reset")
        true
      end

      # First-sync hydration: windowed current state + cursor in one response.
      # The server captures the cursor BEFORE reading rows, so any overlap
      # with subsequent events re-applies idempotently. Returns true when the
      # snapshot applied.
      def bootstrap
        instrument("bootstrap") do |event|
          body = transport.get_json("/bootstrap")
          observe_server_time(body["server_time"])
          records = Array(body["records"])
          records.each { |record| apply_change(record) }
          event[:records] = records.size

          # Cursor written last: a crash mid-apply leaves it nil, so the next
          # tick re-bootstraps; upserts make the retry idempotent. A failure
          # never falls through to a cursor-0 poll of the full change log.
          SyncMetadata.set("identity", body["identity"]) if body["identity"]
          replay = SyncMetadata.get("replay_from")
          if replay.nil? || replay.to_i > body["cursor"].to_i
            self.cursor = body["cursor"]
          else
            self.cursor = replay.to_i
          end
          SyncMetadata.all.each { |entry| entry.destroy if entry.key == "replay_from" } unless replay.nil?
          true
        end
      rescue Transport::Error => e
        log_failure("bootstrap", e)
        false
      end

      # Outbox up. Returns true when anything was sent and applied.
      def drain
        mutations = pending_mutations
        return false if mutations.empty?

        instrument("drain") do |event|
          body = transport.post_json("/mutations", mutations_payload(mutations))
          observe_server_time(body["server_time"])
          apply_results(body["results"])

          results = Array(body["results"]).map { |r| r.deep_stringify_keys }
          event[:posted] = mutations.size
          event[:rejected] = results.count { |r| r["status"] == "rejected" }
          event[:reasons] = results.filter_map { |r| r["reason"] }.uniq.first(3)
          true
        end
      rescue Transport::Error => e
        log_failure("drain", e)
        false
      end

      def observe_server_time(server_time)
        HLC.observe_server_time(server_time) if server_time
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

      # A native host opened another database file: drop what was held in
      # memory about the one before.
      def forget_database
        reset_stream
        history_marks.clear
        changed_records.clear
        @unlisted_changes = false
        @eviction_pending = false
        nil
      end

      # Applies events delivered from outside — a stream the worker is holding.
      # Idempotent by the same upsert + last-write-wins path a poll uses, so a
      # replayed or overlapping batch is harmless. Returns the number applied.
      def apply_events(events)
        applied = 0
        newest_cursor = nil

        was_reset = false

        Array(events).each do |event|
          # Nothing after a reset belongs to this client any more, and the
          # cursor it would have advanced is gone.
          next if was_reset

          event = event.deep_stringify_keys
          observe_server_time(event["server_time"])
          if event["operation"] == "reset"
            was_reset = reset(event)
            applied += 1
            next
          end
          applied += 1 if apply_change(event)
          # The cursor advances for every event, changed or not: an echo we chose
          # to ignore must not be handed to us again.
          newest_cursor = event["cursor"] || newest_cursor
        end

        # One cursor write per batch, as poll_changes does: a crash before this
        # re-applies the batch, which the upserts make safe.
        self.cursor = newest_cursor if newest_cursor && !was_reset
        notify_changed if applied.positive?
        instrument("stream", applied: applied) if applied.positive?
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
        applied = 0
        last_cursor = nil
        was_reset = false
        key = identity_key
        path = "/events?after=#{cursor}&window=0"
        path += "&identity=#{key}" unless key.nil?

        instrument("poll") do |note|
          transport.each_event(path) do |event|
            event = event.deep_stringify_keys
            next if was_reset
            observe_server_time(event["server_time"])
            if event["operation"] == "reset"
              was_reset = reset(event)
              changed = true
              next
            end
            if apply_change(event)
              changed = true
              applied += 1
            end
            last_cursor = event["cursor"] || last_cursor
          end
          note[:applied] = applied

          # One cursor write per poll, not per event. A crash before this line
          # re-applies the batch next poll; upserts + LWW make that idempotent.
          self.cursor = last_cursor if last_cursor && !was_reset
        end
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

        instrument("fetch_history") do |event|
          body = transport.get_json(history_path(model, partition, before_at, before_id, limit))
          observe_server_time(body["server_time"])
          records = Array(body["records"])
          records.each { |record| apply_change(record) }
          extend_history_mark(model, partition, records, has_more: !!body["has_more"])
          event[:applied] = records.size
          event[:has_more] = !!body["has_more"]
          { ok: true, applied: records.size, has_more: !!body["has_more"] }
        end
      rescue Transport::Error => e
        log_failure("fetch_history", e)
        { ok: false, applied: 0, has_more: nil, error: e.message }
      end

      # Server results for a posted batch. Every result drops the outbox row —
      # each one is a durable resolution, not a retry — and what happens to the
      # record depends on which resolution it is:
      # applied           -> mark the record synced
      # applied + skipped -> the write lost last-write-wins; reconcile to the
      #                      value that won, because it did NOT land here
      # rejected          -> reconcile to server state
      def apply_results(results)
        Array(results).each do |result|
          result = result.deep_stringify_keys
          mutation = OutboxMutation.find_by(id: result["mutation_id"])
          next unless mutation

          applying_remote do
            HLC.receive(result["hlc"]) if HLC.valid?(result["hlc"])
            case result["status"]
            when "applied"
              # `skipped` means our write lost resolution; `merged` means a
              # 3-way column merge produced a combined row on the server. Either
              # way, the local row does not yet hold what the server holds, so
              # reconcile authoritatively to `server_attributes`.
              if result["skipped"] || result["merged"] || result["server_attributes"].present?
                reconcile_to_server_state(mutation, result)
              else
                mark_synced(mutation, result["version"], hlc: result["hlc"])
              end
            when "rejected"
              reconcile_rejection(mutation, result)
            end
            mutation.destroy!
          end
        end
        nil
      end

      # Apply one remote change event (HLC-ordered, with updated_at fallback
      # for legacy events). Returns whether it actually changed anything here.
      def apply_change(event)
        event = event.deep_stringify_keys
        model = InstantRecord.synced_model(event["type"])
        return false unless model

        applied = applying_remote do
          if event["operation"] == "destroy"
            HLC.receive(event["hlc"]) if HLC.valid?(event["hlc"])
            HLC.delete_row_hlc(event["type"], event["id"])
            !!model.find_by(id: event["id"])&.destroy!
          else
            upsert_from_server(model, event["attributes"], event["version"], hlc: event["hlc"])
          end
        end
        note_change(event["type"], event["id"]) if applied
        applied
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

      def mark_synced(mutation, version, hlc: nil)
        model = InstantRecord.synced_model(mutation.record_type)
        record = model&.find_by(id: mutation.record_id)
        return unless record

        record.update_columns(sync_state: "synced", server_version: version || record.server_version)
        HLC.set_row_hlc(mutation.record_type, mutation.record_id, hlc) if HLC.valid?(hlc)
      end

      def reconcile_rejection(mutation, result)
        return if reconcile_to_server_state(mutation, result)

        # The server never accepted this record (rejected create): remove it.
        HLC.delete_row_hlc(mutation.record_type, mutation.record_id)
        InstantRecord.synced_model(mutation.record_type)&.find_by(id: mutation.record_id)&.destroy!
      end

      # Roll the local record onto the server's own copy of the row, when the
      # result carries one. Returns whether it did — the caller distinguishes
      # "the server has no such row" from "the server has this row".
      #
      # Authoritative: the server told us what it holds in answer to a write of
      # ours it would not take (or merged), so its row wins here regardless of
      # clocks.
      def reconcile_to_server_state(mutation, result)
        model = InstantRecord.synced_model(mutation.record_type)
        return false unless model && result["server_attributes"].present?

        upsert_from_server(model, result["server_attributes"], result["version"], hlc: result["hlc"], authoritative: true)
        true
      end

      # Returns whether the row actually moved. Every accepted write comes back
      # down the change stream, so a client is constantly re-applying its own
      # rows; treating those as changes would announce them, and an announcement
      # reloads any page without an in-place refresh.
      #
      # Client-side convergence compares server-anchored string-encoded HLCs
      # (falling back to microsecond updated_at only for legacy events without
      # an HLC): a remote value must be strictly NEWER to replace a local one,
      # so equal stamps (such as echoes of our own writes) leave the row alone.
      # Because HLC physical time is anchored to authoritative server UTC and
      # extreme forward skew is clamped on the server, a client whose wall clock
      # runs ahead no longer wins writes it should lose.
      #
      # `authoritative` skips the comparison entirely for reconciling rejections,
      # skipped writes, and 3-way merged rows from the server.
      def upsert_from_server(model, attributes, version, hlc: nil, authoritative: false)
        return false unless attributes

        HLC.receive(hlc) if HLC.valid?(hlc)

        # Schema skew must not raise here either: a client behind the server is
        # sent columns it has not migrated yet. They are the server's to keep;
        # this runtime converges on the columns it actually has.
        attributes = attributes.slice(*model.column_names)
        record = model.find_or_initialize_by(id: attributes["id"])

        incoming_hlc = HLC.valid?(hlc) ? hlc : nil
        local_hlc = record.persisted? ? HLC.row_hlc(model.name, record.id) : nil
        incoming_at = attributes["updated_at"] && Time.parse(attributes["updated_at"].to_s)
        local_at = record.persisted? ? record.updated_at : nil

        record.assign_attributes(attributes.except("id", "server_version"))

        if !authoritative && record.persisted? && stale_remote?(incoming_hlc, local_hlc, incoming_at, local_at)
          # The remote value lost. This is the last moment it exists in this
          # runtime — nothing downstream sees it, which is why models get a seam.
          if (record.changed - BOOKKEEPING_COLUMNS).any?
            model.instant_record_discarded_change_handler&.call(attributes)
          end
          return false
        end

        record.server_version = version || attributes["server_version"] || 0
        record.sync_state = "synced"
        HLC.set_row_hlc(model.name, record.id, incoming_hlc, force: authoritative) if incoming_hlc
        return false unless record.changed?

        record.save!(validate: false)
        true
      end

      def stale_remote?(incoming_hlc, local_hlc, incoming_at, local_at)
        if incoming_hlc && HLC.valid?(local_hlc)
          HLC.compare(incoming_hlc, local_hlc) <= 0
        elsif incoming_hlc && local_at
          incoming_pt = HLC.physical_time(incoming_hlc)
          incoming_pt ? incoming_pt <= local_at : false
        elsif incoming_at && local_at
          incoming_at <= local_at
        else
          false
        end
      end

      def log_failure(phase, error)
        instrument("offline", phase: phase, error: error.message)
        warn "[instant_record] #{phase} failed (offline?): #{error.message}"
      end

      # Every meaningful sync outcome is announced through
      # ActiveSupport::Notifications — the seam a host app subscribes to for
      # logging or metrics, and the one the browser runtime's forwarder turns
      # for server-side subscribers. The compiled worker reports to the inspector.
      # narrative because Ruby is what knows: the worker can only say it made a
      # request; this side knows what the pass actually did. Free-standing
      # events (no block) fire instantly; wrapped ones carry duration and, on a
      # raise, the exception in the payload.
      def instrument(name, payload = {}, &block)
        ActiveSupport::Notifications.instrument("#{name}.instant_record", payload, &block)
      end
    end
  end
end
