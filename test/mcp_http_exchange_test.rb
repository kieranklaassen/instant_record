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

    thread = Thread.new do
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
      socket.close
    end

    exchange = InstantRecord::Mcp::HttpExchange.new(
      token: "loopback-token",
      cookie: "sid=abc",
      scope: "maya"
    )
    reply = exchange.call("POST http://127.0.0.1:#{port}/instant_record/mutations\n{\"mutations\":[]}")
    thread.join(2)
    server.close

    assert_equal "200\n{\"results\":[]}", reply
    assert_equal "POST /instant_record/mutations?scope=maya HTTP/1.1", received.first[:line]
    assert_equal "Bearer loopback-token", received.first[:headers]["authorization"]
    assert_equal "sid=abc", received.first[:headers]["cookie"]
    assert_equal "application/json", received.first[:headers]["content-type"]
    assert_equal '{"mutations":[]}', received.first[:body]
  end
end
