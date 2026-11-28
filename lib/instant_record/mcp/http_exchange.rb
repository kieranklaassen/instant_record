require "net/http"
require "openssl"
require "uri"
require "zlib"

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
      HTTP_REQUEST_CLASSES = {
        "GET" => Net::HTTP::Get,
        "POST" => Net::HTTP::Post,
        "PUT" => Net::HTTP::Put,
        "PATCH" => Net::HTTP::Patch,
        "DELETE" => Net::HTTP::Delete,
        "HEAD" => Net::HTTP::Head
      }.freeze
      BODYLESS_VERBS = %w[GET HEAD].freeze

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
        @timeout = normalize_timeout(timeout)
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
        raw_verb, raw_url = head.to_s.chomp("\r").strip.split(" ", 2)
        verb = raw_verb&.upcase
        return record_offline(verb, raw_url, "invalid exchange request") if verb.nil? || raw_url.nil? || raw_url.empty?
        return record_offline(verb, raw_url, "unsupported HTTP verb: #{verb}") unless HTTP_REQUEST_CLASSES.key?(verb)

        uri = prepare_uri(raw_url)
        return record_offline(verb, raw_url, "invalid URL") unless uri

        body_str = body.to_s
        req_headers = build_headers(verb)
        status, response_body, response_headers =
          if @adapter
            perform_adapter(verb, uri, req_headers, body_str)
          else
            perform_http(verb, uri, req_headers, body_str)
          end

        absorb_cookies(response_headers) if @persist_cookies && response_headers
        @trace << { method: verb, url: uri.to_s, status: status.to_i, error: nil }
        "#{status.to_i}\n#{response_body}"
      rescue URI::InvalidURIError, SocketError, SystemCallError, Timeout::Error,
             IOError, EOFError, OpenSSL::SSL::SSLError, Net::HTTPError,
             Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Zlib::Error => e
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
        return nil unless (uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)) && uri.host && !uri.host.empty?

        if @scope
          params =
            begin
              URI.decode_www_form(uri.query.to_s)
            rescue ArgumentError => e
              raise URI::InvalidURIError, e.message
            end
          unless params.any? { |key, _| key == "scope" }
            params << ["scope", @scope]
            uri.query = URI.encode_www_form(params)
          end
        end
        uri
      end

      def build_headers(verb)
        built = @headers.dup

        if @token && !header_present?(built, "authorization")
          built["Authorization"] = "Bearer #{@token}"
        end

        cookie_str = current_cookie_header
        if cookie_str && !header_present?(built, "cookie")
          built["Cookie"] = cookie_str
        end

        if !BODYLESS_VERBS.include?(verb) && !header_present?(built, "content-type")
          built["Content-Type"] = "application/json"
        end

        built
      end

      def perform_adapter(verb, uri, req_headers, body)
        result = @adapter.call(verb, uri, req_headers, body)
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

        request_class = HTTP_REQUEST_CLASSES.fetch(verb)
        req = request_class.new(uri.request_uri)
        req_headers.each { |key, value| req[key] = value }
        req.body = body unless BODYLESS_VERBS.include?(verb)

        res = http.request(req)
        set_cookies = res.get_fields("set-cookie")
        [res.code.to_i, res.body.to_s, set_cookies ? { "set-cookie" => set_cookies } : nil]
      end

      def absorb_cookies(response_headers)
        return unless response_headers.is_a?(Hash)

        response_headers.each do |key, value|
          next unless key.to_s.casecmp?("set-cookie")

          Array(value).each do |entry|
            entry.to_s.split(/\r?\n/).each do |line|
              pair, attrs = line.split(";", 2)
              pair = pair.to_s.strip
              next unless pair.include?("=")

              name, cookie_value = pair.split("=", 2)
              name = name.strip
              next if name.empty?

              if cookie_expired?(attrs)
                @cookie_jar.delete(name)
              else
                @cookie_jar[name] = cookie_value.to_s.strip
              end
            end
          end
        end
      end

      def cookie_expired?(attrs)
        return false if attrs.nil? || attrs.empty?

        max_age = nil
        attrs.split(";").each do |attr|
          attr_name, attr_value = attr.split("=", 2)
          next unless attr_name && attr_name.strip.casecmp?("max-age") && attr_value

          val = attr_value.strip
          max_age = val.to_i if val.match?(/\A-?\d+\z/)
        end
        !max_age.nil? && max_age <= 0
      end

      def parse_cookie_header(header)
        jar = {}
        return jar if header.nil? || header.empty?

        header.split(";").each do |segment|
          pair = segment.strip
          next unless pair.include?("=")

          name, value = pair.split("=", 2)
          name = name.strip
          next if name.empty?

          jar[name] = value.to_s.strip
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

      def normalize_timeout(value)
        parsed = Float(value)
        parsed.finite? && parsed.positive? ? parsed : DEFAULT_TIMEOUT.to_f
      rescue ArgumentError, TypeError
        DEFAULT_TIMEOUT.to_f
      end

      def header_present?(hash, name)
        hash.each_key.any? { |key| key.to_s.casecmp?(name) }
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
