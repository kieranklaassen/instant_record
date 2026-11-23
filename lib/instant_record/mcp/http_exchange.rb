require "net/http"
require "openssl"
require "uri"

module InstantRecord
  module Mcp
    # Answers the compiled native host's `exchange` requests ("METHOD URL\nBODY")
    # over HTTP/HTTPS (or an injected Rack/test adapter) with configurable
    # token, cookie/session, custom header, and scope-parameter auth.
    #
    # Returns "STATUS\nBODY" on HTTP responses, or "0\n" on network failures or
    # offline mode — matching compiled/pipeline/native/instant_record_native.h.
    class HttpExchange
      OFFLINE_REPLY = "0\n".freeze
      DEFAULT_TIMEOUT = 10

      attr_reader :token, :cookie, :headers, :scope, :timeout, :trace
      attr_accessor :offline

      def initialize(
        token: nil,
        cookie: nil,
        headers: {},
        scope: nil,
        offline: false,
        timeout: DEFAULT_TIMEOUT,
        persist_cookies: true,
        adapter: nil
      )
        @token = blank_to_nil(token)
        @cookie = blank_to_nil(cookie)
        @headers = normalize_headers(headers)
        @scope = blank_to_nil(scope)
        @offline = !!offline
        @timeout = (timeout || DEFAULT_TIMEOUT).to_f
        @persist_cookies = !!persist_cookies
        @adapter = adapter
        @cookie_jar = parse_cookie_header(@cookie)
        @trace = []
      end

      def offline?
        @offline
      end

      def reset_trace!
        @trace = []
      end

      def any_offline?
        @trace.any? { |entry| entry[:status] == 0 }
      end

      def last_error_status
        @trace.reverse_each.find { |entry| entry[:status] && entry[:status] >= 400 }&.dig(:status)
      end

      def last_status
        @trace.last&.dig(:status)
      end

      def call(raw_request)
        return record_offline(nil, nil, "offline mode") if offline?

        head, body = raw_request.to_s.split("\n", 2)
        verb, raw_url = head.to_s.split(" ", 2)
        return record_offline(verb, raw_url, "invalid exchange request") if verb.nil? || raw_url.nil? || raw_url.empty?

        uri = prepare_uri(raw_url)
        return record_offline(verb, raw_url, "invalid URL") unless uri && uri.scheme

        req_headers = build_headers(verb, body.to_s)
        status, response_body, response_headers =
          if @adapter
            perform_adapter(verb, uri, req_headers, body.to_s)
          else
            perform_http(verb, uri, req_headers, body.to_s)
          end

        absorb_cookies(response_headers) if @persist_cookies && response_headers
        @trace << { method: verb, url: uri.to_s, status: status.to_i, error: nil }
        "#{status.to_i}\n#{response_body}"
      rescue URI::InvalidURIError, SocketError, SystemCallError, Timeout::Error,
             IOError, EOFError, OpenSSL::SSL::SSLError, Net::HTTPError => e
        record_offline(verb, raw_url, e.message)
      end

      # Expose effective Cookie header (initial cookie merged with any Set-Cookie).
      def current_cookie_header
        return nil if @cookie_jar.empty?

        @cookie_jar.map { |name, value| "#{name}=#{value}" }.join("; ")
      end

      private

      def prepare_uri(raw_url)
        uri = URI.parse(raw_url.to_s.strip)
        return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

        if @scope
          params = URI.decode_www_form(uri.query.to_s)
          unless params.any? { |key, _| key == "scope" }
            params << ["scope", @scope]
            uri.query = URI.encode_www_form(params)
          end
        end
        uri
      end

      def build_headers(verb, _body)
        built = {}
        @headers.each { |key, value| built[key] = value }

        if @token && !header_present?(built, "authorization")
          built["Authorization"] = "Bearer #{@token}"
        end

        cookie_str = current_cookie_header
        if cookie_str && !header_present?(built, "cookie")
          built["Cookie"] = cookie_str
        end

        if verb.upcase != "GET" && verb.upcase != "HEAD" && !header_present?(built, "content-type")
          built["Content-Type"] = "application/json"
        end

        built
      end

      def perform_adapter(verb, uri, req_headers, body)
        result = @adapter.call(verb.upcase, uri, req_headers, body)
        if result.is_a?(String)
          status_line, res_body = result.split("\n", 2)
          [status_line.to_i, res_body.to_s, nil]
        else
          status, res_body, res_headers = result
          [status.to_i, res_body.to_s, res_headers]
        end
      end

      def perform_http(verb, uri, req_headers, body)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @timeout
        http.read_timeout = @timeout

        request_class =
          case verb.upcase
          when "GET" then Net::HTTP::Get
          when "POST" then Net::HTTP::Post
          when "PUT" then Net::HTTP::Put
          when "PATCH" then Net::HTTP::Patch
          when "DELETE" then Net::HTTP::Delete
          when "HEAD" then Net::HTTP::Head
          else raise ArgumentError, "Unsupported HTTP verb: #{verb}"
          end

        req = request_class.new(uri.request_uri)
        req_headers.each { |key, value| req[key] = value }
        req.body = body unless verb.upcase == "GET" || verb.upcase == "HEAD"

        res = http.request(req)
        set_cookies = res.get_fields("set-cookie")
        [res.code.to_i, res.body.to_s, set_cookies ? { "set-cookie" => set_cookies } : nil]
      end

      def absorb_cookies(response_headers)
        raw = response_headers.each_with_object([]) do |(key, value), acc|
          next unless key.to_s.casecmp?("set-cookie")

          Array(value).each do |entry|
            entry.to_s.split("\n").each { |line| acc << line }
          end
        end

        raw.each do |line|
          pair, attrs = line.split(";", 2)
          pair = pair.to_s.strip
          next unless pair.include?("=")

          name, value = pair.split("=", 2)
          next if name.empty?

          if attrs.to_s.match?(/\bmax-age\s*=\s*0\b/i)
            @cookie_jar.delete(name)
          else
            @cookie_jar[name] = value
          end
        end
      end

      def parse_cookie_header(header)
        jar = {}
        return jar if header.nil? || header.empty?

        header.split(";").each do |segment|
          pair = segment.strip
          next unless pair.include?("=")

          name, value = pair.split("=", 2)
          jar[name.strip] = value.to_s.strip unless name.strip.empty?
        end
        jar
      end

      def normalize_headers(headers)
        return {} unless headers.is_a?(Hash)

        headers.each_with_object({}) do |(key, value), acc|
          name = key.to_s.strip
          next if name.empty? || value.nil?

          acc[name] = value.to_s
        end
      end

      def header_present?(hash, downcased_name)
        hash.keys.any? { |key| key.to_s.downcase == downcased_name }
      end

      def blank_to_nil(value)
        str = value.to_s.strip
        str.empty? ? nil : str
      end

      def record_offline(verb, url, error)
        @trace << { method: verb, url: url, status: 0, error: error }
        OFFLINE_REPLY
      end
    end
  end
end
