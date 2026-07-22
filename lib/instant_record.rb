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

    # Begin background sync (browser runtime only; a no-op on the server).
    # The gem's service worker shim schedules `tick` on config.sync_interval.
    def start
      return false unless browser?

      @started = true
    end

    def started? = !!@started

    # One sync pass: drain the outbox up, poll changes down, notify tabs.
    # Single-flight: a tick that arrives while one is in flight is skipped.
    def tick
      return :not_started unless started?
      return :busy if @ticking

      @ticking = true
      begin
        Client.sync_pass
        :ok
      ensure
        @ticking = false
      end
    end

    # Manual one-shot sync, usable before/without `start`.
    def sync_now
      @started = true
      tick
    end

    def pending_count = Client.pending_count
    def cursor = Client.cursor

    # On-demand history page for a windowed model (see Client.fetch_history).
    # Shares the tick's single-flight guard both ways: a fetch during a sync
    # pass returns :busy for the caller to retry, and a tick arriving while a
    # fetch is mid-flight is skipped — asyncify re-entrancy is the browser
    # runtime's crash class, so the VM never runs both at once.
    def fetch_history(model, before:, partition: nil, limit: nil)
      return :busy if @ticking

      @ticking = true
      begin
        Client.fetch_history(model, before: before, partition: partition, limit: limit)
      ensure
        @ticking = false
      end
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
  end
end

ActiveSupport.on_load(:active_record) do
  require "instant_record/sync_window"
  require "instant_record/syncable"
  require "instant_record/outbox_mutation"
  require "instant_record/sync_metadata"
  require "instant_record/client"
end
