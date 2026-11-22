require "json"
require "base64"

module InstantRecord
  DEFAULT_MOUNT_PATH = "/instant_record".freeze

  # Engine endpoints allow cross-origin reads and JSON writes so a separately
  # hosted compiled site or Vite dev server can reach Rails. Access control is
  # enforced per model via `sync_scope`, `syncable_to`, and `writable_by`.
  CORS_HEADERS = {
    "access-control-allow-origin" => "*",
    "access-control-allow-methods" => "GET, POST, OPTIONS",
    "access-control-allow-headers" => "content-type, last-event-id"
  }.freeze

  # Every timestamp crossing the wire carries microseconds, in both directions.
  # This used to differ per path — the change log and the outbox serialize
  # through ActiveSupport's JSON encoder, which stops at milliseconds, while the
  # bootstrap and records endpoints kept all six places — and the mismatch was
  # not cosmetic. It loses (created_at, id) keyset neighbours between history
  # pages, and it biases every last-write-wins comparison against whichever side
  # was rounded, which silently discarded writes on both.
  TIME_PRECISION = 6

  # Query marker that tells the service worker to pass one request to the
  # network instead of the local wasm runtime (see InstantRecord.server_url).
  NETWORK_MARKER = "instant_record_network=1".freeze
end

require "active_support/isolated_execution_state"
require "instant_record/version"
require "instant_record/host"
require "instant_record/configuration"
require "instant_record/runtime_scoped"
require "instant_record/read_tracker"
require "instant_record/native"
InstantRecord::Host.load_engine

