module InstantRecord
  class Configuration
    # Where the authoritative Rails app's sync engine is mounted. Same-origin
    # relative path by default; set an absolute URL for cross-origin dev
    # setups (e.g. Vite on :5173 talking to Rails on :3000).
    attr_accessor :endpoint

    # Seconds between background sync ticks in the browser.
    attr_accessor :sync_interval

    def initialize
      @endpoint = "/instant_record"
      @sync_interval = 3
    end
  end
end
