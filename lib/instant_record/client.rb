require "json"
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

    # SyncMetadata key prefixes for durable history tracking. Windowed models
    # store per-partition contiguity low-water marks under HISTORY_WINDOW_PREFIX;
    # non-windowed / opaque bridge keys live directly under HISTORY_KEY_PREFIX.
    HISTORY_KEY_PREFIX = "history:".freeze
    HISTORY_WINDOW_PREFIX = "history:window:".freeze

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

      # One full pass: outbox up, changes down, tabs notified when visible rows
      # moved. Called under InstantRecord.tick's single-flight guard. A client
      # that has never synced hydrates from the bootstrap snapshot instead of
      # replaying the whole change log from cursor 0.
      #
      # Returns whether local SQLite state changed (including pure outbox acks,
      # so the worker persists the drained outbox), while `notify_changed` only
      # fires when visible record data changed (evictions, reconciliations,
      # remote deltas, resets, or bootstrap).
      def sync_pass
        evicted = evict_beyond_windows
        drained, reconciled = drain_outbox
        pulled = bootstrapped? ? poll_changes : bootstrap
        notify_changed if evicted || reconciled || pulled
        evicted || drained || pulled
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
      # excluded in the WHERE — an unsynced write is never evicted. Any
      # partition whose rows were trimmed has its durable history mark
      # invalidated in the same SQLite transaction so later pagination
      # refetches instead of serving ghost empty pages. Returns true when
      # anything was deleted.
      def evict_beyond_windows
        return false unless @eviction_pending

        @eviction_pending = false
        evicted = false
        InstantRecord.syncable_models.each do |model|
          window = model.instant_record_sync_window
          next unless window

          applying_remote do
            evicted = true if evict_model_window(model, window)
          end
        end
        unlisted_changes if evicted
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
          entry.destroy if entry.key == "cursor" || entry.key == "identity" || entry.key.start_with?(HISTORY_KEY_PREFIX)
        end
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
          records = Array(body["records"])
          records.each { |record| apply_record(record) }
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
          unlisted_changes
          true
        end
      rescue Transport::Error => e
        log_failure("bootstrap", e)
        false
      end

      # Outbox up. Returns true when anything was sent and applied.
      def drain
        drain_outbox.first
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
        before_at = parse_time(before[:created_at].to_s)
        before_id = before[:id].to_s

        unless InstantRecord.browser?
          return { ok: true, applied: 0, has_more: local_page(window, partition, before_at, before_id, limit + 1).size > limit }
        end

        if (local = local_history_page(model, window, partition, before_at, before_id, limit))
          return local
        end

        instrument("fetch_history") do |event|
          body = transport.get_json(history_path(model, partition, before_at, before_id, limit))
          result = apply_history_page(model, partition, Array(body["records"]), has_more: !!body["has_more"])
          event[:applied] = result[:applied]
          event[:has_more] = result[:has_more]
          result
        end
      rescue Transport::Error => e
        log_failure("fetch_history", e)
        { ok: false, applied: 0, has_more: nil, error: e.message }
      end

      # Unified history entry point for the compiled bridges (WasmBridge and
      # NativeBridge). Windowed keyset queries share the durable SQLite
      # contiguity ledger with fetch_history; non-windowed queries (search,
      # thread lookups, and opaque Native screen keys) keep their per-key
      # receipt in SyncMetadata in the same transaction as their records.
      def handle_history(key:, response: "")
        key = key.to_s
        response = response.to_s

        if (query = parse_windowed_history_key(key))
          handle_windowed_history(query, response)
        else
          handle_opaque_history(key, response)
        end
      end

      # Server results for a posted batch. Every result drops the outbox row —
      # each one is a durable resolution, not a retry — and what happens to the
      # record depends on which resolution it is:
      # applied           -> mark the record synced (pure bookkeeping, stays quiet)
      # applied + skipped -> the write lost last-write-wins; reconcile to the
      #                      value that won, because it did NOT land here
      # rejected          -> reconcile to server state
      #
      # Returns whether any result changed visible local record data (a rollback
      # or removal), as distinct from pure self-acknowledgements.
      def apply_results(results)
        reconciled = false
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
                reconciled = true if reconcile_to_server_state(mutation, result)
              else
                mark_synced(mutation, result["version"])
              end
            when "rejected"
              reconciled = true if reconcile_rejection(mutation, result)
            end
            mutation.destroy!
          end
        end
        reconciled
      end

      # Apply one remote change event (last-write-wins) and note it for the next
      # records_changed notice. Returns whether it actually changed anything
      # here — see upsert_from_server.
      def apply_change(event)
        event = event.deep_stringify_keys
        applied = apply_record(event)
        note_change(event["type"], event["id"]) if applied
        applied
      end

      # Apply one remote record payload without noting it for records_changed
      # (used by bootstrap and history pages, which handle notification separately).
      def apply_record(event)
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

      # Durable contiguity low-water marks, one per (model, partition), stored
      # in SyncMetadata so CRuby, WASM, and Native share one SQLite-backed
      # ledger. Row count alone cannot prove a local page has no holes (live
      # updates re-create evicted rows as strays); each mark tracks the oldest
      # boundary of contiguously fetched history plus the server's last
      # has_more answer.
      def history_mark_key(model, partition)
        partition.nil? ? "#{HISTORY_WINDOW_PREFIX}#{model.name}" : "#{HISTORY_WINDOW_PREFIX}#{model.name}/#{partition}"
      end

      def history_mark(model, partition)
        raw = SyncMetadata.get(history_mark_key(model, partition))
        return nil if raw.nil? || raw.empty?

        data = JSON.parse(raw)
        return nil unless data.is_a?(Hash) && (data["has_more"] == true || data["has_more"] == false)

        oldest_at = data["oldest_at"]
        oldest_id = data["oldest_id"]
        {
          oldest_at: oldest_at ? parse_time(oldest_at.to_s) : nil,
          oldest_id: oldest_id.nil? ? nil : oldest_id.to_s,
          has_more: data["has_more"]
        }
      rescue JSON::ParserError, ArgumentError
        nil
      end

      def write_history_mark(model, partition, mark)
        payload = {
          "oldest_at" => mark[:oldest_at] ? mark[:oldest_at].utc.iso8601(InstantRecord::TIME_PRECISION) : nil,
          "oldest_id" => mark[:oldest_id],
          "has_more" => !!mark[:has_more]
        }
        SyncMetadata.set(history_mark_key(model, partition), JSON.generate(payload))
      end

      def apply_history_page(model, partition, records, has_more:)
        SyncMetadata.transaction do
          records.each { |record| apply_record(record) }
          extend_history_mark(model, partition, records, has_more: has_more)
        end
        { ok: true, applied: records.size, has_more: has_more }
      end

      def extend_history_mark(model, partition, records, has_more:)
        oldest = oldest_record_boundary(model, records)
        mark = history_mark(model, partition)

        if mark.nil?
          write_history_mark(model, partition, {
            oldest_at: oldest ? oldest[0] : nil,
            oldest_id: oldest ? oldest[1] : nil,
            has_more: has_more
          })
          return
        end

        if oldest && (mark[:oldest_at].nil? || compare_boundary(oldest, [mark[:oldest_at], mark[:oldest_id]]) < 0)
          mark[:oldest_at] = oldest[0]
          mark[:oldest_id] = oldest[1]
          mark[:has_more] = has_more
          write_history_mark(model, partition, mark)
        elsif !has_more && mark[:has_more]
          mark[:has_more] = false
          write_history_mark(model, partition, mark)
        end
      end

      def handle_windowed_history(query, response)
        if response.empty?
          return local_history_page(
            query[:model], query[:window], query[:partition],
            query[:before_at], query[:before_id], query[:limit]
          ) || { ok: false, applied: 0, has_more: false }
        end

        page = JSON.parse(response)
        apply_history_page(
          query[:model], query[:partition],
          Array(page["records"]),
          has_more: page["has_more"] == true
        )
      end

      def handle_opaque_history(key, response)
        meta_key = HISTORY_KEY_PREFIX + key
        if response.empty?
          mark = SyncMetadata.get(meta_key)
          return { ok: !mark.nil?, applied: 0, has_more: mark == "more" }
        end

        page = JSON.parse(response)
        records = Array(page["records"])
        more = page["has_more"] == true
        SyncMetadata.transaction do
          records.each { |record| apply_record(record) }
          SyncMetadata.set(meta_key, more ? "more" : "end")
        end
        { ok: true, applied: records.size, has_more: more }
      end

      def oldest_record_boundary(model, records)
        oldest = nil
        records.each do |raw|
          record = raw.is_a?(Hash) ? raw.deep_stringify_keys : nil
          next unless record
          next if record["type"] && record["type"] != model.name

          attrs = record["attributes"]
          next unless attrs.is_a?(Hash) && attrs["created_at"]

          id = record["id"] || attrs["id"]
          next if id.nil?

          candidate = [parse_time(attrs["created_at"].to_s), id.to_s]
          oldest = candidate if oldest.nil? || compare_boundary(candidate, oldest) < 0
        end
        oldest
      end

      # Serve a page from SQLite when the durable mark proves contiguity: either
      # the beginning of history was already reached (has_more == false), or
      # `limit` local rows below `before` sit at or above the low-water mark.
      def local_history_page(model, window, partition, before_at, before_id, limit)
        mark = history_mark(model, partition)
        return nil unless mark

        if mark[:has_more] == false
          # has_more from the served page, not the partition-wide mark: rows
          # remain below this page when the local probe overflows `limit`.
          # Echoing the mark alone reports "beginning reached" for any
          # mid-history page after the true beginning was loaded.
          rows = local_page(window, partition, before_at, before_id, limit + 1)
          return { ok: true, applied: 0, has_more: rows.size > limit }
        end

        return nil if mark[:oldest_at].nil?

        boundary = [mark[:oldest_at], mark[:oldest_id]]
        rows = local_page(window, partition, before_at, before_id, limit)
        return nil unless rows.size >= limit && rows.all? { |row| compare_boundary(row, boundary) >= 0 }

        { ok: true, applied: 0, has_more: true }
      end

      def evict_model_window(model, window)
        evicted = false
        SyncMetadata.transaction do
          scope = window.beyond_window(model.where.not(sync_state: "pending"))
          if window.partition_by
            affected = scope.pluck(window.partition_by).uniq
            if affected.any? && scope.delete_all.positive?
              evicted = true
              invalidate_history_marks(model, partitions: affected)
            end
          elsif scope.delete_all.positive?
            evicted = true
            invalidate_history_marks(model)
          end
        end
        evicted
      end

      def invalidate_history_marks(model, partitions: nil)
        partition_set = partitions ? partitions.map(&:to_s) : nil
        window_prefix = "#{HISTORY_WINDOW_PREFIX}#{model.name}"

        SyncMetadata.all.each do |entry|
          key = entry.key
          next unless key.start_with?(HISTORY_KEY_PREFIX)

          if key == window_prefix
            entry.destroy if partition_set.nil?
          elsif key.start_with?("#{window_prefix}/")
            partition = key.delete_prefix("#{window_prefix}/")
            entry.destroy if partition_set.nil? || partition_set.include?(partition)
          elsif legacy_model_history_key?(key, model.name, partition_set)
            entry.destroy
          end
        end
      end

      def legacy_model_history_key?(key, model_name, partition_set)
        raw = key.delete_prefix(HISTORY_KEY_PREFIX)
        return false unless raw.include?("=")

        params = decode_query_params(raw)
        return false unless params && params["type"] == model_name
        return true if partition_set.nil?

        partition = params["partition"]
        partition.nil? || partition_set.include?(partition)
      end

      def parse_windowed_history_key(key)
        return nil unless key.include?("=")

        params = decode_query_params(key)
        return nil unless params
        return nil if params["search"] || params["thread"]

        type = params["type"]
        return nil if type.nil? || type.empty?

        model = InstantRecord.synced_model(type)
        window = model&.instant_record_sync_window
        return nil unless window

        before_created_at = params["before_created_at"]
        before_id = params["before_id"]
        return nil if before_created_at.nil? || before_created_at.empty? || before_id.nil? || before_id.empty?

        partition = params["partition"]
        return nil if window.partition_by && (partition.nil? || partition.empty?)

        raw_limit = params["limit"].to_i
        {
          model: model,
          window: window,
          partition: window.partition_by ? partition.to_s : nil,
          before_at: parse_time(before_created_at),
          before_id: before_id.to_s,
          limit: raw_limit.positive? ? raw_limit : window.limit
        }
      rescue ArgumentError
        nil
      end

      # Pure-Ruby application/x-www-form-urlencoded parser so WASM and Native
      # builds do not pull in Ruby's URI package on the WasmBridge.history path.
      def decode_query_params(raw)
        params = {}
        raw.split("&").each do |pair|
          next if pair.empty?

          eq = pair.index("=")
          return nil unless eq

          key = decode_query_component(pair[0...eq])
          val = decode_query_component(pair[(eq + 1)..] || "")
          params[key] = val
        end
        params
      end

      def decode_query_component(str)
        text = str.tr("+", " ")
        return text unless text.include?("%")

        bytes = text.b
        out = +"".b
        i = 0
        len = bytes.bytesize
        while i < len
          byte = bytes.getbyte(i)
          if byte == 37 && i + 2 < len
            hex = bytes.byteslice(i + 1, 2)
            if hex.match?(/\A[0-9A-Fa-f]{2}\z/)
              out << hex.to_i(16)
              i += 3
              next
            end
          end
          out << byte
          i += 1
        end
        out.force_encoding(Encoding::UTF_8)
      end

      def compare_boundary(a, b)
        cmp = a[0] <=> b[0]
        cmp == 0 ? (a[1] <=> b[1]) : cmp
      end

      # Normalize Ruby Time, ActiveSupport::TimeWithZone, ISO 8601 strings, and
      # bare SQLite UTC datetime strings ("YYYY-MM-DD HH:MM:SS.ffffff") to UTC
      # so boundary comparisons never drift on non-UTC host machines.
      def parse_time(value)
        return value.utc if value.is_a?(Time)
        return value.to_time.utc if !value.is_a?(String) && value.respond_to?(:to_time)

        text = value.to_s.strip
        raise ArgumentError, "blank timestamp" if text.empty?

        if text.match?(/(?:Z|[+-]\d{2}:?\d{2}|UTC)\z/i)
          Time.parse(text).utc
        else
          Time.parse("#{text} UTC").utc
        end
      end

      # Keyset page below (before_at, before_id), newest first, as
      # [created_at, id] tuples.
      def local_page(window, partition, before_at, before_id, limit)
        window
          .keyset_below(at: before_at, id: before_id, partition: partition)
          .limit(limit)
          .pluck(:created_at, window.model.primary_key)
          .map { |at, id| [parse_time(at), id.to_s] }
      end

      def history_path(model, partition, before_at, before_id, limit)
        params = { type: model.name, before_created_at: before_at.utc.iso8601(6), before_id: before_id, limit: limit }
        params[:partition] = partition if partition
        "/records?#{URI.encode_www_form(params)}"
      end

      def drain_outbox
        mutations = pending_mutations
        return [false, false] if mutations.empty?

        instrument("drain") do |event|
          body = transport.post_json("/mutations", mutations_payload(mutations))
          reconciled = apply_results(body["results"])

          results = Array(body["results"]).map { |r| r.deep_stringify_keys }
          event[:posted] = mutations.size
          event[:rejected] = results.count { |r| r["status"] == "rejected" }
          event[:reasons] = results.filter_map { |r| r["reason"] }.uniq.first(3)
          [true, reconciled]
        end
      rescue Transport::Error => e
        log_failure("drain", e)
        [false, false]
      end

      def mark_synced(mutation, version)
        model = InstantRecord.synced_model(mutation.record_type)
        record = model&.find_by(id: mutation.record_id)
        return unless record

        record.update_columns(sync_state: "synced", server_version: version || record.server_version)
      end

      def reconcile_rejection(mutation, result)
        return reconcile_to_server_state(mutation, result) if result["server_attributes"].present?

        # The server never accepted this record (rejected create): remove it.
        destroyed = !!InstantRecord.synced_model(mutation.record_type)&.find_by(id: mutation.record_id)&.destroy!
        note_change(mutation.record_type, mutation.record_id) if destroyed
        destroyed
      end

      # Roll the local record onto the server's own copy of the row, when the
      # result carries one. Returns whether visible local row data changed.
      #
      # Authoritative: the server told us what it holds in answer to a write of
      # ours it would not take, so its row wins here regardless of timestamps.
      def reconcile_to_server_state(mutation, result)
        model = InstantRecord.synced_model(mutation.record_type)
        return false unless model && result["server_attributes"].present?

        changed = upsert_from_server(model, result["server_attributes"], result["version"], authoritative: true)
        note_change(mutation.record_type, mutation.record_id) if changed
        changed
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

        data_changed = !record.persisted? || (record.changed - BOOKKEEPING_COLUMNS).any?
        if data_changed
          record.save!(validate: false)
        else
          record.update_columns(sync_state: record.sync_state, server_version: record.server_version)
        end
        data_changed
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
