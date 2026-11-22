module InstantRecord
  class Configuration
    # Where the authoritative Rails app's sync engine is mounted. Same-origin
    # relative path by default; set an absolute URL for cross-origin dev
    # setups (e.g. Vite on :5173 talking to Rails on :3000).
    attr_accessor :endpoint

    # Base delay, in seconds, for retrying an outbox drain that did not get
    # through. It is not a poll cadence: the browser has no heartbeat, because
    # writes trigger their own sync pass and the change stream carries
    # everything inbound. A client with an empty outbox makes no requests at all.
    attr_accessor :sync_interval

    # Reads a sync request's scope: whose rows it may be sent, for models that
    # declare sync_scope. The default reads the `X-Instant-Record-Scope` header
    # or `scope` parameter. An app with sign-in reads it from the session or an
    # Authorization header instead:
    #
    #   config.scope_from = ->(request) { request.session[:user_id] }
    attr_accessor :scope_from

    # Reads a sync request's active multi-tenant partition, for models that
    # declare `sync_partition`. Default reads the `X-Instant-Record-Partition`
    # header or `sync_partition` parameter (and `partition` on bootstrap, events,
    # and mutations). May accept `(request)` or `(request, identity)` and may
    # raise `InstantRecord::Unauthorized` or `InstantRecord::Forbidden`.
    attr_accessor :partition_from

    # Optional server-side request authenticator invoked before serving any
    # non-preflight sync endpoint. Raise `InstantRecord::Unauthorized` (401)
    # or `InstantRecord::Forbidden` (403) to reject the request.
    attr_accessor :authenticate_request

    # Pluggable client-side headers sent on every outbound sync request
    # (bootstrap, mutations, events, history). Accepts a Hash or a callable
    # returning a Hash.
    attr_accessor :headers

    # Client-side scope token sent as `X-Instant-Record-Scope`.
    attr_accessor :sync_scope

    # Client-side active partition sent as `X-Instant-Record-Partition`
    # (String like "support" / "mailbox_id:support", or Hash).
    attr_accessor :sync_partition

    # Client-side bearer/auth token sent as `Authorization`. Plain tokens are
    # prefixed with "Bearer "; values containing a space are sent verbatim.
    attr_accessor :auth_token

    # Where the server keeps the bytes of records that declare sync_file:
    # anything that answers as InstantRecord::FileStore does. Left alone, they
    # go under storage/instant_record in the app.
    attr_accessor :file_store

    # The most bytes the server takes for one file, for a model whose
    # sync_file names no max_size of its own. Left alone it is
    # InstantRecord::Files::MAX_SIZE. That number is written there and not
    # here: this file is compiled for the browser, where an integer has 32
    # bits, and two gigabytes do not fit in one.
    attr_accessor :max_file_size

    def initialize
      @endpoint = DEFAULT_MOUNT_PATH
      @sync_interval = 3
      @file_store = nil
      @max_file_size = nil
      @authenticate_request = nil
      @headers = nil
      @sync_scope = nil
      @sync_partition = nil
      @auth_token = nil
      @scope_from = lambda do |request|
        header = request.respond_to?(:headers) ? request.headers["X-Instant-Record-Scope"] : nil
        value = header && !header.to_s.empty? ? header : request.params["scope"]
        value && !value.to_s.empty? ? value : nil
      end
      @partition_from = lambda do |request|
        header = request.respond_to?(:headers) ? request.headers["X-Instant-Record-Partition"] : nil
        return header if header && !header.to_s.empty?

        explicit = request.params["sync_partition"]
        return explicit if explicit && !explicit.to_s.empty?

        # `/records` uses `partition` for `sync_window(partition_by:)`; only fall
        # back to `params["partition"]` when the request is not a windowed query.
        path = request.respond_to?(:path) ? request.path.to_s : ""
        unless path.end_with?("/records") && request.params["before_id"].present?
          param = request.params["partition"]
          return param if param && !param.to_s.empty?
        end
        nil
      end
    end
  end
end
