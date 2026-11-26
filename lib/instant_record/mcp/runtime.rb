require "json"
require "uri"

module InstantRecord
  module Mcp
    # Coordinates the compiled native `host` process, HTTP sync exchange (with
    # configurable token/cookie/header/scope auth), and the <1ms read-only
    # SQLite replica reader under a single serial mutex.
    class Runtime
      MissingEndpoint = Class.new(ArgumentError)

      attr_reader :database_path, :endpoint, :screens, :exchange

      def initialize(
        host_binary: nil,
        database_path:,
        endpoint: nil,
        token: nil,
        cookie: nil,
        headers: {},
        scope: nil,
        offline: false,
        timeout: HttpExchange::DEFAULT_TIMEOUT,
        models: nil,
        screens: [],
        exchange: nil,
        host_process: nil,
        err: nil
      )
        @database_path = File.expand_path(database_path.to_s)
        @endpoint = normalize_endpoint(endpoint)
        @screens = Array(screens).map(&:to_s).sort.uniq
        @models = models
        @mutex = Mutex.new

        @exchange = exchange || HttpExchange.new(
          token: token,
          cookie: cookie,
          headers: headers,
          scope: scope,
          offline: offline,
          timeout: timeout
        )
        @host = host_process || HostProcess.new(
          binary: host_binary,
          database: @database_path,
          exchange: @exchange,
          err: err
        )
        @replica = Replica.new(database_path: @database_path, models: @models)
      end

      def offline?
        @exchange.respond_to?(:offline?) ? @exchange.offline? : false
      end

      def offline=(value)
        @exchange.offline = !!value if @exchange.respond_to?(:offline=)
      end

      def status
        @mutex.synchronize do
          started = monotonic_now
          pos = parse_cursor(@host.call("cursor", "").out)
          models_summary = @replica.models["models"]
          {
            "database" => @database_path,
            "endpoint" => @endpoint,
            "offline" => offline?,
            "cursor" => pos["cursor"].to_i,
            "pending" => pos["pending"].to_i,
            "bootstrap" => pos["bootstrap"] || "needed",
            "identity" => pos["identity"].to_s,
            "screens" => @screens,
            "models" => models_summary,
            "elapsed_ms" => elapsed_ms(started)
          }
        end
      end

      def sync(endpoint: nil)
        @mutex.synchronize do
          started = monotonic_now
          target = normalize_endpoint(endpoint) || @endpoint
          raise MissingEndpoint, "No sync endpoint configured. Pass endpoint or set INSTANT_RECORD_ENDPOINT." if target.nil?

          if offline?
            pos = parse_cursor(@host.call("cursor", "").out)
            return {
              "ok" => false,
              "offline" => true,
              "endpoint" => target,
              "error" => "Client is in offline mode",
              "cursor" => pos["cursor"].to_i,
              "pending" => pos["pending"].to_i,
              "bootstrap" => pos["bootstrap"] || "needed",
              "identity" => pos["identity"].to_s,
              "elapsed_ms" => elapsed_ms(started)
            }
          end

          @exchange.reset_trace! if @exchange.respond_to?(:reset_trace!)
          result = @host.call("sync", target)
          pos = parse_cursor(@host.call("cursor", "").out)
          @replica.refresh_schema!

          went_offline = @exchange.respond_to?(:any_offline?) && @exchange.any_offline?
          http_err = @exchange.respond_to?(:last_error_status) ? @exchange.last_error_status : nil
          last_http = @exchange.respond_to?(:last_status) ? @exchange.last_status : nil
          changed = result.out.start_with?("changed")
          ok = !went_offline && http_err.nil?

          payload = {
            "ok" => ok,
            "offline" => went_offline,
            "endpoint" => target,
            "changed" => changed,
            "summary" => result.out,
            "notice" => result.notice,
            "cursor" => pos["cursor"].to_i,
            "pending" => pos["pending"].to_i,
            "bootstrap" => pos["bootstrap"] || "needed",
            "identity" => pos["identity"].to_s,
            "http_status" => last_http,
            "elapsed_ms" => elapsed_ms(started)
          }
          if went_offline
            payload["error"] = "Sync server unreachable (offline)"
          elsif http_err
            payload["error"] = "Sync server returned HTTP #{http_err}"
          end
          payload
        end
      end

      def list_models
        @mutex.synchronize { @replica.models }
      end

      def query_records(model:, where: {}, order: nil, limit: Replica::DEFAULT_LIMIT, offset: 0, columns: nil)
        @mutex.synchronize do
          @replica.query(model: model, where: where, order: order, limit: limit, offset: offset, columns: columns)
        end
      end

      def get_record(model:, id:)
        @mutex.synchronize { @replica.find(model: model, id: id) }
      end

      def search_records(query:, models: nil, columns: nil, limit: Replica::DEFAULT_LIMIT)
        @mutex.synchronize { @replica.search(query: query, models: models, columns: columns, limit: limit) }
      end

      def outbox(limit: 100)
        @mutex.synchronize { @replica.outbox(limit: limit) }
      end

      def render_screen(screen:, params: {})
        @mutex.synchronize do
          started = monotonic_now
          input = JSON.generate("screen" => screen.to_s, "params" => stringify_map(params))
          result = @host.call("render", input)
          {
            "screen" => screen.to_s,
            "params" => stringify_map(params),
            "tree" => JSON.parse(result.out),
            "elapsed_ms" => elapsed_ms(started)
          }
        end
      end

      def perform_action(screen:, action:, params: {}, args: {}, values: {}, render: false, sync: false)
        payload = @mutex.synchronize do
          started = monotonic_now
          str_params = stringify_map(params)
          str_args = stringify_map(args)
          str_values = stringify_map(values)
          input = JSON.generate(
            "screen" => screen.to_s,
            "params" => str_params,
            "action" => action.to_s,
            "args" => str_args,
            "values" => str_values
          )
          result = @host.call("action", input)
          errors = {}
          pending = after_write(errors, "pending") { pending_count }
          rendered =
            if render
              after_write(errors, "rendered") do
                parse_writable_json(@host.call("render", JSON.generate("screen" => screen.to_s, "params" => str_params)).out)
              end
            end

          {
            "ok" => true,
            "screen" => screen.to_s,
            "action" => action.to_s,
            "pending" => pending,
            "notice" => result.notice,
            "rendered" => rendered,
            "elapsed_ms" => elapsed_ms(started)
          }.merge(errors)
        end

        payload["sync"] = sync_after_write if sync
        payload
      end

      def app_request(method:, path:, params: nil, body: nil, headers: {}, content_type: nil, sync: false)
        payload = @mutex.synchronize do
          started = monotonic_now
          verb = method.to_s.upcase
          raise ArgumentError, "HTTP method is required" if verb.empty?

          request_path = path.to_s
          request_path = "/#{request_path}" unless request_path.start_with?("/")

          raw_body, resolved_content_type = encode_request_body(verb, params, body, content_type)
          if verb == "GET" && params.is_a?(Hash) && !params.empty?
            sep = request_path.include?("?") ? "&" : "?"
            request_path = "#{request_path}#{sep}#{encode_form_params(params)}"
          end

          raw_http = build_raw_http_request(verb, request_path, raw_body, resolved_content_type, headers)
          result = @host.call("request", raw_http)
          parsed = parse_raw_http_response(result.out)
          errors = {}
          pending = after_write(errors, "pending") { pending_count }

          parsed_json = nil
          if parsed[:headers]["content-type"].to_s.include?("json") && !parsed[:body].empty?
            parsed_json = parse_writable_json(parsed[:body]) rescue nil
          end

          {
            "ok" => parsed[:status] >= 200 && parsed[:status] < 400,
            "status" => parsed[:status],
            "headers" => parsed[:headers],
            "body" => parsed[:body],
            "json" => parsed_json,
            "pending" => pending,
            "notice" => result.notice,
            "elapsed_ms" => elapsed_ms(started)
          }.merge(errors)
        end

        payload["sync"] = sync_after_write if sync && payload["ok"]
        payload
      end

      def fetch_history(key:, query: nil, endpoint: nil)
        @mutex.synchronize do
          started = monotonic_now
          if query.nil? || query.to_s.strip.empty?
            result = @host.call("history", JSON.generate("key" => key.to_s))
            parsed = JSON.parse(result.out)
            return parsed.merge("key" => key.to_s, "elapsed_ms" => elapsed_ms(started))
          end

          target = normalize_endpoint(endpoint) || @endpoint
          raise ArgumentError, "No sync endpoint configured for history fetch." if target.nil?
          raise Error, "Client is in offline mode" if offline?

          # HTTP bodies come tagged as binary.
          raw_reply = @exchange.call("GET #{target}/records?#{query}\n").to_s.b
          status_line, body = raw_reply.split("\n", 2)
          status = status_line.to_i
          body = String.new(body.to_s, encoding: Encoding::UTF_8)
          error =
            if status == 0
              "History server unreachable (offline)"
            elsif status < 200 || status >= 300
              "History request returned HTTP #{status}"
            elsif !body.valid_encoding?
              "History response is not valid UTF-8"
            end
          if error
            return {
              "ok" => false,
              "key" => key.to_s,
              "offline" => status == 0,
              "http_status" => status,
              "error" => error,
              "elapsed_ms" => elapsed_ms(started)
            }
          end

          result = @host.call("history", JSON.generate("key" => key.to_s, "response" => body))
          parsed = JSON.parse(result.out)
          parsed.merge("key" => key.to_s, "http_status" => status, "elapsed_ms" => elapsed_ms(started))
        end
      end

      def open_database(path:, endpoint: nil)
        @mutex.synchronize do
          started = monotonic_now
          expanded = File.expand_path(path.to_s)
          @host.open(expanded)
          @database_path = expanded
          @endpoint = normalize_endpoint(endpoint) if endpoint
          @replica.reopen(expanded)
          pos = parse_cursor(@host.call("cursor", "").out)
          {
            "ok" => true,
            "database" => @database_path,
            "endpoint" => @endpoint,
            "cursor" => pos["cursor"].to_i,
            "pending" => pos["pending"].to_i,
            "bootstrap" => pos["bootstrap"] || "needed",
            "identity" => pos["identity"].to_s,
            "elapsed_ms" => elapsed_ms(started)
          }
        end
      end

      def close
        @mutex.synchronize do
          @replica.close
          @host.close
        end
      end

      private

      # The write is queued by now, so a failed sync must not hide its result:
      # the caller would write again. Rescued is what a sync may raise: no
      # endpoint, or a host or exchange that fails. Anything else is a bug and
      # escapes.
      def sync_after_write
        sync
      rescue MissingEndpoint, Error, SystemCallError, IOError => e
        { "ok" => false, "error" => e.message }
      end

      def after_write(errors, name)
        yield
      rescue Error, SystemCallError, IOError, JSON::JSONError => e
        errors["#{name}_error"] = String.new(e.message, encoding: Encoding::UTF_8).scrub
        nil
      end

      def pending_count
        parse_cursor(@host.call("cursor", "").out)["pending"]&.to_i
      end

      # Some JSON parses to values JSON cannot write (1e999, or "\udc00" in json
      # 2), or nests too deep to write inside an answer.
      def parse_writable_json(text)
        JSON.parse(text).tap { |value| JSON.generate([value]) }
      end

      def parse_cursor(raw)
        raw.to_s.split.each_with_object({}) do |pair, acc|
          key, value = pair.split("=", 2)
          acc[key] = value.to_s if key
        end
      end

      def stringify_map(hash)
        return {} unless hash.is_a?(Hash)

        hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v.to_s }
      end

      def normalize_endpoint(endpoint)
        str = endpoint.to_s.strip.sub(%r{/+\z}, "")
        str.empty? ? nil : str
      end

      def encode_request_body(verb, params, body, content_type)
        return ["", nil] if verb == "GET" || verb == "HEAD"

        if !body.nil?
          payload = body.is_a?(String) ? body : JSON.generate(body)
          ct = content_type || (body.is_a?(String) ? "application/x-www-form-urlencoded" : "application/json")
          return [payload, ct]
        end

        if params.is_a?(Hash) && !params.empty?
          if content_type.to_s.include?("json")
            [JSON.generate(params), content_type]
          else
            [encode_form_params(params), content_type || "application/x-www-form-urlencoded"]
          end
        else
          ["", content_type]
        end
      end

      # Nested Rails-style form encoding: { "issue" => { "title" => "Hi" } } -> "issue[title]=Hi"
      def encode_form_params(params, prefix = nil)
        pairs = []
        params.each do |key, value|
          full_key = prefix ? "#{prefix}[#{key}]" : key.to_s
          case value
          when Hash
            pairs << encode_form_params(value, full_key)
          when Array
            value.each { |item| pairs << "#{URI.encode_www_form_component("#{full_key}[]")}=#{URI.encode_www_form_component(item.to_s)}" }
          else
            pairs << "#{URI.encode_www_form_component(full_key)}=#{URI.encode_www_form_component(value.to_s)}"
          end
        end
        pairs.reject(&:empty?).join("&")
      end

      def build_raw_http_request(verb, path, body, content_type, headers)
        bytes = body.to_s.b
        lines = ["#{verb} #{path} HTTP/1.1", "Host: localhost"]
        custom = headers.is_a?(Hash) ? headers : {}
        custom.each do |key, value|
          next if key.to_s.casecmp?("host") || key.to_s.casecmp?("content-length")

          lines << "#{key}: #{value}"
        end
        if bytes.bytesize > 0
          unless custom.keys.any? { |k| k.to_s.casecmp?("content-type") }
            lines << "Content-Type: #{content_type || 'application/x-www-form-urlencoded'}"
          end
          lines << "Content-Length: #{bytes.bytesize}"
        end
        "#{lines.join("\r\n")}\r\n\r\n".b + bytes
      end

      def parse_raw_http_response(raw)
        head, body = raw.to_s.split("\n\n", 2)
        lines = head.to_s.split("\n")
        status = lines.first.to_i
        headers = {}
        Array(lines[1..]).each do |line|
          next unless line.include?(":")

          name, value = line.split(":", 2)
          headers[name.strip.downcase] = value.to_s.strip
        end
        { status: status, headers: headers, body: body.to_s }
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def elapsed_ms(started)
        ((monotonic_now - started) * 1000.0).round(3)
      end
    end
  end
end
