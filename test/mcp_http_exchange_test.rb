require "test_helper"
require "instant_record/mcp"
require "socket"

class McpHttpExchangeTest < ActiveSupport::TestCase
  test "attaches Bearer token, Cookie, custom headers, JSON Content-Type, and scope query param" do
    captured = []
    adapter = lambda do |verb, uri, headers, body|
      captured << { verb: verb, uri: uri.to_s, headers: headers, body: body }
      [200, '{"cursor":4,"records":[]}', { "Set-Cookie" => ["_session=fresh123; Path=/; HttpOnly"] }]
    end

    exchange = InstantRecord::Mcp::HttpExchange.new(
      token: "secret-tok",
      cookie: "pref=dark",
      headers: { "X-Client" => "local-mcp" },
      scope: "visitor-42",
      adapter: adapter
    )

    reply = exchange.call("GET http://127.0.0.1:3000/instant_record/bootstrap\n")
    assert_equal "200\n{\"cursor\":4,\"records\":[]}", reply
    assert_equal "GET", captured[0][:verb]
    assert_equal "http://127.0.0.1:3000/instant_record/bootstrap?scope=visitor-42", captured[0][:uri]
    assert_equal "Bearer secret-tok", captured[0][:headers]["Authorization"]
    assert_equal "pref=dark", captured[0][:headers]["Cookie"]
    assert_equal "local-mcp", captured[0][:headers]["X-Client"]
    assert_nil captured[0][:headers]["Content-Type"]

    # Subsequent POST includes merged Set-Cookie, JSON Content-Type, and preserves existing query params.
    post_reply = exchange.call("POST http://127.0.0.1:3000/instant_record/mutations?existing=1\n{\"mutations\":[]}")
    assert_equal "200\n{\"cursor\":4,\"records\":[]}", post_reply
    assert_equal "POST", captured[1][:verb]
    assert_equal "http://127.0.0.1:3000/instant_record/mutations?existing=1&scope=visitor-42", captured[1][:uri]
    assert_equal "application/json", captured[1][:headers]["Content-Type"]
    assert_equal "pref=dark; _session=fresh123", captured[1][:headers]["Cookie"]
    assert_equal '{"mutations":[]}', captured[1][:body]
  end

  test "does not duplicate scope query param when already present in URL" do
    seen_uri = nil
    exchange = InstantRecord::Mcp::HttpExchange.new(
      scope: "visitor-42",
      adapter: lambda do |_verb, uri, _headers, _body|
        seen_uri = uri.to_s
        [200, "ok"]
      end
    )

    exchange.call("GET http://127.0.0.1:3000/instant_record/events?after=0&scope=explicit\n")
    assert_equal "http://127.0.0.1:3000/instant_record/events?after=0&scope=explicit", seen_uri
  end

  test "offline mode returns 0 without touching the adapter and records offline trace" do
    called = false
    exchange = InstantRecord::Mcp::HttpExchange.new(
      offline: true,
      adapter: lambda { |*| called = true; [200, "ok"] }
    )

    assert_equal "0\n", exchange.call("GET http://127.0.0.1:3000/instant_record/bootstrap\n")
    refute called
    assert exchange.any_offline?
  end

  test "tracks HTTP error statuses and network failures cleanly" do
    exchange = InstantRecord::Mcp::HttpExchange.new(
      adapter: ->(*) { [401, "Unauthorized"] }
    )
    assert_equal "401\nUnauthorized", exchange.call("GET http://127.0.0.1:3000/instant_record/bootstrap\n")
    assert_equal 401, exchange.last_error_status
    refute exchange.any_offline?

    failing = InstantRecord::Mcp::HttpExchange.new(
      adapter: ->(*) { raise Errno::ECONNREFUSED, "refused" }
    )
    assert_equal "0\n", failing.call("GET http://127.0.0.1:3000/instant_record/bootstrap\n")
    assert failing.any_offline?
  end

  test "an answer that is not HTTP, does not unpack, or a refusing proxy is offline" do
    errors = [
      Net::HTTPBadResponse.new("wrong status line"),
      Net::HTTPHeaderSyntaxError.new("wrong header"),
      Net::HTTPClientException.new("403 Forbidden", nil),
      Net::HTTPFatalError.new("502 Bad Gateway", nil),
      Zlib::DataError.new("incorrect header check")
    ]
    errors.each do |error|
      exchange = InstantRecord::Mcp::HttpExchange.new(adapter: ->(*) { raise error })
      assert_equal "0\n", exchange.call("GET http://example.test/bootstrap\n"), error.class.name
      assert_equal error.message, exchange.trace.last[:error]
    end
  end

  test "performs real loopback Net::HTTP GET and POST requests with auth headers" do
    received = []
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = nil
    reply = nil

    begin
      thread = Thread.new do
        socket = nil
        begin
          socket = server.accept
          request_line = socket.gets
          headers = {}
          while (line = socket.gets) && line != "\r\n"
            k, v = line.split(":", 2)
            headers[k.downcase] = v.strip
          end
          body = headers["content-length"] ? socket.read(headers["content-length"].to_i) : ""
          received << { line: request_line.strip, headers: headers, body: body }

          resp_body = '{"results":[]}'
          socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{resp_body.bytesize}\r\nConnection: close\r\n\r\n#{resp_body}")
        rescue IOError
          # Listener closed before a client connected.
        ensure
          socket&.close unless socket&.closed?
        end
      end

      exchange = InstantRecord::Mcp::HttpExchange.new(
        token: "loopback-token",
        cookie: "sid=abc",
        scope: "maya"
      )
      reply = exchange.call("POST http://127.0.0.1:#{port}/instant_record/mutations\n{\"mutations\":[]}")
    ensure
      server.close unless server.closed?
      if thread
        thread.join(2)
        thread.kill if thread.alive?
      end
    end

    assert_equal "200\n{\"results\":[]}", reply
    assert_equal "POST /instant_record/mutations?scope=maya HTTP/1.1", received.first[:line]
    assert_equal "Bearer loopback-token", received.first[:headers]["authorization"]
    assert_equal "sid=abc", received.first[:headers]["cookie"]
    assert_equal "application/json", received.first[:headers]["content-type"]
    assert_equal '{"mutations":[]}', received.first[:body]
  end

  test "deletes cookies on Max-Age=0 and negative Max-Age, strips whitespace, and ignores empty names or non-Hash headers" do
    responses = [
      [200, "ok", { "Set-Cookie" => [" sid = fresh \r; Path=/; Max-Age=3600", "keep=1; X-Max-Age=0", "  =ignored; Path=/"] }],
      [200, "ok", { "set-cookie" => "sid=bye; Path=/; Max-Age=0\r\nkeep=gone; Max-Age=-1\r\n" }],
      [200, "ok", "not-a-hash"],
      [200, "ok", nil]
    ]
    exchange = InstantRecord::Mcp::HttpExchange.new(
      cookie: "pref=dark; sid=old",
      adapter: ->(*) { responses.shift }
    )

    exchange.call("GET http://example.test/one\n")
    assert_equal "pref=dark; sid=fresh; keep=1", exchange.current_cookie_header

    exchange.call("GET http://example.test/two\n")
    assert_equal "pref=dark", exchange.current_cookie_header

    assert_equal "200\nok", exchange.call("GET http://example.test/three\n")
    assert_equal "200\nok", exchange.call("GET http://example.test/four\n")
    assert_equal "pref=dark", exchange.current_cookie_header
  end

  test "respects persist_cookies: false by ignoring Set-Cookie headers" do
    captured_cookies = []
    exchange = InstantRecord::Mcp::HttpExchange.new(
      cookie: "initial=1",
      persist_cookies: false,
      adapter: lambda do |_verb, _uri, headers, _body|
        captured_cookies << headers["Cookie"]
        [200, "ok", { "Set-Cookie" => ["_session=new; Path=/", "initial=gone; Max-Age=0"] }]
      end
    )

    exchange.call("GET http://example.test/one\n")
    exchange.call("GET http://example.test/two\n")

    assert_equal ["initial=1", "initial=1"], captured_cookies
    assert_equal "initial=1", exchange.current_cookie_header
  end

  test "caller custom headers override auto-injected Authorization, Cookie, and Content-Type case-insensitively" do
    captured = []
    exchange = InstantRecord::Mcp::HttpExchange.new(
      token: "auto-token",
      cookie: "auto=1",
      headers: {
        "authorization" => "Token custom-auth",
        "COOKIE" => "custom=2",
        "content-type" => "text/plain"
      },
      adapter: lambda do |verb, _uri, headers, _body|
        captured << { verb: verb, headers: headers }
        [200, "ok"]
      end
    )

    exchange.call("POST http://example.test/mutations\nhello")
    exchange.call("HEAD http://example.test/ping\n")

    assert_equal "Token custom-auth", captured[0][:headers]["authorization"]
    assert_nil captured[0][:headers]["Authorization"]
    assert_equal "custom=2", captured[0][:headers]["COOKIE"]
    assert_nil captured[0][:headers]["Cookie"]
    assert_equal "text/plain", captured[0][:headers]["content-type"]
    assert_nil captured[0][:headers]["Content-Type"]

    head_exchange = InstantRecord::Mcp::HttpExchange.new(
      adapter: lambda do |_verb, _uri, headers, _body|
        captured << { headers: headers }
        [200, ""]
      end
    )
    head_exchange.call("HEAD http://example.test/ping\n")
    assert_nil captured.last[:headers]["Content-Type"]
  end

  test "handles CRLF request framing and normalizes lowercase verbs consistently" do
    captured = []
    exchange = InstantRecord::Mcp::HttpExchange.new(
      adapter: lambda do |verb, uri, headers, body|
        captured << { verb: verb, uri: uri.to_s, headers: headers, body: body }
        [200, "ok"]
      end
    )

    assert_equal "200\nok", exchange.call("get http://example.test/bootstrap\r\n")
    assert_equal "200\nok", exchange.call("post http://example.test/mutations\r\n{\"a\":1}")

    assert_equal "GET", captured[0][:verb]
    assert_equal "http://example.test/bootstrap", captured[0][:uri]
    assert_nil captured[0][:headers]["Content-Type"]
    assert_equal "POST", captured[1][:verb]
    assert_equal "http://example.test/mutations", captured[1][:uri]
    assert_equal "application/json", captured[1][:headers]["Content-Type"]
    assert_equal '{"a":1}', captured[1][:body]
    assert_equal %w[GET POST], exchange.trace.map { |entry| entry[:method] }
  end

  test "rejects non-HTTP(S) schemes, hostless URLs, and malformed percent-encoded query strings as offline" do
    called = false
    exchange = InstantRecord::Mcp::HttpExchange.new(
      scope: "visitor-42",
      adapter: lambda { |*| called = true; [200, "ok"] }
    )

    [
      "GET file:///etc/passwd\n",
      "GET ftp://example.test/data\n",
      "GET /relative/path\n",
      "GET http:///missing-host\n",
      "GET http://example.test/bootstrap?bad=%ZZ\n",
      "   \r\n"
    ].each do |raw_request|
      assert_equal "0\n", exchange.call(raw_request), raw_request.inspect
    end

    refute called
    assert_equal 6, exchange.trace.length
    assert exchange.trace.all? { |entry| entry[:status] == 0 && !entry[:error].to_s.empty? }
  end

  test "records unsupported HTTP verbs as offline for both adapter and Net::HTTP paths" do
    adapter_called = false
    with_adapter = InstantRecord::Mcp::HttpExchange.new(
      adapter: lambda { |*| adapter_called = true; [200, "ok"] }
    )
    assert_equal "0\n", with_adapter.call("BREW http://example.test/coffee\n")
    refute adapter_called
    assert_equal({ method: "BREW", url: "http://example.test/coffee", status: 0, error: "unsupported HTTP verb: BREW" }, with_adapter.trace.last)

    without_adapter = InstantRecord::Mcp::HttpExchange.new
    assert_equal "0\n", without_adapter.call("options http://127.0.0.1:1/bootstrap\n")
    assert_equal({ method: "OPTIONS", url: "http://127.0.0.1:1/bootstrap", status: 0, error: "unsupported HTTP verb: OPTIONS" }, without_adapter.trace.last)
  end

  test "guards invalid or non-positive timeout values with DEFAULT_TIMEOUT" do
    default = InstantRecord::Mcp::HttpExchange::DEFAULT_TIMEOUT.to_f
    [nil, 0, -5, "0", "-1.5", "not-a-number", Float::NAN, Float::INFINITY, -Float::INFINITY].each do |bad_timeout|
      exchange = InstantRecord::Mcp::HttpExchange.new(timeout: bad_timeout)
      assert_equal default, exchange.timeout, bad_timeout.inspect
    end

    assert_equal 2.5, InstantRecord::Mcp::HttpExchange.new(timeout: "2.5").timeout
    assert_equal 3.0, InstantRecord::Mcp::HttpExchange.new(timeout: 3).timeout
  end

  test "tracks last_status, last_error_status, any_offline?, and resets trace cleanly" do
    responses = [
      [200, "ok"],
      [422, "invalid"],
      [503, "down"],
      [204, ""]
    ]
    exchange = InstantRecord::Mcp::HttpExchange.new(adapter: ->(*) { responses.shift })

    assert_nil exchange.last_status
    assert_nil exchange.last_error_status
    refute exchange.any_offline?

    exchange.call("GET http://example.test/1\n")
    assert_equal 200, exchange.last_status
    assert_nil exchange.last_error_status

    exchange.call("POST http://example.test/2\n{}")
    assert_equal 422, exchange.last_status
    assert_equal 422, exchange.last_error_status

    exchange.call("POST http://example.test/3\n{}")
    assert_equal 503, exchange.last_status
    assert_equal 503, exchange.last_error_status

    exchange.call("DELETE http://example.test/4\n")
    assert_equal 204, exchange.last_status
    assert_equal 503, exchange.last_error_status

    exchange.call("BREW http://example.test/5\n")
    assert_equal 0, exchange.last_status
    assert_equal 503, exchange.last_error_status
    assert exchange.any_offline?

    exchange.reset_trace!
    assert_empty exchange.trace
    assert_nil exchange.last_status
    assert_nil exchange.last_error_status
    refute exchange.any_offline?
  end

  test "accepts string-formatted adapter return values" do
    exchange = InstantRecord::Mcp::HttpExchange.new(
      adapter: ->(_verb, _uri, _headers, _body) { "201\n{\"created\":true}" }
    )

    reply = exchange.call("POST http://example.test/items\n{\"name\":\"a\"}")
    assert_equal "201\n{\"created\":true}", reply
    assert_equal 201, exchange.last_status
    assert_nil exchange.last_error_status
  end
end
