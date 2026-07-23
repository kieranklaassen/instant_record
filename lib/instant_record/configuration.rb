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

    def initialize
      @endpoint = DEFAULT_MOUNT_PATH
      @sync_interval = 3
    end
  end
end
