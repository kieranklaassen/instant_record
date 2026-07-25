require "uri"
require "time"
require "active_support/notifications"
require "instant_record/client/transport"
require "instant_record/client/notifier"
require "instant_record/client/instrumentation"

module InstantRecord
  # Browser-side sync client. Ruby owns the whole sync loop — transport
  # included — via JS fetch interop; the service worker shim only schedules
  # `InstantRecord.tick` (wasm Ruby cannot sleep without blocking the VM).
  module Client
    # Columns the gem keeps for its own bookkeeping. A remote value that differs
    # in these alone is not a change to the row, it is our own write being
    # acknowledged twice.
    BOOKKEEPING_COLUMNS = %w[server_version sync_state].freeze

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
        instrument("bootstrap") do |event|
          body = transport.get_json("/bootstrap")
          records = Array(body["records"])
          records.each { |record| apply_change(record) }
          event[:records] = records.size

          # Cursor written last: a crash mid-apply leaves it nil, so the next
          # tick re-bootstraps; upserts make the retry idempotent. A failure
          # never falls through to a cursor-0 poll of the full change log.
          self.cursor = body["cursor"]
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
          body = transport.post_json("/mutations", { mutations: mutations })
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

        instrument("poll") do |note|
          transport.each_event("/events?after=#{cursor}&window=0") do |event|
            event = event.deep_stringify_keys
            if apply_change(event)
              changed = true
              applied += 1
            end
            last_cursor = event["cursor"] || last_cursor
          end
          note[:applied] = applied

          # One cursor write per poll, not per event. A crash before this line
          # re-applies the batch next poll; upserts + LWW make that idempotent.
          self.cursor = last_cursor if last_cursor
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
            case result["status"]
            when "applied"
              # `skipped` is the server saying it threw this write away to
              # last-write-wins. It is resolved (nothing will retry it) but it
              # never landed, so marking the record synced would badge a
              # discarded write as delivered — the record does not hold what the
              # server holds. Reconcile to the winner, which rides along with the
              # result; the same value also arrives over the change stream, which
              # is what makes doing nothing here look fine until the stream is
              # behind.
              if result["skipped"]
                reconcile_to_server_state(mutation, result)
              else
                mark_synced(mutation, result["version"])
              end
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
        return if reconcile_to_server_state(mutation, result)

        # The server never accepted this record (rejected create): remove it.
        InstantRecord.synced_model(mutation.record_type)&.find_by(id: mutation.record_id)&.destroy!
      end

      # Roll the local record onto the server's own copy of the row, when the
      # result carries one. Returns whether it did — the caller distinguishes
      # "the server has no such row" from "the server has this row".
      #
      # Authoritative: the server told us what it holds in answer to a write of
      # ours it would not take, so its row wins here regardless of timestamps.
      def reconcile_to_server_state(mutation, result)
        model = InstantRecord.synced_model(mutation.record_type)
        return false unless model && result["server_attributes"].present?

        upsert_from_server(model, result["server_attributes"], result["version"], authoritative: true)
        true
      end

      # Returns whether the row actually moved. Every accepted write comes back
      # down the change stream, so a client is constantly re-applying its own
      # rows; treating those as changes would announce them, and an announcement
      # reloads any page without an in-place refresh.
      #
      # Client-side last-write-wins, with the tie-break stated on purpose: a
      # remote value must be strictly NEWER to replace a local one, so equal
      # stamps leave the row alone. Equal stamps are the ordinary case, not the
      # exotic one — every write we make comes back with the timestamp we sent —
      # and applying those echoes would re-save the row, announce a change to
      # every tab, and fire the host app's after_save callbacks for a value that
      # never moved. Until both paths carried microseconds, rounding hid this by
      # making an echo look older than its own row; the rule has to be explicit
      # instead of an artifact of truncation.
      #
      # The two sides break ties in opposite directions deliberately:
      # MutationApplier#stale? is strict too, so the server ACCEPTS an
      # equal-stamped client mutation. A tie is therefore settled once, on the
      # server, and never has to be settled again here. (Both sides still compare
      # two machines' wall clocks with no logical clock. Microsecond stamps make
      # a coincidental tie far less likely than millisecond ones did, so the
      # tie-break matters less than it used to — but a client whose clock runs
      # ahead still wins writes it should lose, and that is unchanged.)
      # `authoritative` skips the comparison entirely, for the one case where the
      # server's row is the answer no matter what the clocks say: reconciling a
      # rejection. A rejected update is the ordinary case here, and the server's
      # un-updated row is necessarily OLDER than the optimistic local row that it
      # refused — so last-write-wins would drop it, the outbox row would still be
      # destroyed, and the record would keep the value the server just refused
      # and sit at `pending` forever. Nothing was discarded remotely in that
      # case, so the discard seam does not fire either.
      def upsert_from_server(model, attributes, version, authoritative: false)
        return false unless attributes

        # Schema skew must not raise here either: a client behind the server is
        # sent columns it has not migrated yet. They are the server's to keep;
        # this runtime converges on the columns it actually has.
        attributes = attributes.slice(*model.column_names)
        record = model.find_or_initialize_by(id: attributes["id"])

        incoming_at = attributes["updated_at"] && Time.parse(attributes["updated_at"].to_s)
        local_at = record.persisted? ? record.updated_at : nil

        record.assign_attributes(attributes.except("id", "server_version"))

        if !authoritative && incoming_at && local_at && incoming_at <= local_at
          # The remote value lost. This is the last moment it exists in this
          # runtime — nothing downstream sees it, which is why models get a seam.
          if (record.changed - BOOKKEEPING_COLUMNS).any?
            model.instant_record_discarded_change_handler&.call(attributes)
          end
          return false
        end

        record.server_version = version || attributes["server_version"] || 0
        record.sync_state = "synced"
        return false unless record.changed?

        record.save!(validate: false)
        true
      end

      def log_failure(phase, error)
        instrument("offline", phase: phase, error: error.message)
        warn "[instant_record] #{phase} failed (offline?): #{error.message}"
      end

      # Every meaningful sync outcome is announced through
      # ActiveSupport::Notifications — the seam a host app subscribes to for
      # logging or metrics, and the one the browser runtime's forwarder turns
      # into inspector entries (see Client::Instrumentation). Ruby authors the
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
