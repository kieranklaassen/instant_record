require "json"
require "uri"
require "time"
require "active_support/notifications"
require "instant_record/client/transport"
require "instant_record/client/notifier"
require "instant_record/client/rebaser"

module InstantRecord
  # Ruby reconciles local records and queued mutations. The worker handles network I/O.
  module Client
    # Columns the gem keeps for its own bookkeeping. A remote value that differs
    # in these alone is not a change to the row, it is our own write being
    # acknowledged twice.
    BOOKKEEPING_COLUMNS = %w[server_version sync_state].freeze

    # More changes than this in one notice are not listed one by one.
    MAX_LISTED_CHANGES = 200

    # Cap buffered ActiveSupport::Notifications per host call so a runaway loop
    # cannot exhaust the browser VM's heap.
    MAX_RECORDED_EVENTS = 200

    # SyncMetadata key prefixes for durable history tracking. Windowed models
    # store per-partition contiguity low-water marks under HISTORY_WINDOW_PREFIX;
    # non-windowed / opaque bridge keys live directly under HISTORY_KEY_PREFIX.
    HISTORY_KEY_PREFIX = "history:".freeze
    HISTORY_WINDOW_PREFIX = "history:window:".freeze

    # Upper bound on bounded batches drained in a single synchronous pass.
    MAX_DRAIN_CHUNKS_PER_PASS = 50

    DRAIN_BATCH_LIMIT_KEY = "drain_batch_limit".freeze
    RETRY_PREFIX = "outbox_5xx:".freeze
    QUARANTINE_PREFIX = "quarantined:".freeze

    # Individual attribute values larger than this are omitted from delta attrs
    # (their column stays in changed_columns so UI patchers know to reload).
    MAX_ATTR_BYTES = 4096

    # Cap total serialized notice size so a huge batch degrades to a wildcard.
    MAX_NOTICE_BYTES = 65_536

    # Cap next_release_ms to 24 hours so it always fits safely inside a signed
    # 32-bit integer on wasm32 Spinel builds.
    MAX_RELEASE_DELAY_MS = 86_400_000

    class << self
      # Applying remote state must never enqueue new outbox mutations.
      def applying_remote? = @applying_remote
      def applying_remote(&block)
        previous = @applying_remote
        @applying_remote = true
        block.call
      ensure
        @applying_remote = previous
      end

      def current_hold_for = @hold_for

      def enter_hold(seconds)
        if seconds.nil?
          normalized = nil
        else
          normalized = seconds.to_f
          raise ArgumentError, "hold_for must be non-negative" if normalized < 0.0
          normalized = nil if normalized == 0.0
        end

        previous = @hold_for
        @hold_for = normalized
        previous
      end

      def leave_hold(previous)
        @hold_for = previous
      end

      # Hold local outbox writes created inside the block for `seconds` before
      # they mature for drain. Nested calls restore the outer hold window.
      def with_hold(seconds)
        previous = enter_hold(seconds)
        yield
      ensure
        leave_hold(previous)
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

      # Pluggable client-side headers sent on every outbound sync request
      # (bootstrap, mutations, events, history). Merges:
      #   1. X-Instant-Record-Scope      (from config.sync_scope)
      #   2. X-Instant-Record-Partition  (from config.sync_partition)
      #   3. Authorization               (from config.auth_token)
      #   4. Custom headers              (from config.headers — Hash or callable)
      def request_headers
        result = {}
        config = InstantRecord.config
        scope = config.sync_scope
        result["X-Instant-Record-Scope"] = scope.to_s if scope && !scope.to_s.empty?

        partition = config.sync_partition
        formatted = format_partition_header(partition)
        result["X-Instant-Record-Partition"] = formatted if formatted

        token = config.auth_token
        if token && !token.to_s.empty?
          str = token.to_s
          result["Authorization"] = str.include?(" ") ? str : "Bearer #{str}"
        end

        extra = config.headers.respond_to?(:call) ? config.headers.call : config.headers
        if extra.is_a?(Hash)
          extra.each do |name, value|
            result[name.to_s] = value.to_s if value && !value.to_s.empty?
          end
        end
        result
      end

      # Background history-fill targets declared by the server's bootstrap response.
      def fill_targets
        raw = SyncMetadata.get("history_fill_targets")
        raw ? JSON.parse(raw) : []
      rescue JSON::ParserError
        []
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
        return false if InstantRecord.branched?

        evicted = evict_beyond_windows
        drained, reconciled = drain_outbox
        pulled = bootstrapped? ? poll_changes : bootstrap
        notify_changed if evicted || reconciled || pulled || recorded_notices.any?
        evicted || drained || pulled
      end

      # Which records changed since the page was last told: "records_changed"
      # followed by one compact JSON delta per line:
      #   {"type":"MailEntry","id":"a-1","op":"update","changed_columns":[...],"attrs":{...}}
      # plus any quarantined sync notices as "sync_notice:<json>" lines. The
      # notice alone means anything may have changed (bootstrap, eviction,
      # reset, or a batch past the listing or byte budget).
      def changes_notice
        lines = ["records_changed"]
        unless @unlisted_changes || changed_records.empty?
          delta_lines = changed_records.map { |delta| JSON.generate(delta) }
          delta_payload = "records_changed\n" + delta_lines.join("\n")
          lines.concat(delta_lines) if delta_payload.bytesize <= MAX_NOTICE_BYTES
        end
        recorded_notices.each { |notice| lines << "sync_notice:#{JSON.generate(notice)}" }
        lines.join("\n")
      end

      def changed_records
        @changed_records ||= []
      end

      def recorded_notices
        @recorded_notices ||= []
      end

      def unlisted_changes
        @unlisted_changes = true
      end

      def capturing_changes?
        !!@capturing_changes
      end

      # Capture local Syncable writes during a request or native action and
      # flush them to the notifier when the block completes normally.
      def capture_local_changes
        nested = @capturing_changes
        @capturing_changes = true
        unless nested
          changed_records.clear
          changed_index.clear
          @unlisted_changes = false
        end
        result = yield
        if !nested && (@unlisted_changes || !changed_records.empty?)
          notify_changed
        end
        result
      rescue StandardError
        unless nested
          changed_records.clear
          changed_index.clear
          @unlisted_changes = false
        end
        raise
      ensure
        @capturing_changes = nested
      end

      def note_change(type, id, op: "update", changed_columns: [], attrs: {})
        return if @unlisted_changes

        changed_index.clear if changed_records.empty?
        key = "#{type}\0#{id}"
        delta = {
          "type" => type.to_s,
          "id" => id.to_s,
          "op" => op.to_s,
          "changed_columns" => Array(changed_columns).map(&:to_s).uniq,
          "attrs" => compact_attrs(attrs)
        }

        if (existing_idx = changed_index[key])
          changed_records[existing_idx] = merge_delta(changed_records[existing_idx], delta)
        elsif changed_records.size >= MAX_LISTED_CHANGES
          unlisted_changes
        else
          changed_index[key] = changed_records.size
          changed_records << delta
        end
      end

      def note_record_change(record, op, changed_columns: nil)
        return if @unlisted_changes

        model = record.class
        raw = record.attributes
        op_s = op.to_s
        case op_s
        when "create"
          cols = raw.keys.map(&:to_s)
          note_change(model.name, record.id, op: "create", changed_columns: cols, attrs: compact_attrs(raw))
        when "update"
          cols = Array(changed_columns).map(&:to_s).uniq
          selected = {}
          cols.each { |col| selected[col] = raw[col] if raw.key?(col) }
          context_columns_for(model, raw).each { |col| selected[col] = raw[col] if raw.key?(col) }
          note_change(model.name, record.id, op: "update", changed_columns: cols, attrs: compact_attrs(selected))
        when "destroy"
          selected = {}
          context_columns_for(model, raw).each { |col| selected[col] = raw[col] if raw.key?(col) }
          note_change(model.name, record.id, op: "destroy", changed_columns: [], attrs: compact_attrs(selected))
        else
          note_change(model.name, record.id, op: op_s)
        end
      end

      def notify_changed
        notifier.records_changed
        changed_records.clear
        changed_index.clear
        recorded_notices.clear
        @unlisted_changes = false
      end

      # Bridged notifications captured during the current host call so the JS
      # worker receives ActiveSupport::Notifications across the WASI boundary.
      def recorded_events
        @recorded_events ||= []
      end

      def clear_events
        recorded_events.clear
        nil
      end

      def events_notice
        JSON.generate(recorded_events)
      end

      def drain_events
        snapshot = recorded_events.dup
        recorded_events.clear
        snapshot
      end

      # Arm the boot-time trim; InstantRecord.start sets this on cold boots
      # only. Runs once, on the next sync pass.
      def request_eviction
        @eviction_pending = true
      end

      # Trim every windowed model back to its declared window. delete_all
      # under applying_remote: no callbacks, no outbox rows. Pending rows are
      # excluded before ranking — unsynced writes are never evicted and never
      # push synced rows out of the window. Any partition whose rows were
      # trimmed has its durable history mark invalidated in the same SQLite
      # transaction so later pagination refetches instead of serving ghost empty
      # pages. Returns true when anything was deleted.
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

      def pending_count(now = Time.now.utc)
        return OutboxMutation.matured(now).count unless OutboxMutation.held(now).exists?

        matured_outbox_rows(now).size
      end

      # Matured outbox rows ready to drain (release_at IS NULL OR release_at <= now).
      # Preserves per-record causal order: a later write to a record with an earlier
      # held mutation waits behind it, while independent records drain immediately.
      def pending_mutations(now = Time.now.utc)
        matured_outbox_rows(now).map(&:as_mutation)
      end

      # Snapshot the exact outgoing mutation batch for a two-phase host sync
      # (sync_plan -> network fetch -> sync). Pinning the planned IDs prevents
      # a held mutation that matures mid-fetch from altering the batch body
      # between sync_plan and drain.
      def plan_drain(now = Time.now.utc)
        mutations = drain_batch(now: now)
        @planned_drain_ids = mutations.map { |m| m[:id] }
        mutations
      end

      def clear_planned_drain
        @planned_drain_ids = nil
      end

      def held_mutations(now = Time.now.utc)
        OutboxMutation.held(now).ordered
      end

      def held_count(now = Time.now.utc)
        OutboxMutation.held(now).count
      end

      def next_release_at(now = Time.now.utc)
        OutboxMutation.held(now).order(:release_at, :created_at, :id).first&.release_at
      end

      def next_release_ms(now = Time.now.utc)
        release_at = next_release_at(now)
        return nil unless release_at

        seconds = release_at.to_f - now.to_f
        return 0 if seconds <= 0.0
        return MAX_RELEASE_DELAY_MS if seconds >= 86_400.0

        (seconds * 1000.0).ceil
      end

      # Cancel a held outbox mutation before its release_at matures: restore the
      # local SQLite row from its pre-mutation snapshot and delete the outbox row
      # atomically. Returns true when cancelled, false when unknown, already
      # released/matured, or superseded by a later outbox mutation on the same row.
      def cancel_pending(mutation_id, now: Time.now.utc)
        cancelled = nil

        OutboxMutation.transaction do
          mutation = OutboxMutation.find_by(id: mutation_id)
          next unless mutation && mutation.held?(now)

          later = OutboxMutation.where(record_type: mutation.record_type, record_id: mutation.record_id)
            .where("created_at > :at OR (created_at = :at AND id > :id)", at: mutation.created_at, id: mutation.id)
            .exists?
          next if later

          model = InstantRecord.synced_model(mutation.record_type)
          next unless model

          earlier_pending = OutboxMutation.where(record_type: mutation.record_type, record_id: mutation.record_id)
            .where.not(id: mutation.id)
            .exists?

          restored = applying_remote do
            if Rebaser.confirmed_snapshot(mutation.record_type, mutation.record_id) &&
                (mutation.operation == "create" || mutation.rollback_payload.is_a?(Hash))
              Rebaser.reconcile_quarantined_mutation(mutation)
              true
            else
              case mutation.operation
              when "create"
                model.find_by(id: mutation.record_id)&.destroy!
                mutation.destroy!
                true
              when "update", "destroy"
                if mutation.rollback_payload.is_a?(Hash)
                  restore_record(model, mutation, earlier_pending: earlier_pending)
                  mutation.destroy!
                  true
                else
                  false
                end
              else
                false
              end
            end
          end
          next unless restored

          Rebaser.clear_confirmed_snapshot(mutation.record_type, mutation.record_id) unless earlier_pending
          cancelled = {
            mutation_id: mutation.id,
            record_type: mutation.record_type,
            record_id: mutation.record_id,
            operation: mutation.operation
          }
        end

        return false unless cancelled

        instrument("cancel_pending", cancelled)
        true
      end

      # Next bounded chunk of matured outbox mutations to POST. Respects
      # `config.drain_batch_size`, adaptive 5xx bisection limits, and per-record
      # causal ordering behind held (`hold_for:`) mutations.
      def drain_batch(limit: effective_drain_batch_size, now: Time.now.utc)
        matured_outbox_rows(now).first(limit).map(&:as_mutation)
      end

      def effective_drain_batch_size
        configured = [InstantRecord.config.drain_batch_size.to_i, 1].max
        adaptive = SyncMetadata.get(DRAIN_BATCH_LIMIT_KEY)&.to_i
        adaptive && adaptive.positive? ? [configured, adaptive].min : configured
      end

      def quarantined_mutations
        entries = []
        SyncMetadata.all.each do |entry|
          next unless entry.key.start_with?(QUARANTINE_PREFIX)

          entries << JSON.parse(entry.value)
        rescue JSON::ParserError
          next
        end
        entries.sort_by { |e| [e["quarantined_at"].to_s, e["mutation_id"].to_s] }
      end

      def clear_quarantined_mutations
        SyncMetadata.all.each do |entry|
          entry.destroy if entry.key.start_with?(QUARANTINE_PREFIX)
        end
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
        destroyed_ids = []
        OutboxMutation.all.each do |mutation|
          drop = types.include?(mutation.record_type)
          if !drop && mutation.mutator?
            mutation.touched_records.each do |entry|
              if types.include?(entry["type"])
                drop = true
                break
              end
            end
          end
          if drop
            destroyed_ids << mutation.id
            mutation.destroy
          end
        end
        Rebaser.reset_types(types)
        SyncNotice.all.each do |notice|
          notice.destroy if types.include?(notice.record_type)
        end
        # The rows that stay were last brought up to date at this cursor. The
        # bootstrap to come only adds and changes rows, so the poll after it
        # starts here again and a destroy made in between is not missed.
        SyncMetadata.set("replay_from", cursor) if bootstrapped? && SyncMetadata.get("replay_from").nil?
        SyncMetadata.all.each do |entry|
          if entry.key == "cursor" || entry.key == "identity" || entry.key == DRAIN_BATCH_LIMIT_KEY ||
              entry.key.start_with?(HISTORY_KEY_PREFIX) ||
              types.any? { |type| entry.key.start_with?("#{HLC::ROW_PREFIX}#{type}:") } ||
              (entry.key.start_with?(RETRY_PREFIX) && destroyed_ids.include?(entry.key[RETRY_PREFIX.length..]))
            entry.destroy
          elsif entry.key.start_with?(QUARANTINE_PREFIX)
            parsed = begin JSON.parse(entry.value) rescue nil end
            entry.destroy if parsed && types.include?(parsed["record_type"])
          end
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
        return false if InstantRecord.branched?

        instrument("bootstrap") do |event|
          body = transport_get_json("/bootstrap")
          event[:records] = apply_bootstrap_body(body)
          true
        end
      rescue Transport::Error => e
        log_failure("bootstrap", e)
        false
      end

      # Outbox up in bounded batches. Halves batch size on multi-mutation 5xx
      # responses and isolates a single poison pill after N 5xx retries so
      # healthy mutations behind it keep draining. Returns true when anything
      # was sent, applied, or quarantined.
      def drain
        return false if InstantRecord.branched?

        drain_outbox.first
      end

      # Merge pre-fetched push and/or bootstrap responses from an async worker
      # into the current SQLite state by mutation_id, without discarding acks
      # when newer local edits landed while the network call was in flight.
      # Pure self-acks persist SQLite (`changed: true`) while staying quiet on
      # `records_changed`; evictions, reconciliations, quarantines, and
      # bootstrap still notify tabs.
      def apply_prepared_sync(push: nil, bootstrap: nil)
        return { changed: false, progressed: false, failed: false, quarantined: 0 } if InstantRecord.branched?

        evicted = evict_beyond_windows
        changed = evicted
        reconciled = false
        bootstrapped_now = false
        progressed = false
        failed = false
        quarantined = 0

        if push
          push = push.deep_stringify_keys
          status = push["status"].to_i
          sent_ids = Array(push["mutation_ids"]).map(&:to_s)

          if status >= 200 && status < 300
            begin
              body = JSON.parse(push["body"].to_s)
              observe_server_time(body["server_time"])
              instrument("drain") do |event|
                results = Array(body["results"]).map { |r| r.deep_stringify_keys }
                resolved, batch_reconciled = apply_results_with_counts(results)
                clear_adaptive_batch_limit if pending_count == 0
                changed = true if resolved.positive?
                reconciled = true if batch_reconciled
                progressed = true if resolved.positive? || sent_ids.none? { |id| OutboxMutation.find_by(id: id) }
                event[:posted] = sent_ids.size
                event[:rejected] = results.count { |r| r["status"] == "rejected" }
                event[:reasons] = results.filter_map { |r| r["reason"] }.uniq.first(3)
                event[:batches] = 1
                event[:quarantined] = 0
              end
            rescue JSON::ParserError => e
              log_failure("drain", Transport::Error.new("POST /mutations -> invalid JSON: #{e.message}", status: status))
              failed = true
            end
          elsif status >= 500 && status < 600
            outcome = handle_drain_failure(sent_ids, status: status, error: "POST /mutations -> #{status}")
            if outcome[:quarantined].positive?
              quarantined += outcome[:quarantined]
              changed = true
              reconciled = true if outcome[:reconciled]
              progressed = true
            else
              log_failure("drain", Transport::Error.new("POST /mutations -> #{status}", status: status))
              failed = true
            end
          else
            log_failure("drain", Transport::Error.new("POST /mutations -> #{status}", status: status))
            failed = true
          end
        end

        if bootstrap && !bootstrapped?
          bootstrap = bootstrap.deep_stringify_keys
          status = bootstrap["status"].to_i
          if status >= 200 && status < 300
            begin
              body = JSON.parse(bootstrap["body"].to_s)
              instrument("bootstrap") do |event|
                event[:records] = apply_bootstrap_body(body)
              end
              changed = true
              bootstrapped_now = true
              progressed = true
            rescue JSON::ParserError => e
              log_failure("bootstrap", Transport::Error.new("GET /bootstrap -> invalid JSON: #{e.message}", status: status))
              failed = true
            end
          else
            log_failure("bootstrap", Transport::Error.new("GET /bootstrap -> #{status}", status: status))
            failed = true
          end
        end

        notify_changed if evicted || reconciled || bootstrapped_now || recorded_notices.any?

        { changed: changed, progressed: progressed, failed: failed, quarantined: quarantined }
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
        changed_records.clear
        recorded_events.clear
        changed_index.clear
        recorded_notices.clear
        @unlisted_changes = false
        @capturing_changes = false
        @eviction_pending = false
        @planned_drain_ids = nil
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
        return false if streaming? || InstantRecord.branched?

        changed = false
        applied = 0
        last_cursor = nil
        was_reset = false
        key = identity_key
        path = "/events?after=#{cursor}&window=0"
        path += "&identity=#{key}" unless key.nil?

        instrument("poll") do |note|
          transport_each_event(path) do |event|
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
        before_at = parse_time(before[:created_at].to_s)
        before_id = before[:id].to_s

        unless InstantRecord.browser?
          return { ok: true, applied: 0, has_more: local_page(window, partition, before_at, before_id, limit + 1).size > limit }
        end

        if (local = local_history_page(model, window, partition, before_at, before_id, limit))
          return local
        end

        instrument("fetch_history") do |event|
          body = transport_get_json(history_path(model, partition, before_at, before_id, limit))
          observe_server_time(body["server_time"])
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
      # each one is a durable resolution, not a retry — and reconciles the row
      # through GGPO dirty-row rebasing so newer unacked local edits on the same
      # row are deterministically replayed over server truth instead of clobbered.
      #
      # Returns whether any result changed visible local record data (a rollback,
      # removal, or rebase delta), as distinct from pure self-acknowledgements.
      def apply_results(results)
        apply_results_with_counts(results).last
      end

      # Apply one remote change event (HLC-ordered, with updated_at fallback
      # for legacy events) and note it for the next records_changed notice.
      # Clean rows apply directly; dirty rows rewind to their server-confirmed
      # snapshot, apply server truth, and deterministically replay remaining
      # unacked mutations. Returns whether the visible row moved.
      def apply_change(event)
        apply_remote_event(event, record_delta: true)
      end

      # Apply one remote record payload without noting it for records_changed
      # (used by bootstrap and history pages, which handle notification separately).
      def apply_record(event)
        apply_remote_event(event, record_delta: false)
      end

      # Normalize Ruby Time, ActiveSupport::TimeWithZone, ISO 8601 strings, and
      # bare SQLite UTC datetime strings ("YYYY-MM-DD HH:MM:SS.ffffff") to UTC
      # so comparisons never drift on non-UTC host machines. Public for the rebaser
      # and branches, which read such times too. :nodoc:
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

      private

      def apply_remote_event(event, record_delta:)
        event = event.deep_stringify_keys
        model = InstantRecord.synced_model(event["type"])
        return false unless model

        record_id = event["id"] || (event["attributes"].is_a?(Hash) && event["attributes"]["id"])
        applying_remote do
          if record_id && Rebaser.dirty?(event["type"], record_id)
            Rebaser.apply_server_delta(
              model,
              record_id,
              operation: event["operation"],
              attributes: event["attributes"],
              version: event["version"],
              hlc: event["hlc"],
              record_delta: record_delta
            )
          elsif event["operation"] == "destroy"
            HLC.receive(event["hlc"]) if HLC.valid?(event["hlc"])
            HLC.delete_row_hlc(event["type"], record_id)
            record = model.find_by(id: record_id)
            return false unless record

            destroy_attrs = record_delta ? destroy_context_attrs(model, record) : nil
            record.destroy!
            note_change(event["type"], record_id, op: "destroy", changed_columns: [], attrs: destroy_attrs) if record_delta
            true
          else
            upsert_from_server(model, event["attributes"], event["version"], hlc: event["hlc"], record_delta: record_delta)
          end
        end
      end

      def changed_index
        @changed_index ||= {}
      end

      def merge_delta(prev, incoming)
        prev_op = prev["op"]
        next_op = incoming["op"]
        if next_op == "destroy"
          {
            "type" => incoming["type"],
            "id" => incoming["id"],
            "op" => "destroy",
            "changed_columns" => [],
            "attrs" => incoming["attrs"]
          }
        elsif prev_op == "destroy" && next_op == "create"
          incoming
        else
          merged_op = prev_op == "create" ? "create" : next_op
          {
            "type" => incoming["type"],
            "id" => incoming["id"],
            "op" => merged_op,
            "changed_columns" => (prev["changed_columns"] + incoming["changed_columns"]).uniq,
            "attrs" => prev["attrs"].merge(incoming["attrs"])
          }
        end
      end

      def compact_attrs(attrs)
        return {} unless attrs.is_a?(Hash)

        out = {}
        attrs.each do |key, value|
          encoded = wire_value(value)
          next if encoded.is_a?(String) && encoded.bytesize > MAX_ATTR_BYTES

          out[key.to_s] = encoded
        end
        out
      end

      def wire_value(value)
        value.respond_to?(:usec) ? value.iso8601(InstantRecord::TIME_PRECISION) : value
      end

      def context_columns_for(model, raw)
        cols = ["id"]
        window = model.respond_to?(:instant_record_sync_window) ? model.instant_record_sync_window : nil
        cols << window.partition_by.to_s if window && window.partition_by
        scope_col = model.respond_to?(:instant_record_sync_scope) ? model.instant_record_sync_scope : nil
        cols << scope_col.to_s if scope_col
        raw.each_key do |key|
          name = key.to_s
          cols << name if name.end_with?("_id")
        end
        cols.uniq
      end

      def destroy_context_attrs(model, record)
        raw = record.attributes
        selected = {}
        context_columns_for(model, raw).each { |col| selected[col] = raw[col] if raw.key?(col) }
        compact_attrs(selected)
      end

      def apply_results_with_counts(results)
        resolved = 0
        reconciled = false
        Array(results).each do |result|
          result = result.deep_stringify_keys
          mutation = OutboxMutation.find_by(id: result["mutation_id"])
          next unless mutation

          notice = nil
          OutboxMutation.transaction do
            SyncMetadata.delete("#{RETRY_PREFIX}#{mutation.id}")
            if mutation.mutator?
              changed_visible = applying_remote do
                HLC.receive(result["hlc"]) if HLC.valid?(result["hlc"])
                moved =
                  case result["status"]
                  when "applied"
                    reconcile_applied_mutator(mutation, result)
                  when "rejected"
                    notice = quarantine_mutation(
                      mutation,
                      kind: "rejected",
                      reason: result["reason"].to_s.presence || "Rejected by server",
                      result: result
                    )
                    reconcile_rejected_mutator(mutation, result)
                  else
                    false
                  end
                mutation.destroy!
                moved
              end
              reconciled = true if changed_visible
            else
              if result["status"] == "applied" && result["skipped"]
                notice = quarantine_mutation(
                  mutation,
                  kind: "conflict",
                  reason: result["reason"].to_s.presence || "Overwritten by a newer server change",
                  result: result
                )
              elsif result["status"] == "rejected"
                notice = quarantine_mutation(
                  mutation,
                  kind: "rejected",
                  reason: result["reason"].to_s.presence || "Rejected by server",
                  result: result
                )
              end
              changed_visible = applying_remote do
                Rebaser.reconcile_mutation_result(mutation, result, record_delta: true)
              end
              reconciled = true if changed_visible
            end
          end
          announce_notice(notice) if notice
          resolved += 1
        end
        [resolved, reconciled]
      end

      def apply_bootstrap_body(body)
        observe_server_time(body["server_time"])
        records = Array(body["records"])
        records.each { |record| apply_record(record) }

        # Cursor written last: a crash mid-apply leaves it nil, so the next
        # tick re-bootstraps; upserts make the retry idempotent. A failure
        # never falls through to a cursor-0 poll of the full change log.
        SyncMetadata.set("identity", body["identity"]) if body["identity"]
        if body["fill"].is_a?(Array) && body["fill"].any?
          SyncMetadata.set("history_fill_targets", JSON.generate(body["fill"]))
        end
        replay = SyncMetadata.get("replay_from")
        if replay.nil? || replay.to_i > body["cursor"].to_i
          self.cursor = body["cursor"]
        else
          self.cursor = replay.to_i
        end
        SyncMetadata.all.each { |entry| entry.destroy if entry.key == "replay_from" } unless replay.nil?
        unlisted_changes
        records.size
      end

      def clear_adaptive_batch_limit
        SyncMetadata.delete(DRAIN_BATCH_LIMIT_KEY)
      end

      def handle_drain_failure(sent_ids, status:, error:)
        return { quarantined: 0, reconciled: false, bisected: false } unless status.is_a?(Integer) && status >= 500 && status < 600

        live_mutations = sent_ids.filter_map { |id| OutboxMutation.find_by(id: id) }
        return { quarantined: 0, reconciled: false, bisected: false } if live_mutations.empty?

        if live_mutations.size > 1
          next_limit = [live_mutations.size / 2, 1].max
          SyncMetadata.set(DRAIN_BATCH_LIMIT_KEY, next_limit)
          return { quarantined: 0, reconciled: false, bisected: true }
        end

        mutation = live_mutations.first
        retry_key = "#{RETRY_PREFIX}#{mutation.id}"
        attempts = SyncMetadata.get(retry_key).to_i + 1
        threshold = [InstantRecord.config.max_server_error_retries.to_i, 1].max

        if attempts >= threshold
          reconciled = isolate_poison_pill(mutation, status: status, error: error, attempts: attempts)
          SyncMetadata.delete(retry_key)
          clear_adaptive_batch_limit
          { quarantined: 1, reconciled: reconciled, bisected: false }
        else
          SyncMetadata.set(retry_key, attempts)
          { quarantined: 0, reconciled: false, bisected: false }
        end
      end

      def isolate_poison_pill(mutation, status:, error:, attempts:)
        # Interpolated, not `error.to_s`: the browser's compiler writes C that
        # does not build for `to_s` on a String among keyword arguments.
        reason = "#{error}"
        payload = {
          "mutation_id" => mutation.id,
          "record_type" => mutation.record_type,
          "record_id" => mutation.record_id,
          "operation" => mutation.operation,
          "changes" => mutation.changes_payload,
          "base_version" => mutation.base_version,
          "status" => status,
          "error" => reason,
          "attempts" => attempts,
          "quarantined_at" => Time.now.utc.iso8601(InstantRecord::TIME_PRECISION)
        }
        SyncMetadata.set("#{QUARANTINE_PREFIX}#{mutation.id}", JSON.generate(payload))
        changed_visible = applying_remote do
          if mutation.mutator?
            moved = reconcile_rejected_mutator(mutation, {})
            mutation.destroy!
            moved
          else
            Rebaser.reconcile_quarantined_mutation(mutation, record_delta: true)
          end
        end
        instrument("poison_pill",
          mutation_id: mutation.id,
          record_type: mutation.record_type,
          record_id: mutation.record_id,
          operation: mutation.operation,
          status: status,
          attempts: attempts,
          error: reason)
        changed_visible
      end

      def transport_get_json(path)
        headers = request_headers
        headers.empty? ? transport.get_json(path) : transport.get_json(path, headers: headers)
      end

      def transport_post_json(path, payload)
        headers = request_headers
        headers.empty? ? transport.post_json(path, payload) : transport.post_json(path, payload, headers: headers)
      end

      def transport_each_event(path, &block)
        headers = request_headers
        headers.empty? ? transport.each_event(path, &block) : transport.each_event(path, headers: headers, &block)
      end

      def format_partition_header(partition)
        return nil if partition.nil?

        if partition.is_a?(Hash)
          partition.each do |key, value|
            text = value.to_s
            return "#{key}:#{text}" unless text.empty?
          end
          return nil
        end
        text = partition.to_s.strip
        text.empty? ? nil : text
      end

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
        observe_server_time(page["server_time"])
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
        observe_server_time(page["server_time"])
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

      # Returns -1, 0, or 1 (never nil) so Spinel AOT can compare directly with 0.
      def compare_boundary(a, b)
        return -1 if a[0] < b[0]
        return 1 if a[0] > b[0]
        return -1 if a[1] < b[1]
        return 1 if a[1] > b[1]

        0
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
        if InstantRecord.branched?
          @planned_drain_ids = nil
          return [false, false]
        end

        planned_ids = @planned_drain_ids
        @planned_drain_ids = nil
        first_batch = planned_ids.nil? ? drain_batch : planned_mutations(planned_ids)
        return [false, false] if first_batch.empty?

        instrument("drain") do |event|
          total_posted = 0
          total_rejected = 0
          reasons = []
          batches = 0
          quarantined = 0
          did_work = false
          reconciled = false

          max_chunks = planned_ids.nil? ? MAX_DRAIN_CHUNKS_PER_PASS : 1
          max_chunks.times do |chunk_index|
            mutations = chunk_index == 0 ? first_batch : drain_batch
            break if mutations.empty?

            begin
              body = transport_post_json("/mutations", mutations_payload(mutations))
              observe_server_time(body["server_time"])
              results = Array(body["results"]).map { |r| r.deep_stringify_keys }
              resolved, batch_reconciled = apply_results_with_counts(results)

              batches += 1
              total_posted += mutations.size
              total_rejected += results.count { |r| r["status"] == "rejected" }
              results.each do |r|
                reason = r["reason"]
                reasons << reason if reason && !reasons.include?(reason)
              end
              did_work = true
              reconciled = true if batch_reconciled
              clear_adaptive_batch_limit if pending_count == 0
              break if resolved == 0
            rescue Transport::Error => e
              outcome = handle_drain_failure(mutations.map { |m| m[:id] }, status: e.status, error: e.message)
              if outcome[:quarantined].positive?
                quarantined += outcome[:quarantined]
                did_work = true
                reconciled = true if outcome[:reconciled]
                next
              else
                log_failure("drain", e)
                break
              end
            end
          end

          event[:posted] = total_posted
          event[:rejected] = total_rejected
          event[:reasons] = reasons.first(3)
          event[:batches] = batches
          event[:quarantined] = quarantined
          [did_work, reconciled]
        end
      end

      def matured_outbox_rows(now)
        return OutboxMutation.matured(now).ordered.to_a unless OutboxMutation.held(now).exists?

        blocked = {}
        ready = []
        OutboxMutation.ordered.each do |mutation|
          key = "#{mutation.record_type}:#{mutation.record_id}"
          if mutation.held?(now)
            blocked[key] = true
          elsif !blocked[key]
            ready << mutation
          end
        end
        ready
      end

      def planned_mutations(ids)
        return [] if ids.empty?

        by_id = {}
        OutboxMutation.where(id: ids).each { |mutation| by_id[mutation.id] = mutation }
        ids.filter_map { |id| by_id[id]&.as_mutation }
      end

      def restore_record(model, mutation, earlier_pending:)
        snapshot = mutation.rollback_payload
        attrs = snapshot.slice(*model.column_names)
        existing = model.find_by(id: mutation.record_id)

        # A remote destroy (or rejected earlier create) already removed this row;
        # undoing an update must not resurrect it.
        return if mutation.operation == "update" && existing.nil?

        # Rebaser keeps sync_state == "pending" while this held mutation is
        # still in the outbox, so a persisted row at sync_state == "synced" means
        # a newer remote change (or server reconciliation) already replaced it.
        return if existing && existing.sync_state == "synced"

        record = existing || model.new
        current_version = existing ? existing.server_version.to_i : 0

        record.assign_attributes(attrs.except("id"))
        record.id = mutation.record_id

        if earlier_pending
          record.sync_state = "pending"
        elsif attrs["sync_state"] == "pending"
          record.sync_state = "synced"
          record.server_version = current_version if current_version > record.server_version.to_i
        end

        if record.respond_to?(:record_timestamps=)
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
      end
      def reconcile_applied_mutator(mutation, result)
        seen = {}
        changed = false
        Array(result["records"]).each do |rec|
          rec = rec.deep_stringify_keys
          model = InstantRecord.synced_model(rec["type"])
          next unless model

          seen["#{rec["type"]}:#{rec["id"]}"] = true
          moved =
            if rec["operation"] == "destroy"
              record = model.find_by(id: rec["id"])
              if record
                destroy_attrs = destroy_context_attrs(model, record)
                record.destroy!
                note_change(rec["type"], rec["id"], op: "destroy", changed_columns: [], attrs: destroy_attrs)
                true
              else
                false
              end
            else
              upsert_from_server(model, rec["attributes"], rec["version"], authoritative: true)
            end
          changed = true if moved
        end

        mutation.touched_records.each do |entry|
          key = "#{entry["type"]}:#{entry["id"]}"
          next if seen[key]

          model = InstantRecord.synced_model(entry["type"])
          record = model&.find_by(id: entry["id"])
          record.update_columns(sync_state: "synced") if record
        end
        changed
      end

      def reconcile_rejected_mutator(mutation, result)
        reconciled = {}
        changed = false
        Array(result["records"]).each do |rec|
          rec = rec.deep_stringify_keys
          model = InstantRecord.synced_model(rec["type"])
          next unless model && rec["attributes"].present?

          if upsert_from_server(model, rec["attributes"], rec["version"], authoritative: true)
            changed = true
          end
          reconciled["#{rec["type"]}:#{rec["id"]}"] = true
        end

        mutation.touched_records.each do |entry|
          key = "#{entry["type"]}:#{entry["id"]}"
          next if reconciled[key]

          model = InstantRecord.synced_model(entry["type"])
          next unless model

          moved =
            if entry["op"] == "create"
              record = model.find_by(id: entry["id"])
              if record
                destroy_attrs = destroy_context_attrs(model, record)
                record.destroy!
                note_change(entry["type"], entry["id"], op: "destroy", changed_columns: [], attrs: destroy_attrs)
                true
              else
                false
              end
            elsif entry["before"].is_a?(Hash)
              restore_local_snapshot(model, entry["before"])
            else
              false
            end
          changed = true if moved
        end
        changed
      end

      def restore_local_snapshot(model, attributes)
        sliced = attributes.slice(*model.column_names)
        return false unless sliced["id"]

        record = model.find_or_initialize_by(id: sliced["id"])
        record.assign_attributes(sliced.except("id"))
        was_new = !record.persisted?
        changed_cols = record.changed.map(&:to_s)
        record.save!(validate: false)
        if sliced["updated_at"]
          record.update_columns(updated_at: parse_time(sliced["updated_at"].to_s))
          changed_cols << "updated_at" unless changed_cols.include?("updated_at")
        end
        note_record_change(record, was_new ? "create" : "update", changed_columns: changed_cols)
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
      def upsert_from_server(model, attributes, version, hlc: nil, authoritative: false, record_delta: true)
        return false unless attributes

        HLC.receive(hlc) if HLC.valid?(hlc)

        # Schema skew must not raise here either: a client behind the server is
        # sent columns it has not migrated yet. They are the server's to keep;
        # this runtime converges on the columns it actually has.
        attributes = attributes.slice(*model.column_names)
        record = model.find_or_initialize_by(id: attributes["id"])

        incoming_hlc = HLC.valid?(hlc) ? hlc : nil
        local_hlc = record.persisted? ? HLC.row_hlc(model.name, record.id) : nil
        incoming_at = attributes["updated_at"] && parse_time(attributes["updated_at"].to_s)
        local_at = record.persisted? ? record.updated_at : nil
        prior_pending = !authoritative && record.persisted? && record.sync_state == "pending"
        prior_attributes = prior_pending ? InstantRecord.wire_attributes(record.attributes) : nil

        record.assign_attributes(attributes.except("id", "server_version"))

        if !authoritative && record.persisted? && stale_remote?(incoming_hlc, local_hlc, incoming_at, local_at)
          # The remote value lost. This is the last moment it exists in this
          # runtime — nothing downstream sees it, which is why models get a seam.
          if (record.changed - BOOKKEEPING_COLUMNS).any?
            model.instant_record_discarded_change_handler&.call(attributes)
          end
          return false
        end

        inbound_conflict = prior_pending && (record.changed - BOOKKEEPING_COLUMNS).any? &&
          OutboxMutation.find_by(record_type: model.name, record_id: record.id).nil?

        record.server_version = version || attributes["server_version"] || 0
        record.sync_state = "synced"
        HLC.set_row_hlc(model.name, record.id, incoming_hlc, force: authoritative) if incoming_hlc
        return false unless record.changed?

        was_new = !record.persisted?
        changed_cols = record.changed.map(&:to_s)
        data_changed = was_new || (changed_cols - BOOKKEEPING_COLUMNS).any?
        quarantined = nil
        if inbound_conflict && data_changed
          OutboxMutation.transaction do
            quarantined = SyncNotice.record!(
              kind: "conflict",
              record_type: model.name,
              record_id: record.id,
              operation: "update",
              reason: "Overwritten by a newer server change",
              attempted_changes: prior_attributes,
              server_attributes: InstantRecord.wire_attributes(attributes),
              server_version: record.server_version
            )
            record.save!(validate: false)
          end
          note_record_change(record, was_new ? "create" : "update", changed_columns: changed_cols) if record_delta
          announce_notice(quarantined) if quarantined
        elsif data_changed
          record.save!(validate: false)
          note_record_change(record, was_new ? "create" : "update", changed_columns: changed_cols) if record_delta
        else
          record.update_columns(sync_state: record.sync_state, server_version: record.server_version)
        end
        data_changed
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

      def quarantine_mutation(mutation, kind:, reason:, result:)
        return nil if SyncNotice.find_by(mutation_id: mutation.id)

        SyncNotice.record!(
          mutation_id: mutation.id,
          kind: kind,
          record_type: mutation.record_type,
          record_id: mutation.record_id,
          operation: mutation.operation,
          reason: reason,
          attempted_changes: mutation.changes_payload || {},
          server_attributes: result["server_attributes"] || {},
          server_version: result["version"].to_i
        )
      end

      def announce_notice(notice)
        recorded_notices << notice.as_notice
        instrument("notice",
          id: notice.id,
          kind: notice.kind,
          record_type: notice.record_type,
          record_id: notice.record_id,
          operation: notice.operation,
          reason: notice.reason)
      end

      def log_failure(phase, error)
        instrument("offline", phase: phase, error: error.message)
        warn "[instant_record] #{phase} failed (offline?): #{error.message}"
      end

      # Every meaningful sync outcome is announced through
      # ActiveSupport::Notifications — the seam a host app subscribes to for
      # logging or metrics, and the one the browser runtime bridges to the JS
      # worker through /host/events. Ruby is what knows: the worker can only say
      # it made a request; this side knows what the pass actually did.
      def instrument(name, payload = {}, &block)
        full_name = "#{name}.instant_record"
        started = Time.now.to_f
        raised = nil
        begin
          ActiveSupport::Notifications.instrument(full_name, payload, &block)
        rescue StandardError => e
          raised = e
          raise
        ensure
          if InstantRecord.browser?
            duration_ms = (Time.now.to_f - started) * 1000.0
            record_bridged_event(full_name, payload, duration_ms, raised)
          end
        end
      end

      def record_bridged_event(name, payload, duration_ms, error = nil)
        clean = normalize_event_payload(payload)
        clean["exception"] = [error.class.name, error.message.to_s] if error
        recorded_events.shift if recorded_events.size >= MAX_RECORDED_EVENTS
        recorded_events << {
          "name" => name,
          "payload" => clean,
          "duration_ms" => duration_ms
        }
        notifier.events_emitted(events_notice) if notifier.respond_to?(:events_emitted)
        nil
      end

      def normalize_event_payload(payload)
        result = {}
        return result unless payload.is_a?(Hash)

        payload.each do |key, value|
          name = key.to_s
          next if name == "exception_object"

          result[name] = normalize_event_value(value)
        end
        result
      end

      def normalize_event_value(value)
        case value
        when String, Integer, Float, TrueClass, FalseClass, NilClass
          value
        when Symbol
          value.to_s
        when Array
          value.map { |item| normalize_event_value(item) }
        when Hash
          normalize_event_payload(value)
        else
          value.to_s
        end
      end
    end
  end
end