module InstantRecord
  class << self
    # Delegated to InstantRecord::Host so AOT builds swap the host adapter
    # module instead of string-patching this file.
    def browser? = Host.browser?

    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    # Optional explicit allowlist of syncable models. Without it, any model
    # that includes InstantRecord::Syncable is syncable.
    def sync(*models)
      @synced_models = models.flatten
    end

    def synced_models
      @synced_models ||= []
    end

    def synced_model(record_type)
      return synced_models.find { |model| model.name == record_type } if synced_models.any?

      Host.resolve_syncable_model(record_type)
    end

    # Every model participating in sync: the explicit allowlist when set,
    # otherwise all loaded Syncable includers.
    def syncable_models
      return synced_models if synced_models.any?

      Host.discover_syncable_models
    end

    # One record's attributes as they cross the wire, in either direction and on
    # every path: the bootstrap and records endpoints, the change log, the
    # outbox, and the server's rejection/superseded replies. sync_state is
    # client-local and never serialized. Timestamps go out at TIME_PRECISION so
    # the (created_at, id) keyset cursor round-trips exactly and both sides of a
    # last-write-wins comparison are measured with the same ruler.
    def wire_attributes(attributes)
      snapshot_attributes(attributes.except("sync_state"))
    end

    # Full local row snapshot for delay-line rollback: keeps sync_state alongside
    # every other column, with timestamps at TIME_PRECISION so restore is lossless.
    def snapshot_attributes(attributes)
      attributes.transform_values do |value|
        # usec, not iso8601: a Date answers to iso8601 but takes no precision
        # argument, and its default JSON form already round-trips exactly.
        value.respond_to?(:usec) ? value.iso8601(TIME_PRECISION) : value
      end
    end

    # The scope a record belongs to, or nil for a record every client may see.
    def scope_of(record)
      column = record.class.instant_record_sync_scope
      record[column].presence if column
    end

    # The wire shape for one record, shared by the bootstrap and records
    # endpoints and mirroring Change#as_event: clients apply all three through
    # the same upsert path.
    def record_payload(record)
      {
        type: record.class.name,
        id: record.id,
        version: record[:server_version],
        attributes: wire_attributes(record.attributes)
      }
    end

    # Begin background sync in the browser.
    def start(cold_boot: true)
      return false unless browser?

      Client.request_eviction if cold_boot
      @started = true
    end

    def started? = !!@started

    # How many times one tick will loop to absorb requests that arrived while it
    # was working. A cap keeps a continuous writer from holding the VM forever —
    # whatever is left is reported as pending and retried.
    COALESCE_PASSES = 5

    # One sync pass: drain the outbox up, changes down, notify tabs.
    #
    # Requests that arrive mid-pass are coalesced rather than queued or dropped.
    # They cannot start a second pass — the VM must never be re-entered — so the
    # running pass notes them and goes round again. A burst of writes therefore
    # costs a couple of batched requests instead of one per write, and no write
    # is left sitting in the outbox waiting for a later trigger.
    def tick
      return :not_started unless started?

      if @ticking
        @tick_again = true
        return :busy
      end

      single_flight do
        COALESCE_PASSES.times do
          @tick_again = false
          outbox_before = Client.pending_count
          Client.sync_pass

          # Go round again only for a request that arrived mid-pass AND an outbox
          # that actually moved. Repeating a pass that changed nothing would just
          # hammer a server already refusing the same batch; the caller's backoff
          # is where that belongs.
          break unless @tick_again && Client.pending_count != outbox_before
        end
        :ok
      end
    end

    # Manual one-shot sync, usable before/without `start`.
    def sync_now
      @started = true
      tick
    end

    # A tick for the service worker, which needs to know whether to come back.
    # There is no heartbeat: writes trigger a pass, the change stream carries
    # everything inbound, and this `pending` count is the only reason to retry —
    # so when it reaches zero an idle client goes quiet entirely.
    def tick_json
      result = tick
      return JSON.generate(ok: false, busy: true) if result == :busy
      return JSON.generate(ok: false, started: false) if result == :not_started

      payload = { ok: true, pending: pending_count }
      next_ms = next_release_ms
      payload[:next_release_ms] = next_ms unless next_ms.nil?
      JSON.generate(payload)
    rescue StandardError => e
      # Never raise across the JS boundary; a failed pass is a retry, not a crash.
      JSON.generate(ok: false, error: e.message, pending: safe_pending_count)
    end

    def pending_count = Client.pending_count
    def held_count = Client.held_count
    def held_mutations = Client.held_mutations
    def next_release_at = Client.next_release_at
    def next_release_ms = Client.next_release_ms
    def cursor = Client.cursor
    def sync_notices = SyncNotice.active.recent
    def sync_notices_count = SyncNotice.active.count
    def resolve_sync_notice(id, action:, overrides: {}) = SyncNotice.resolve(id, action: action, overrides: overrides)

    # Hold local outbox writes created inside the block for `seconds` before they
    # mature for sync, recording a pre-mutation snapshot so cancel_pending can
    # restore local SQLite and drop the outbox row before release.
    def hold_for(seconds, &block)
      Client.with_hold(seconds, &block)
    end

    # Cancel a held outbox mutation before its release_at matures, restoring the
    # local SQLite row from its pre-mutation snapshot and deleting the outbox row.
    def cancel_pending(mutation_id)
      Client.cancel_pending(mutation_id)
    end

    # Copy-on-write local SQLite staging branch. Forks the live local SQLite
    # workspace into an isolated offline copy for safe bulk edits and visual UI
    # preview, then either approves (extracting & replaying queued outbox
    # mutations onto current `main`) or discards with zero server impact.
    def branch!(name: nil, directory: nil, &block)
      Branch.open(name: name, directory: directory, &block)
    end

    def current_branch = Branch.current
    def branched? = Branch.active?
    def branch_name = Branch.current_name

    # On-demand history page for a windowed model (see Client.fetch_history).
    # Shares the tick's single-flight guard both ways: a fetch during a sync
    # pass returns :busy for the caller to retry, and a tick arriving while a
    # fetch is mid-flight is skipped — asyncify re-entrancy is the browser
    # runtime's crash class, so the VM never runs both at once.
    def fetch_history(model, before:, partition: nil, limit: nil)
      single_flight do
        Client.fetch_history(model, before: before, partition: partition, limit: limit)
      end
    end

    # --- Streamed changes -----------------------------------------------------
    # Ruby can't hold the change stream itself: every chunk it awaited would
    # suspend the single-flight tick, so a tailing window would starve outbox
    # drains for its whole duration. That is why the sync loop polls with
    # window=0 by default. Something outside the VM — the service worker — can
    # hold the stream instead and hand events in here, which is what turns
    # tick-bounded delivery into push.

    # Where the sync engine lives, so the holder of the stream knows what to
    # open. Reading it from here keeps one source of truth.
    def endpoint = config.endpoint

    # One of your own app paths on the authoritative server, reachable from
    # either runtime — for the rare action that must not be served locally
    # (anything whose effect has to reach other clients through the server's
    # change log).
    #
    # The sync endpoint already points at that server, so an app path hangs off
    # the same base: absolute when the PWA is served cross-origin (a Vite dev
    # server), empty when the endpoint is the same-origin default. The marker
    # tells the service worker to pass this one request to the network instead of
    # the local runtime; on the server there is no service worker and it is
    # ignored — which is why app code builds this URL without asking which
    # runtime it is in.
    def server_url(path)
      path_str = path.to_s
      separator = path_str.include?("?") ? "&" : "?"
      current_mount = mount_path
      base = (endpoint == DEFAULT_MOUNT_PATH && current_mount != DEFAULT_MOUNT_PATH) ? "" : endpoint.to_s.delete_suffix(current_mount)
      "#{base}#{path_str}#{separator}#{NETWORK_MARKER}"
    end

    # Tell the sync loop a stream is live, so its own catch-up poll stands down.
    # Set false when the stream drops and the poll should take over again.
    def streaming=(value)
      Client.streaming = value
    end

    # Apply a batch of streamed events. Shares the tick's single-flight guard:
    # applying while a sync pass runs would re-enter the VM, so the caller gets
    # :busy and retries — the same contract as fetch_history.
    def apply_events(events)
      single_flight { Client.apply_events(events) }
    end

    # One chunk of the change stream, straight off the socket the worker holds.
    # Base64 for the same injection reason as fetch_history_b64. A :busy reply
    # leaves the chunk unparsed, so resending it is safe and loses nothing.
    def consume_stream_b64(chunk_b64)
      chunk = Base64.strict_decode64(chunk_b64.to_s)
      result = single_flight { Client.consume_stream(chunk) }
      return JSON.generate(ok: false, busy: true) if result == :busy

      JSON.generate(ok: true, applied: result, cursor: cursor)
    rescue ArgumentError, TypeError => e
      JSON.generate(ok: false, error: e.message)
    end

    # A stream just opened: forget any half-received frame from the last one and
    # stand the catch-up poll down.
    def stream_opened_json
      result = single_flight do
        Client.reset_stream
        self.streaming = true
      end
      JSON.generate(result == :busy ? { ok: false, busy: true } : { ok: true })
    end

    # The stream dropped: the poll is the delivery path again until it is back.
    def stream_closed_json
      result = single_flight { self.streaming = false }
      JSON.generate(result == :busy ? { ok: false, busy: true } : { ok: true })
    end

    # Base64 entrypoint the service worker calls: the request never enters
    # Ruby source as raw text (which would be a #{}-interpolation injection
    # sink), only as a base64 token decoded here. Delegates to
    # fetch_history_json for the actual work.
    def fetch_history_b64(request_b64)
      fetch_history_json(Base64.strict_decode64(request_b64.to_s))
    rescue ArgumentError => e
      JSON.generate(ok: false, error: e.message)
    end

    # String-in/string-out fetch_history for the service worker's evalAsync
    # interop (no JS object bridging). Never raises across the boundary:
    # errors come back as {ok: false, error:}, a held single-flight guard as
    # {ok: false, busy: true} for the worker's retry loop.
    def fetch_history_json(request_json)
      request = JSON.parse(request_json)
      model = synced_model(request["type"])
      return JSON.generate(ok: false, error: "unknown record type #{request["type"].inspect}") unless model

      before = request["before"] || {}
      result = fetch_history(model,
        partition: request["partition"],
        before: { created_at: before["created_at"], id: before["id"] },
        limit: request["limit"])
      return JSON.generate(ok: false, busy: true, error: "sync in flight") if result == :busy

      JSON.generate(result)
    rescue JSON::ParserError, ArgumentError, TypeError => e
      JSON.generate(ok: false, error: e.message)
    end

    # Execute a declared sync_action in the active runtime (optimistically inside
    # a local SQLite savepoint on the client, or in one transaction on the server).
    def mutate(mutator_name, args = nil, mutation_id: nil, **kwargs)
      merged = args ? (kwargs.empty? ? args : args.merge(kwargs)) : kwargs
      SyncActions.mutate(mutator_name, merged, mutation_id: mutation_id)
    end

    # Server-side change logging (Syncable) must not fire while a client
    # mutation is being applied — MutationApplier logs those itself.
    # IsolatedExecutionState is fiber-aware for Falcon's fiber-per-request.
    def applying_client_mutation?
      !!ActiveSupport::IsolatedExecutionState[:instant_record_applying_client_mutation]
    end

    def applying_client_mutation
      previous = ActiveSupport::IsolatedExecutionState[:instant_record_applying_client_mutation]
      ActiveSupport::IsolatedExecutionState[:instant_record_applying_client_mutation] = true
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[:instant_record_applying_client_mutation] = previous
    end

    private

    # Where the engine is mounted on the authoritative server. The endpoint IS
    # that mount, so stripping it leaves the app's own base — read from config
    # rather than assumed, because an app is free to move the mount.
    def mount_path
      return config.mount_path if config.mount_path.is_a?(String)

      Host.default_mount_path
    end

    # The retry decision must survive a database that is itself unhappy:
    # reporting "nothing pending" there would strand queued writes forever.
    def safe_pending_count
      pending_count
    rescue StandardError
      1
    end

    # Ticks and history fetches share one guard: the wasm VM must never run
    # two sync entry points concurrently (asyncify re-entrancy), so whichever
    # is in flight makes the other answer :busy.
    def single_flight
      return :busy if @ticking

      @ticking = true
      begin
        yield
      ensure
        @ticking = false
      end
    end
  end
end

ActiveSupport.on_load(:active_record) do
  require "instant_record/sync_window"
  require "instant_record/sync_actions"
  require "instant_record/syncable"
  require "instant_record/outbox_mutation"
  require "instant_record/sync_metadata"
  require "instant_record/sync_notice"
  require "instant_record/client"
  require "instant_record/branch"
  InstantRecord::Host.load_branch_store
end

InstantRecord::Host.install_active_job_guard
