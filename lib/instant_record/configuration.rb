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
    # declare sync_scope. The default trusts a `scope` parameter, which suits a
    # demo where an unguessable token stands for a visitor. An app with
    # sign-in reads it from the session instead:
    #
    #   config.scope_from = ->(request) { request.session[:user_id] }
    attr_accessor :scope_from

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

    # Maximum number of outbox mutations sent in a single POST /mutations
    # request. Bounding the batch keeps large offline backlogs chunked and
    # lets 5xx poison-pill isolation narrow down a single failing mutation.
    attr_accessor :drain_batch_size

    # Number of consecutive 5xx responses on an isolated single mutation before
    # quarantining it as a poison pill so subsequent writes can keep draining.
    attr_accessor :max_server_error_retries

    def initialize
      @endpoint = DEFAULT_MOUNT_PATH
      @sync_interval = 3
      @drain_batch_size = 100
      @max_server_error_retries = 3
      @file_store = nil
      @max_file_size = nil
      @scope_from = ->(request) { request.params["scope"] }
    end
  end
end
