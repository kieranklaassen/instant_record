module InstantRecord
  class Engine < ::Rails::Engine
    isolate_namespace InstantRecord

    config.instant_record = ActiveSupport::OrderedOptions.new
    config.instant_record.mount_path = DEFAULT_MOUNT_PATH
    config.instant_record.build_on_precompile = false
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

    # `ActiveRecord::Migrator.migrations_paths` stays as Rails ships it — the
    # relative "db/migrate", which resolves only because a server's working
    # directory happens to be Rails.root. The browser VM starts at "/", so
    # nothing there can be fixed by an initializer: reconciling
    # `schema_migrations` before migrating needs a database connection, which no
    # initializer is guaranteed. That work is InstantRecord.prepare_database! —
    # the boot path's replacement for `prepare_all`, see LocalSchema. Leaving the
    # global default alone is deliberate: it keeps `prepare_all`'s own internal
    # migrate a no-op, so the reconciliation runs before any migration does.

    # One gap in the PGlite adapter has to be closed before any of that can run
    # a migration; see instant_record/pglite_compat.
    initializer "instant_record.pglite_compat" do
      next unless InstantRecord.browser?

      require "instant_record/pglite_compat"
    end

    # Auto-mount the sync endpoints on the server. Set
    # `config.instant_record.mount_path = false` to mount manually,
    # or to another string to change the path.
    initializer "instant_record.mount" do |app|
      next if InstantRecord.browser?

      mount_path = app.config.instant_record.mount_path
      next unless mount_path

      app.routes.append do
        mount InstantRecord::Engine => mount_path
      end
    end
  end
end
