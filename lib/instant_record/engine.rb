require "instant_record/sync_scope"
require "instant_record/files"

module InstantRecord
  class Engine < ::Rails::Engine
    isolate_namespace InstantRecord

    config.instant_record = ActiveSupport::OrderedOptions.new
    config.instant_record.mount_path = DEFAULT_MOUNT_PATH
    config.instant_record.build_on_precompile = false
    # Serve a native app's screens over HTTP for development (NativeScreensController).
    config.instant_record.native_dev = false

    # `render inertia: ..., live: { prop: Model }` where the app has inertia_rails.
    config.after_initialize do
      if defined?(::InertiaRails::Renderer)
        require "instant_record/inertia"
        ::InertiaRails::Renderer.prepend(InstantRecord::Inertia::Renderer)
      end
    end

    # A record that declares sync_file takes its file with it when it goes.
    config.to_prepare { InstantRecord::Files.forget_on_destroy }

    initializer "instant_record.compiled_site" do |app|
      host = app.config.instant_record.compiled_host
      if host.present?
        require "instant_record/compiled_site"
        app.middleware.insert_after Rack::Sendfile, InstantRecord::CompiledSite, host: host,
          root: app.root.join("public/instant_record_compiled/current").to_s,
          sync_path: app.config.instant_record.mount_path || DEFAULT_MOUNT_PATH
      end
    end

    # How long GET /events tails for new changes before closing (the client
    # reconnects from its cursor). Clients may request less via ?window=.
    #
    # 25s is sized for Puma, where every open stream holds a request thread —
    # short windows are what keep a small thread pool from starving. Under a
    # fiber-per-request server (Falcon) streams are cheap and the window can be
    # minutes; Mercure, the dedicated SSE hub, defaults to 600s. Whatever the
    # length, the cursor makes the close/reopen lossless.
    config.instant_record.sse_window_seconds = 25.0

    # Idle heartbeat: an SSE comment written when nothing else has been for
    # this long. Two jobs. Reverse proxies kill connections they think are
    # idle (commonly at 60-100s), and a comment resets that clock. And a
    # vanished client — closed laptop, dropped network — is only discovered
    # when a write fails; on a quiet stream the heartbeat is that write, so a
    # dead peer's fiber is collected within one interval instead of surviving
    # to the end of the window. Comments are invisible to clients: EventSource
    # ignores them by spec, and the gem's own parser skips blocks with no
    # `data:` line. 0 disables.
    config.instant_record.sse_heartbeat_seconds = 15.0

    initializer "instant_record.migrations" do |app|
      unless app.root == root
        config.paths["db/migrate"].expanded.each do |path|
          app.config.paths["db/migrate"] << path unless app.config.paths["db/migrate"].include?(path)
        end
      end
    end

    # Auto-mount the sync endpoints on the server. Set
    # `config.instant_record.mount_path = false` to mount manually,
    # or to another string to change the path.
    initializer "instant_record.mount" do |app|
      next if InstantRecord.browser?

      mount_path = app.config.instant_record.mount_path
      next unless mount_path

      InstantRecord.config.endpoint = mount_path if mount_path.is_a?(String) && InstantRecord.config.endpoint == DEFAULT_MOUNT_PATH

      app.routes.append do
        mount InstantRecord::Engine => mount_path
      end
    end
  end
end
