# frozen_string_literal: true

require "json"
require "rack/files"
require "rack/mime"
require "rack/request"
require "rack/sendfile"

module InstantRecord
  # Serve the published browser artifact on the host chosen by the application.
  # The sync engine, health checks and non-navigation requests still reach Rails.
  class CompiledSite
    # A tab can receive the old HTML just before a deploy and request its
    # content-addressed worker or Wasm just after the release link switches.
    FINGERPRINTED = %r{\A/(?:app-[0-9a-f]+\.wasm|harness/[\w.-]+-[\w-]{8}\.js)\z}

    # Best first.
    ENCODINGS = { "br" => ".br", "gzip" => ".gz" }.freeze

    # A manifest changed more recently than this is read again on each request: a
    # second write within one timestamp tick would leave its stat the same.
    SETTLE_SECONDS = 2

    WASM_ASSET = %r{\A/app-[a-f0-9]+\.wasm\z}
    SLASH_RUN = %r{/+}
    PARAM_TOKEN = /:[a-zA-Z_]\w*/
    Q_ZERO = /\Aq=0(?:\.0*)?\z/
    SIMPLE_PATH = %r{\A(?:/[^/.%\\\0][^/%\\\0]*)+\z}
    ASCII_DIGITS = /\A[0-9]+\z/
    ENCODING_LIST = ENCODINGS.to_a.each(&:freeze).freeze
    ACCEPT_PATTERNS = ENCODINGS.each_key.each_with_object({}) do |encoding, map|
      escaped = Regexp.escape(encoding)
      map[encoding] = /(?:\A|,)[ \t\r\n\f\v\0]*+#{escaped}[ \t\r\n\f\v\0]*+(?:;[ \t\r\n\f\v\0]*+(?!q=0(?:\.0*)?[ \t\r\n\f\v\0]*+(?:;|,|\z))[^;,]*+)*(?:,|\z)/i
    end.freeze
    VARY_ACCEPT_ENCODING = "accept-encoding"
    CACHE_IMMUTABLE = "public, max-age=31536000, immutable"
    CACHE_NO_CACHE = "no-cache"
    INDEX_PATH_INFO = "/index.html"
    INDEX_EXT = ".html"
    MIME_BINARY = "application/octet-stream"
    MIME_TEXT = "text/plain"
    ManifestCache = Data.define(:dev, :ino, :size, :mtime, :ctime, :routes, :static, :by_segment, :fallback, :non_ascii_encoding)

    private_constant :SETTLE_SECONDS, :WASM_ASSET, :SLASH_RUN, :PARAM_TOKEN, :Q_ZERO,
      :SIMPLE_PATH, :ASCII_DIGITS, :ENCODING_LIST, :ACCEPT_PATTERNS, :VARY_ACCEPT_ENCODING,
      :CACHE_IMMUTABLE, :CACHE_NO_CACHE, :INDEX_PATH_INFO, :INDEX_EXT, :MIME_BINARY,
      :MIME_TEXT, :ManifestCache

    def initialize(app, host:, root:, sync_path:)
      @app = app
      @host = host
      @host_exact_authority = host.is_a?(String) && Rack::Request.new("HTTP_HOST" => host).host == host
      @host_colon = @host_exact_authority ? "#{host}:".freeze : nil
      @root = root
      @files = Rack::Files.new(root)
      @files_root = @files.root.chomp("/").freeze
      @releases = File.dirname(root)
      @sync_path = sync_path
      @sync_prefix = "#{sync_path}/".freeze
      @service_worker_path = File.join(root, "service-worker.js").freeze
      @manifest = File.join(root, "instant_record.manifest.json").freeze
      @index_disk_path = "#{@files_root}#{INDEX_PATH_INFO}".freeze
      @index_compressed_paths = ENCODING_LIST.map { |encoding, ext| [encoding, "#{@index_disk_path}#{ext}".freeze].freeze }.freeze
      # Written in one step and outside the instance, which may be frozen.
      @kept = [nil]
      @httpdate = [nil]
    end

    def call(env)
      method = env["REQUEST_METHOD"]
      return @app.call(env) unless method == "GET" || method == "HEAD"
      return @app.call(env) unless host_matches?(env)

      raw_path = env["PATH_INFO"]
      path = raw_path.instance_of?(String) ? raw_path : raw_path.to_s
      return @app.call(env) if path == "/up" || path == @sync_path || path.start_with?(@sync_prefix)

      serve_as_is =
        path.start_with?("/assets/", "/harness/") ||
        WASM_ASSET.match?(path) ||
        path == "/instant-record-release.json" ||
        path == "/instant_record.manifest.json" ||
        (path == "/service-worker.js" && File.file?(@service_worker_path))

      unless serve_as_is
        accept = env["HTTP_ACCEPT"]
        return @app.call(env) unless accept && (accept.instance_of?(String) ? accept : accept.to_s).include?("text/html") && local_island_path?(path)
      end

      if serve_as_is
        immutable = FINGERPRINTED.match?(path)
        cache_control = immutable ? CACHE_IMMUTABLE : CACHE_NO_CACHE
        if env["HTTP_RANGE"].nil? && path.valid_encoding? && SIMPLE_PATH.match?(path)
          response = serve_simple_path(env, path, method, cache_control)
          return response if response
        end

        status, headers, body = precompressed(env) || @files.call(env)
        if status == 404 && immutable
          Dir.glob(File.join(@releases, "[a-f0-9]" * 64)).each do |release|
            next unless File.file?(File.join(release, path.delete_prefix("/")))
            body.close if body.respond_to?(:close)
            status, headers, body = Rack::Files.new(release).call(env)
            break
          end
        end
        headers["vary"] = VARY_ACCEPT_ENCODING
        headers["cache-control"] = immutable && (status == 200 || status == 206 || status == 304) ? CACHE_IMMUTABLE : CACHE_NO_CACHE
        [status, headers, body]
      else
        if env["HTTP_RANGE"].nil?
          response = serve_index(env, method, CACHE_NO_CACHE)
          return response if response
        end

        status, headers, body = @files.call(env.merge("PATH_INFO" => INDEX_PATH_INFO))
        headers["vary"] = VARY_ACCEPT_ENCODING
        headers["cache-control"] = CACHE_NO_CACHE
        [status, headers, body]
      end
    end

    private

    def host_matches?(env)
      if @host_exact_authority && env["HTTP_FORWARDED"].nil? && env["HTTP_X_FORWARDED_HOST"].nil?
        http_host = env["HTTP_HOST"]
        if http_host.instance_of?(String)
          return true if http_host == @host
          return port_suffix_only?(http_host) if http_host.start_with?(@host_colon)
          return false
        elsif http_host.nil?
          server_name = env["SERVER_NAME"]
          if server_name.instance_of?(String)
            port = env["SERVER_PORT"]
            if server_name == @host
              return true if port.nil?
              return ASCII_DIGITS.match?(port) if port.instance_of?(String)
            elsif port.nil?
              return port_suffix_only?(server_name) if server_name.start_with?(@host_colon)
              return false
            else
              return false
            end
          end
        end
      end

      Rack::Request.new(env).host == @host
    end

    def port_suffix_only?(http_host)
      i = @host_colon.bytesize
      len = http_host.bytesize
      return false if i >= len

      while i < len
        byte = http_host.getbyte(i)
        return false if byte < 48 || byte > 57
        i += 1
      end
      true
    end

    # The build writes .br and .gz copies next to what compresses (WasmBuild#precompress).
    # A build without them, or a ranged request, is served as it is.
    def serve_index(env, method, cache_control)
      accept_encoding = env["HTTP_ACCEPT_ENCODING"]
      if accept_encoding
        @index_compressed_paths.each do |encoding, candidate|
          next unless accepts?(accept_encoding, encoding)
          if (stat = stat_readable_file(candidate, probe: false))
            mime_type = Rack::Mime::MIME_TYPES[INDEX_EXT] || Rack::Mime.mime_type(INDEX_EXT, MIME_BINARY)
            return build_file_response(candidate, stat, env, method, mime_type, encoding, cache_control)
          end
        end
      end

      if (stat = stat_readable_file(@index_disk_path, probe: false))
        mime_type = Rack::Mime::MIME_TYPES[INDEX_EXT] || Rack::Mime.mime_type(INDEX_EXT, MIME_TEXT)
        return build_file_response(@index_disk_path, stat, env, method, mime_type, nil, cache_control)
      end

      nil
    end

    def serve_simple_path(env, path, method, cache_control)
      disk_path = "#{@files_root}#{path}"
      accept_encoding = env["HTTP_ACCEPT_ENCODING"]
      if accept_encoding
        ENCODING_LIST.each do |encoding, extension|
          next unless accepts?(accept_encoding, encoding)
          candidate = "#{disk_path}#{extension}"
          if (stat = stat_readable_file(candidate, probe: true))
            mime_type = mime_type_for_path(path, MIME_BINARY)
            return build_file_response(candidate, stat, env, method, mime_type, encoding, cache_control)
          end
        end
      end

      if (stat = stat_readable_file(disk_path, probe: false))
        mime_type = mime_type_for_path(path, MIME_TEXT)
        return build_file_response(disk_path, stat, env, method, mime_type, nil, cache_control)
      end

      nil
    end

    def precompressed(env)
      return if env["HTTP_RANGE"]

      path = env["PATH_INFO"]
      accept_encoding = env["HTTP_ACCEPT_ENCODING"]
      return unless accept_encoding

      ENCODING_LIST.each do |encoding, extension|
        next unless accepts?(accept_encoding, encoding)

        status, headers, body = @files.call(env.merge("PATH_INFO" => "#{path}#{extension}"))
        unless status == 200 || status == 304
          body.close if body.respond_to?(:close)
          next
        end
        headers["content-type"] = Rack::Mime.mime_type(File.extname(path), MIME_BINARY) if status == 200
        headers["content-encoding"] = encoding if status == 200
        return [status, headers, body]
      end
      nil
    end

    def stat_readable_file(disk_path, probe:)
      return nil if probe && !File.file?(disk_path)
      stat = File.stat(disk_path)
      stat if stat.file? && File.readable?(disk_path)
    rescue SystemCallError
      nil
    end

    def mime_type_for_path(path, fallback)
      ext =
        if path.end_with?(".js") && path.bytesize > 4 && path.getbyte(-4) != 47
          ".js"
        elsif path.end_with?(".css") && path.bytesize > 5 && path.getbyte(-5) != 47
          ".css"
        elsif path.end_with?(".wasm") && path.bytesize > 6 && path.getbyte(-6) != 47
          ".wasm"
        elsif path.end_with?(".json") && path.bytesize > 6 && path.getbyte(-6) != 47
          ".json"
        elsif path.end_with?(".html") && path.bytesize > 6 && path.getbyte(-6) != 47
          ".html"
        else
          File.extname(path)
        end
      Rack::Mime::MIME_TYPES[ext] || Rack::Mime.mime_type(ext, fallback)
    end

    def build_file_response(disk_path, stat, env, method, mime_type, content_encoding, cache_control)
      last_modified = httpdate_for(stat.mtime)
      if env["HTTP_IF_MODIFIED_SINCE"] == last_modified
        return [304, { "vary" => VARY_ACCEPT_ENCODING, "cache-control" => cache_control }, []]
      end

      size = stat.size
      size = File.read(disk_path).bytesize if size == 0
      headers =
        if content_encoding
          {
            "last-modified" => last_modified,
            "content-type" => mime_type,
            "content-length" => size.to_s,
            "content-encoding" => content_encoding,
            "vary" => VARY_ACCEPT_ENCODING,
            "cache-control" => cache_control
          }
        else
          {
            "last-modified" => last_modified,
            "content-type" => mime_type,
            "content-length" => size.to_s,
            "vary" => VARY_ACCEPT_ENCODING,
            "cache-control" => cache_control
          }
        end
      body = method == "HEAD" ? [] : Rack::Files::Iterator.new(disk_path, [0..size - 1], mime_type: mime_type, size: size)
      [200, headers, body]
    end

    def httpdate_for(mtime)
      sec = mtime.to_i
      cached = @httpdate[0]
      return cached[1] if cached && cached[0] == sec

      formatted = mtime.httpdate.freeze
      @httpdate[0] = [sec, formatted].freeze
      formatted
    end

    def accepts?(header, encoding)
      return false if header.nil?

      str = header.instance_of?(String) ? header : header.to_s
      return false if str.empty?

      if str.valid_encoding? && (pattern = ACCEPT_PATTERNS[encoding])
        if (idx = str.byteindex(encoding))
          left_ok = idx == 0 ||
            str.getbyte(idx - 1) == 44 ||
            (str.getbyte(idx - 1) == 32 && idx >= 2 && str.getbyte(idx - 2) == 44)
          if left_ok
            end_idx = idx + encoding.bytesize
            return true if end_idx == str.bytesize || str.getbyte(end_idx) == 44
          end
        end
        return pattern.match?(str)
      end

      str.downcase.split(",").any? do |item|
        name, *params = item.split(";").map(&:strip)
        name == encoding && params.none? { |param| param.match?(Q_ZERO) }
      end
    end

    def local_island_path?(path)
      stat = File.stat(@manifest)
      return true unless stat.file?

      cached = @kept[0]
      if cached && same_manifest?(cached, stat)
        return true if cached.routes.empty?

        normalized = normalize_request_path(path)
        if cached.static && fast_route_encoding_safe?(cached, normalized)
          return match_indexed_routes?(cached, normalized)
        end
        return match_routes_sequentially?(cached.routes, normalized)
      end

      routes = read_local_routes
      return true if routes.empty?

      normalized = normalize_request_path(path)
      match_routes_sequentially?(routes, normalized)
    rescue JSON::ParserError, SystemCallError
      true
    end

    def normalize_request_path(path)
      normalized = path.instance_of?(String) ? path : path.to_s
      if !normalized.valid_encoding? || normalized.include?("//")
        normalized = normalized.gsub(SLASH_RUN, "/")
      end
      normalized = normalized.delete_suffix("/") if normalized.length > 1 && normalized.end_with?("/")
      normalized
    end

    def same_manifest?(cached, stat)
      cached.ino == stat.ino &&
        cached.size == stat.size &&
        cached.dev == stat.dev &&
        cached.mtime == stat.mtime &&
        cached.ctime == stat.ctime
    end

    def fast_route_encoding_safe?(cached, normalized)
      return false unless normalized.encoding.ascii_compatible?
      non_ascii = cached.non_ascii_encoding
      return true if non_ascii.nil?
      normalized.encoding == non_ascii || normalized.ascii_only?
    end

    def match_indexed_routes?(cached, normalized)
      return true if cached.static.key?(normalized)

      by_segment = cached.by_segment
      if by_segment && normalized.bytesize > 1 && normalized.getbyte(0) == 47
        slash = normalized.byteindex("/", 1)
        segment = slash ? normalized.byteslice(1, slash - 1) : normalized.byteslice(1, normalized.bytesize - 1)
        if (regex = by_segment[segment]) && regex.match?(normalized)
          return true
        end
      end

      fallback = cached.fallback
      fallback ? fallback.match?(normalized) : false
    end

    def match_routes_sequentially?(routes, normalized)
      routes.any? { |route| (route.is_a?(Regexp) ? route : route_pattern_to_regex(route)).match?(normalized) }
    end

    # Empty when the manifest leaves every path to the browser.
    def read_local_routes
      File.open(@manifest) do |file|
        # Taken before the read, so a write during it changes the identity.
        read_at = now
        stat = file.stat
        raw_routes = parse_routes(file.read)
        mtime = stat.mtime
        ctime = stat.ctime
        latest = mtime > ctime ? mtime : ctime
        if latest < read_at - SETTLE_SECONDS
          routes = raw_routes.map { |pattern| kept_pattern(pattern) }.freeze
          @kept[0] = build_manifest_cache(stat, mtime, ctime, raw_routes, routes)
          return routes
        end
        raw_routes
      end
    end

    def build_manifest_cache(stat, mtime, ctime, raw_routes, routes)
      all_regex = routes.all? { |r| r.is_a?(Regexp) }
      unless all_regex
        return ManifestCache.new(stat.dev, stat.ino, stat.size, mtime, ctime, routes, nil, nil, nil, nil)
      end

      static = {}
      by_segment = {}
      fallback = []
      non_ascii_encoding = nil
      mixed_encodings = false

      raw_routes.each_with_index do |pattern, idx|
        regex = routes[idx]
        if regex.fixed_encoding?
          if non_ascii_encoding.nil?
            non_ascii_encoding = regex.encoding
          elsif non_ascii_encoding != regex.encoding
            mixed_encodings = true
          end
        end

        norm = normalize_route_pattern(pattern)
        if norm == "/"
          static["/"] = true
          next
        end

        segments = norm.delete_prefix("/").split("/")
        if segments.none? { |segment| dynamic_segment?(segment) }
          static[norm] = true
        else
          first = segments[0]
          if dynamic_segment?(first)
            fallback << regex
          else
            (by_segment[first] ||= []) << regex
          end
        end
      end

      if mixed_encodings
        return ManifestCache.new(stat.dev, stat.ino, stat.size, mtime, ctime, routes, nil, nil, nil, nil)
      end

      by_segment = by_segment.empty? ? nil : by_segment.transform_values { |list| list.length == 1 ? list[0] : Regexp.union(list) }.freeze
      compiled_fallback = fallback.empty? ? nil : (fallback.length == 1 ? fallback[0] : Regexp.union(fallback))

      ManifestCache.new(stat.dev, stat.ino, stat.size, mtime, ctime, routes, static.freeze, by_segment, compiled_fallback, non_ascii_encoding)
    end

    def dynamic_segment?(segment)
      segment.start_with?("*", ":") || PARAM_TOKEN.match?(segment)
    end

    def normalize_route_pattern(pattern)
      norm = pattern.to_s.gsub(SLASH_RUN, "/")
      norm = "/#{norm}" unless norm.start_with?("/")
      norm = norm.delete_suffix("/") if norm.length > 1
      norm
    end

    def now
      Time.now
    end

    def parse_routes(json)
      data = JSON.parse(json)
      return [] unless data["mode"] == "island"

      Array(data["local_routes"]).select { |r| r["method"].to_s.upcase == "GET" && r["path"] }.map { |r| r["path"] }
    end

    # A pattern that cannot be built raises when a path reaches it, not before.
    def kept_pattern(pattern)
      route_pattern_to_regex(pattern)
    rescue StandardError
      pattern
    end

    def route_pattern_to_regex(pattern)
      norm = normalize_route_pattern(pattern)
      return /\A\/\z/ if norm == "/"

      segments = norm.delete_prefix("/").split("/").map do |segment|
        if segment.start_with?("*")
          ".+"
        elsif segment.start_with?(":")
          "[^/]+"
        else
          Regexp.escape(segment).gsub(PARAM_TOKEN, "[^/]+")
        end
      end
      /\A\/#{segments.join("/")}\/?\z/
    end
  end
end
