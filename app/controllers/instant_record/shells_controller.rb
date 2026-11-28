require "instant_record/sync_endpoint"

module InstantRecord
  # Prebuilt SQLite cold-start shell delivery, partitioned by SyncScope.
  #
  # GET /instant_record/shell?fingerprint=<sha256>
  #   Returns a short-lived signed grant URL when a shell matching the client's
  #   compiled schema fingerprint exists and is still within retention. Returns
  #   204 No Content otherwise (sending the client to /bootstrap) and schedules
  #   an out-of-band build when the caller's identity is job-serializable.
  #
  # GET /instant_record/shell/file?token=<signed>
  #   Verifies the HMAC signature, expiry, purpose, AND that the live request's
  #   SyncScope identity matches the partition the grant was issued for.
  #   Marked `private, no-store` so private shells never enter shared caches.
  class ShellsController < ActionController::API
    include SyncEndpoint

    HEADERS = InstantRecord::CORS_HEADERS.merge(
      "cache-control" => "private, no-store",
      "vary" => "Authorization, Cookie"
    ).freeze

    self.sync_headers = HEADERS

    def show
      SyncScope.authenticate!(request)
      expected = Shell.fingerprint
      return head :no_content unless params[:fingerprint].to_s == expected

      identity = SyncScope.identity(request)
      partition = Shell.partition_key(identity)
      revision = Change.maximum(:id) || 0
      shell = Shell.latest(partition, fingerprint: expected)

      if (shell.nil? || shell.stale?(revision)) && Shell.serializable_identity?(identity)
        ShellBuildJob.perform_later(Shell.dump_identity(identity))
      end

      return head :no_content unless shell&.servable?(revision)

      render json: {
        cursor: shell.cursor,
        bytes: shell.bytes,
        built_at: shell.built_at.utc.iso8601,
        identity: SyncScope.key(identity),
        path: "/shell/file?#{{ token: shell.signed_token(holder: partition) }.to_query}"
      }
    end

    def file
      SyncScope.authenticate!(request)
      identity = SyncScope.identity(request)
      partition = Shell.partition_key(identity)
      shell = Shell.find_signed(params[:token].to_s, partition: partition, holder: partition)
      return head :not_found unless shell

      headers["x-content-type-options"] = "nosniff"
      send_file shell.path, type: "application/vnd.sqlite3", disposition: "inline"
    end
  end
end
