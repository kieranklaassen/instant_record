require "pathname"
require_relative "version"
require_relative "mcp/http_exchange"
require_relative "mcp/host_process"
require_relative "mcp/replica"
require_relative "mcp/runtime"
require_relative "mcp/server"
require_relative "mcp/cli"

module InstantRecord
  # Local MCP stdio server and offline CLI around a compiled native `host`
  # binary (`InstantRecord::Compiler::NativeBuild`). Keeps a scoped local
  # SQLite replica in sync with the Rails server using configurable auth and
  # serves synced model queries, search, and validated local actions offline
  # in sub-millisecond time.
  module Mcp
    Error = Class.new(StandardError)
    HostError = Class.new(Error)
    HostCrashedError = Class.new(HostError)

    module_function

    def default_host_path(root)
      app_root = Pathname(root).expand_path
      candidates = [
        app_root.join("tmp/instant_record/compiled/.build-native/host"),
        app_root.join("../compiled/.build-native/host").cleanpath
      ]
      found = candidates.find { |path| path.file? && path.executable? }
      (found || candidates.first).to_s
    end

    def default_database_path(root, scope: nil)
      slug = scope.to_s.strip.gsub(/[^a-zA-Z0-9._-]+/, "_")
      slug = "default" if slug.empty?
      Pathname(root).expand_path.join("tmp/instant_record/mcp", "#{slug}.sqlite3").to_s
    end

    def runtime(**options)
      Runtime.new(**options)
    end

    def server(runtime, **options)
      Server.new(runtime, **options)
    end
  end
end
