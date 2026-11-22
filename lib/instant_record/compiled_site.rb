require "json"
require "rack/files"
require "rack/request"
require "rack/sendfile"

module InstantRecord
  # Serve the published browser artifact on the host chosen by the application.
  # The sync engine, health checks and non-navigation requests still reach Rails.
  class CompiledSite
    # A tab can receive the old HTML just before a deploy and request its
    # content-addressed worker or Wasm just after the release link switches.
    FINGERPRINTED = %r{\A/(?:app-[0-9a-f]+\.wasm|harness/[\w.-]+-[\w-]{8}\.js)\z}

    def initialize(app, host:, root:, sync_path:)
      @app = app
      @host = host
      @root = root
      @files = Rack::Files.new(root)
      @releases = File.dirname(root)
      @sync_path = sync_path
    end

    def call(env)
      request = Rack::Request.new(env)
      path = request.path_info
      return @app.call(env) unless request.host == @host && (request.get? || request.head?)
      return @app.call(env) if path == "/up" || path == @sync_path || path.start_with?("#{@sync_path}/")

      asset = path.start_with?("/assets/", "/harness/") || path.match?(%r{\A/app-[a-f0-9]+\.wasm\z}) ||
        (path == "/service-worker.js" && File.file?(File.join(@root, "service-worker.js")))
      manifest = path == "/instant-record-release.json" || path == "/instant_record.manifest.json"
      html = request.get_header("HTTP_ACCEPT").to_s.include?("text/html")
      return @app.call(env) unless asset || manifest || (html && local_island_path?(path))
      status, headers, body = @files.call(asset || manifest ? env : env.merge("PATH_INFO" => "/index.html"))
      immutable = FINGERPRINTED.match?(path)
      if status == 404 && immutable
        Dir.glob(File.join(@releases, "[a-f0-9]" * 64)).each do |release|
          next unless File.file?(File.join(release, path.delete_prefix("/")))
          body.close if body.respond_to?(:close)
          status, headers, body = Rack::Files.new(release).call(env)
          break
        end
      end
      headers["cache-control"] = immutable && [200, 206, 304].include?(status) ? "public, max-age=31536000, immutable" : "no-cache"
      [status, headers, body]
    end

    private

    def local_island_path?(path)
      manifest_file = File.join(@root, "instant_record.manifest.json")
      return true unless File.file?(manifest_file)

      data = JSON.parse(File.read(manifest_file))
      return true unless data["mode"] == "island"

      routes = Array(data["local_routes"]).select { |r| r["method"].to_s.upcase == "GET" && r["path"] }
      return true if routes.empty?

      normalized = path.to_s.gsub(%r{/+}, "/")
      normalized = normalized.delete_suffix("/") if normalized.length > 1
      routes.any? { |route| route_pattern_to_regex(route["path"]).match?(normalized) }
    rescue JSON::ParserError, SystemCallError
      true
    end

    def route_pattern_to_regex(pattern)
      norm = pattern.to_s.gsub(%r{/+}, "/")
      norm = "/#{norm}" unless norm.start_with?("/")
      norm = norm.delete_suffix("/") if norm.length > 1
      return /\A\/\z/ if norm == "/"

      segments = norm.delete_prefix("/").split("/").map do |segment|
        if segment.start_with?("*")
          ".+"
        elsif segment.start_with?(":")
          "[^/]+"
        else
          Regexp.escape(segment).gsub(/:[a-zA-Z_]\w*/, "[^/]+")
        end
      end
      /\A\/#{segments.join("/")}\/?\z/
    end
  end
end
