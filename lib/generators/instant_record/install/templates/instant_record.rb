# InstantRecord configuration.
# See README.md and compiled/README.md for full details.

InstantRecord.configure do |config|
  # Identify who is making each sync request (for models declaring `sync_scope`
  # or `syncable_to` / `writable_by`). The default trusts a `scope` query param;
  # apps with authentication should read the user from the session instead:
  #
  #   config.scope_from = ->(request) { User.find_by(id: request.session[:user_id]) }

  # Where the server stores files attached to `sync_file` models.
  # Defaults to Rails.root.join("storage/instant_record").
  #
  #   config.file_store = InstantRecord::FileStore.new(Rails.root.join("storage/instant_record"))

  # Default maximum file size in bytes for `sync_file` models without their own `max_size:`.
  # Defaults to 2 GiB (InstantRecord::Files::MAX_SIZE).
  #
  #   config.max_file_size = 500 * 1024 * 1024
end

# Optional: restrict syncing to an explicit allowlist of models.
# Without this, every model that includes `InstantRecord::Syncable` syncs.
#
#   InstantRecord.sync(Issue, Note)

# Railtie options (set in config/application.rb or config/environments/*.rb):
#
#   config.instant_record.mount_path = "/instant_record"   # or false to mount manually
#   config.instant_record.compiled_host = "app.example.com"
#   config.instant_record.build_on_precompile = :compiled  # publish during assets:precompile
#   config.instant_record.native_dev = true                # serve app/screens over HTTP in development
#   config.instant_record.sse_window_seconds = 25.0        # raise under Falcon (e.g. 600.0)
#   config.instant_record.sse_heartbeat_seconds = 15.0
