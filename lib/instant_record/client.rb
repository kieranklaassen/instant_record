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

      # Arm the boot-time trim; InstantRecord.start sets this on cold boots
      # only. Runs once, on the next sync pass.
      def request_eviction
        @eviction_pending = true
      end

      # Trim every windowed model back to its declared window. delete_all
      # under applying_remote: no callbacks, no outbox rows. Pending rows are
      # excluded before ranking — unsynced writes are never evicted and never
      # push synced rows out of the window. Returns true when anything was
      # deleted.
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
        mutations = pending_mutations(now)
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
            case mutation.operation
            when "create"
              model.find_by(id: mutation.record_id)&.destroy!
              true
            when "update", "destroy"
              if mutation.rollback_payload.is_a?(Hash)
                restore_record(model, mutation, earlier_pending: earlier_pending)
                true
              else
                false
              end
            else
              false
            end
          end
          next unless restored

          mutation.destroy!
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
          drop = types.include?(mutation.record_type)
          if !drop && mutation.mutator?
            mutation.touched_records.each do |entry|
              if types.include?(entry["type"])
                drop = true
                break
              end
            end
          end
          mutation.destroy if drop
        end
        SyncNotice.all.each do |notice|
          notice.destroy if types.include?(notice.record_type)
        end
        # The rows that stay were last brought up to date at this cursor. The
        # bootstrap to come only adds and changes rows, so the poll after it
        # starts here again and a destroy made in between is not missed.
        SyncMetadata.set("replay_from", cursor) if bootstrapped? && SyncMetadata.get("replay_from").nil?
        SyncMetadata.all.each do |entry|
          entry.destroy if entry.key == "cursor" || entry.key == "identity" || entry.key.start_with?("history:")
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
        return false if InstantRecord.branched?

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
        return false if InstantRecord.branched?

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
        history_marks.clear
        changed_records.clear
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
          records.each { |record| apply_record(record) }
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

          quarantined = nil
          OutboxMutation.transaction do
            applying_remote do
              if mutation.mutator?
                case result["status"]
                when "applied"
                  reconciled = true if reconcile_applied_mutator(mutation, result)
                when "rejected"
                  quarantined = quarantine_mutation(
                    mutation,
                    kind: "rejected",
                    reason: result["reason"].to_s.presence || "Rejected by server",
                    result: result
                  )
                  reconciled = true if reconcile_rejected_mutator(mutation, result)
                end
              else
                case result["status"]
                when "applied"
                  # `skipped` is the server saying it threw this write away to
                  # last-write-wins. It is resolved (nothing will retry it) but it
                  # never landed, so quarantine the user's attempted write in
                  # SyncNotice and reconcile to the winner before removing the outbox row.
                  if result["skipped"]
                    quarantined = quarantine_mutation(
                      mutation,
                      kind: "conflict",
                      reason: result["reason"].to_s.presence || "Overwritten by a newer server change",
                      result: result
                    )
                    reconciled = true if reconcile_to_server_state(mutation, result)
                  else
                    mark_synced(mutation, result["version"])
                  end
                when "rejected"
                  quarantined = quarantine_mutation(
                    mutation,
                    kind: "rejected",
                    reason: result["reason"].to_s.presence || "Rejected by server",
                    result: result
                  )
                  reconciled = true if reconcile_rejection(mutation, result)
                end
              end
              mutation.destroy!
            end
          end
          announce_notice(quarantined) if quarantined
        end
        reconciled
      end

      # Apply one remote change event (last-write-wins) and note it for the next
      # records_changed notice. Returns whether it actually changed anything
      # here — see upsert_from_server.
      def apply_change(event)
        apply_remote_event(event, record_delta: true)
      end

      # Apply one remote record payload without noting it for records_changed
      # (used by bootstrap and history pages, which handle notification separately).
      def apply_record(event)
        apply_remote_event(event, record_delta: false)
      end

      private

      def apply_remote_event(event, record_delta:)
        event = event.deep_stringify_keys
        model = InstantRecord.synced_model(event["type"])
        return false unless model

        applying_remote do
          if event["operation"] == "destroy"
            record = model.find_by(id: event["id"])
            return false unless record

            destroy_attrs = record_delta ? destroy_context_attrs(model, record) : nil
            record.destroy!
            note_change(event["type"], event["id"], op: "destroy", changed_columns: [], attrs: destroy_attrs) if record_delta
            true
          else
            upsert_from_server(model, event["attributes"], event["version"], record_delta: record_delta)
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

      def drain_outbox
        if InstantRecord.branched?
          @planned_drain_ids = nil
          return [false, false]
        end

        planned_ids = @planned_drain_ids
        @planned_drain_ids = nil
        mutations = planned_ids.nil? ? pending_mutations : planned_mutations(planned_ids)
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

        still_pending = OutboxMutation.where(record_type: mutation.record_type, record_id: mutation.record_id)
          .where.not(id: mutation.id)
          .exists?
        next_state = still_pending ? "pending" : "synced"
        record.update_columns(sync_state: next_state, server_version: version || record.server_version)
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

        # mark_synced keeps sync_state == "pending" while this held mutation is
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
          record.update_columns(updated_at: Time.parse(sliced["updated_at"].to_s))
          changed_cols << "updated_at" unless changed_cols.include?("updated_at")
        end
        note_record_change(record, was_new ? "create" : "update", changed_columns: changed_cols)
        true
      end

      def reconcile_rejection(mutation, result)
        return reconcile_to_server_state(mutation, result) if result["server_attributes"].present?

        # The server never accepted this record (rejected create): remove it.
        model = InstantRecord.synced_model(mutation.record_type)
        record = model&.find_by(id: mutation.record_id)
        return false unless record

        destroy_attrs = destroy_context_attrs(model, record)
        record.destroy!
        note_change(mutation.record_type, mutation.record_id, op: "destroy", changed_columns: [], attrs: destroy_attrs)
        true
      end

      # Roll the local record onto the server's own copy of the row, when the
      # result carries one. Returns whether visible local row data changed.
      #
      # Authoritative: the server told us what it holds in answer to a write of
      # ours it would not take, so its row wins here regardless of timestamps.
      def reconcile_to_server_state(mutation, result)
        model = InstantRecord.synced_model(mutation.record_type)
        return false unless model && result["server_attributes"].present?

        upsert_from_server(model, result["server_attributes"], result["version"], authoritative: true, record_delta: true)
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
      def upsert_from_server(model, attributes, version, authoritative: false, record_delta: true)
        return false unless attributes

        # Schema skew must not raise here either: a client behind the server is
        # sent columns it has not migrated yet. They are the server's to keep;
        # this runtime converges on the columns it actually has.
        attributes = attributes.slice(*model.column_names)
        record = model.find_or_initialize_by(id: attributes["id"])

        incoming_at = attributes["updated_at"] && Time.parse(attributes["updated_at"].to_s)
        local_at = record.persisted? ? record.updated_at : nil
        prior_pending = !authoritative && record.persisted? && record.sync_state == "pending"
        prior_attributes = prior_pending ? InstantRecord.wire_attributes(record.attributes) : nil

        record.assign_attributes(attributes.except("id", "server_version"))

        if !authoritative && incoming_at && local_at && incoming_at <= local_at
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
