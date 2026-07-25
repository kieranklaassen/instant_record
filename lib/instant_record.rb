require "json"
require "base64"

module InstantRecord
  DEFAULT_MOUNT_PATH = "/instant_record".freeze

  # Both engine controllers serve a PWA that may run on another origin in
  # development (Vite dev server); auth on the sync endpoints is out of scope
  # for the PoC.
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
require "instant_record/configuration"
require "instant_record/runtime_scoped"
require "wasmify-rails" # browser build tasks + PGlite adapter; inert outside wasm builds
require "instant_record/engine" if defined?(Rails::Engine)

module InstantRecord
  class << self
    # True when running inside the browser (ruby.wasm). Delegates to
    # wasmify-rails' Kernel#on_wasm?; kept as a method so it stays the
    # single stub point for tests and the public name for apps.
    def browser?
      on_wasm?
    end

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

      klass = record_type.to_s.safe_constantize
      klass if klass.respond_to?(:instant_record_syncable?) && klass.instant_record_syncable?
    end

    # Every model participating in sync: the explicit allowlist when set,
    # otherwise all loaded Syncable includers.
    def syncable_models
      return synced_models if synced_models.any?

      ActiveRecord::Base.descendants.select do |model|
        !model.abstract_class? && model.name &&
          model.respond_to?(:instant_record_syncable?) && model.instant_record_syncable?
      end
    end

    # One record's attributes as they cross the wire, in either direction and on
    # every path: the bootstrap and records endpoints, the change log, the
    # outbox, and the server's rejection/superseded replies. sync_state is
    # client-local and never serialized. Timestamps go out at TIME_PRECISION so
    # the (created_at, id) keyset cursor round-trips exactly and both sides of a
    # last-write-wins comparison are measured with the same ruler.
    def wire_attributes(attributes)
      attributes.except("sync_state").transform_values do |value|
        # usec, not iso8601: a Date answers to iso8601 but takes no precision
        # argument, and its default JSON form already round-trips exactly.
        value.respond_to?(:usec) ? value.iso8601(TIME_PRECISION) : value
      end
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

    # Bring this runtime's database up to the app's schema. Stands in for a bare
    # `ActiveRecord::Tasks::DatabaseTasks.prepare_all` at boot, which cannot see
    # the app's migrations from the browser VM's working directory and so leaves
    # a returning visitor on the schema they first booted with — see LocalSchema.
    def prepare_database! = LocalSchema.prepare!

    # Begin background sync (browser runtime only; a no-op on the server).
    # The gem's service worker shim schedules `tick` on config.sync_interval.
    # cold_boot: false skips the boot-time window eviction — the service
    # worker passes it when it was restarted under already-open tabs (an idle
    # SW restart mid-read must not trim scrollback the reader is holding).
    def start(cold_boot: true)
      return false unless browser?

      # Sync narration flows to the inspector from here on: Ruby authors the
      # entries, the worker's report pipe carries them (see
      # Client::Instrumentation).
      Client::Instrumentation.attach
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

      JSON.generate(ok: true, pending: pending_count)
    rescue StandardError => e
      # Never raise across the JS boundary; a failed pass is a retry, not a crash.
      JSON.generate(ok: false, error: e.message, pending: safe_pending_count)
    end

    def pending_count = Client.pending_count
    def cursor = Client.cursor

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
      "#{endpoint.to_s.delete_suffix(mount_path)}#{path}?#{NETWORK_MARKER}"
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
      configured = Rails.application.config.instant_record.mount_path if defined?(Rails) && Rails.application
      configured.is_a?(String) ? configured : DEFAULT_MOUNT_PATH
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
  require "instant_record/local_schema"
  require "instant_record/sync_window"
  require "instant_record/syncable"
  require "instant_record/outbox_mutation"
  require "instant_record/sync_metadata"
  require "instant_record/client"
end
