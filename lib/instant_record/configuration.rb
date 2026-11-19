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

    def initialize
      @endpoint = DEFAULT_MOUNT_PATH
      @sync_interval = 3
      @scope_from = ->(request) { request.params["scope"] }
    end
  end
end
