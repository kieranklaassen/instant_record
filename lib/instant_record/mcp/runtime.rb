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
        timed_synchronize do
          position = replica_position
          models_summary = @replica.models["models"]
          {
            "database" => @database_path,
            "endpoint" => @endpoint,
            "offline" => offline?,
            **position,
            "screens" => @screens,
            "models" => models_summary
          }
        end
      end

      def sync(endpoint: nil)
        timed_synchronize do
          target = resolve_endpoint(endpoint)
          raise MissingEndpoint, "No sync endpoint configured. Pass endpoint or set INSTANT_RECORD_ENDPOINT." if target.nil?

          if offline?
            offline_sync_payload(target)
          else
            perform_sync(target)
          end
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
        timed_synchronize do
          screen_name = screen.to_s
          str_params = stringify_map(params)
          result = @host.call("render", JSON.generate("screen" => screen_name, "params" => str_params))
          {
            "screen" => screen_name,
            "params" => str_params,
            "tree" => JSON.parse(result.out)
          }
        end
      end

      def perform_action(screen:, action:, params: {}, args: {}, values: {}, render: false, sync: false)
        payload = timed_synchronize do
          screen_name = screen.to_s
          action_name = action.to_s
          str_params = stringify_map(params)
          input = JSON.generate(
            "screen" => screen_name,
            "params" => str_params,
            "action" => action_name,
            "args" => stringify_map(args),
            "values" => stringify_map(values)
          )
          result = @host.call("action", input)
          errors = {}
          pending = after_write(errors, "pending") { pending_count }
          rendered = render ? render_after_action(errors, screen_name, str_params) : nil

          {
            "ok" => true,
            "screen" => screen_name,
            "action" => action_name,
            "pending" => pending,
            "notice" => result.notice,
            "rendered" => rendered,
            **errors
          }
        end

        payload["sync"] = sync_after_write if sync
        payload
      end

      def app_request(method:, path:, params: nil, body: nil, headers: {}, content_type: nil, sync: false)
        payload = timed_synchronize do
          raw_http = prepare_app_request(method, path, params, body, headers, content_type)
          result = @host.call("request", raw_http)
          parsed = parse_raw_http_response(result.out)
          errors = {}
          pending = after_write(errors, "pending") { pending_count }

          {
            "ok" => parsed[:status] >= 200 && parsed[:status] < 400,
            "status" => parsed[:status],
            "headers" => parsed[:headers],
            "body" => parsed[:body],
            "json" => decode_response_json(parsed),
            "pending" => pending,
            "notice" => result.notice,
            **errors
          }
        end

        payload["sync"] = sync_after_write if sync && payload["ok"]
        payload
      end

      def fetch_history(key:, query: nil, endpoint: nil)
        timed_synchronize do
          history_key = key.to_s
          if query.nil? || query.to_s.strip.empty?
            inspect_history(history_key)
          else
            fetch_remote_history(history_key, query, endpoint)
          end
        end
      end

      def open_database(path:, endpoint: nil)
        timed_synchronize do
          expanded = File.expand_path(path.to_s)
          @host.open(expanded)
          @database_path = expanded
          @endpoint = normalize_endpoint(endpoint) if endpoint
          @replica.reopen(expanded)
          {
            "ok" => true,
            "database" => @database_path,
            "endpoint" => @endpoint,
            **replica_position
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

      def timed_synchronize
        @mutex.synchronize do
          started = monotonic_now
          payload = yield
          payload["elapsed_ms"] = elapsed_ms(started)
          payload
        end
      end

      def offline_sync_payload(target)
        {
          "ok" => false,
          "offline" => true,
          "endpoint" => target,
          "error" => "Client is in offline mode",
          **replica_position
        }
      end

      def perform_sync(target)
        @exchange.reset_trace! if @exchange.respond_to?(:reset_trace!)
        result = @host.call("sync", target)
        position = replica_position
        @replica.refresh_schema!

        outcome = sync_exchange_outcome
        payload = {
          "ok" => outcome[:ok],
          "offline" => outcome[:offline],
          "endpoint" => target,
          "changed" => result.out.start_with?("changed"),
          "summary" => result.out,
          "notice" => result.notice,
          **position,
          "http_status" => outcome[:http_status]
        }
        payload["error"] = outcome[:error] if outcome[:error]
        payload
      end

      def sync_exchange_outcome
        went_offline = @exchange.respond_to?(:any_offline?) && @exchange.any_offline?
        http_err = @exchange.respond_to?(:last_error_status) ? @exchange.last_error_status : nil
        last_http = @exchange.respond_to?(:last_status) ? @exchange.last_status : nil
        error =
          if went_offline
            "Sync server unreachable (offline)"
          elsif http_err
            "Sync server returned HTTP #{http_err}"
          end

        {
          ok: !went_offline && http_err.nil?,
          offline: went_offline,
          http_status: last_http,
          error: error
        }
      end

      def render_after_action(errors, screen_name, str_params)
        after_write(errors, "rendered") do
          parse_writable_json(@host.call("render", JSON.generate("screen" => screen_name, "params" => str_params)).out)
        end
      end

      def prepare_app_request(method, path, params, body, headers, content_type)
        verb = method.to_s.upcase
        raise ArgumentError, "HTTP method is required" if verb.empty?

        raw_body, resolved_content_type = encode_request_body(verb, params, body, content_type)
        request_path = normalize_request_path(path, verb, params)
        build_raw_http_request(verb, request_path, raw_body, resolved_content_type, headers)
      end

      def normalize_request_path(path, verb, params)
        request_path = path.to_s
        request_path = "/#{request_path}" unless request_path.start_with?("/")
        return request_path unless verb == "GET" && params.is_a?(Hash) && !params.empty?

        sep = request_path.include?("?") ? "&" : "?"
        "#{request_path}#{sep}#{encode_form_params(params)}"
      end

      def decode_response_json(parsed)
        return nil unless parsed[:headers]["content-type"].to_s.include?("json") && !parsed[:body].empty?

        parse_writable_json(parsed[:body])
      rescue StandardError
        nil
      end

      def inspect_history(history_key)
        result = @host.call("history", JSON.generate("key" => history_key))
        JSON.parse(result.out).merge("key" => history_key)
      end

      def fetch_remote_history(history_key, query, endpoint)
        target = resolve_endpoint(endpoint)
        raise ArgumentError, "No sync endpoint configured for history fetch." if target.nil?
        raise Error, "Client is in offline mode" if offline?

        status, body, error = decode_history_response(@exchange.call("GET #{target}/records?#{query}\n"))
        if error
          return {
            "ok" => false,
            "key" => history_key,
            "offline" => status == 0,
            "http_status" => status,
            "error" => error
          }
        end

        result = @host.call("history", JSON.generate("key" => history_key, "response" => body))
        JSON.parse(result.out).merge("key" => history_key, "http_status" => status)
      end

      def decode_history_response(raw_reply)
        # HTTP bodies come tagged as binary.
        status_line, raw_body = raw_reply.to_s.b.split("\n", 2)
        status = status_line.to_i
        body = String.new(raw_body.to_s, encoding: Encoding::UTF_8)
        [status, body, history_response_error(status, body)]
      end

      def history_response_error(status, body)
        if status == 0
          "History server unreachable (offline)"
        elsif status < 200 || status >= 300
          "History request returned HTTP #{status}"
        elsif !body.valid_encoding?
          "History response is not valid UTF-8"
        end
      end

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

      def replica_position
        pos = parse_cursor(@host.call("cursor", "").out)
        {
          "cursor" => pos["cursor"].to_i,
          "pending" => pos["pending"].to_i,
          "bootstrap" => pos["bootstrap"] || "needed",
          "identity" => pos["identity"].to_s
        }
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

      def resolve_endpoint(endpoint)
        normalize_endpoint(endpoint) || @endpoint
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
