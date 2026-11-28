require "test_helper"
require "instant_record/mcp"
require "fileutils"
require "json"
require "sqlite3"
require "tmpdir"

class McpRuntimeTest < ActiveSupport::TestCase
  class FakeHost
    attr_reader :calls, :opened_paths, :closed

    def initialize(handlers = {})
      @handlers = handlers
      @calls = []
      @opened_paths = []
      @closed = false
    end

    def call(entry, input = "")
      @calls << [entry, input]
      handler = @handlers[entry]
      value = handler.respond_to?(:call) ? handler.call(input) : handler
      case value
      when InstantRecord::Mcp::HostProcess::Result
        value
      when Exception
        raise value
      else
        InstantRecord::Mcp::HostProcess::Result.new(out: value.to_s, notice: "")
      end
    end

    def open(path)
      @opened_paths << path
    end

    def close
      @closed = true
    end
  end

  class MinimalExchange
    attr_reader :requests

    def initialize(replies = "200\n{}")
      @replies = replies.is_a?(Array) ? replies.dup : nil
      @default_reply = replies
      @requests = []
    end

    def call(raw_request)
      @requests << raw_request
      @replies ? @replies.shift : @default_reply
    end
  end

  setup do
    @dir = Dir.mktmpdir
    @db_path = File.join(@dir, "replica.sqlite3")
    @runtimes = []
    create_sqlite_db(@db_path)
  end

  teardown do
    @runtimes.each(&:close)
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  test "sync raises MissingEndpoint when no endpoint is configured" do
    runtime, = build_runtime(endpoint: nil)

    error = assert_raises(InstantRecord::Mcp::Runtime::MissingEndpoint) { runtime.sync }
    assert_kind_of ArgumentError, error
    assert_equal "No sync endpoint configured. Pass endpoint or set INSTANT_RECORD_ENDPOINT.", error.message
  end

  test "sync in offline mode reports offline status without invoking host sync" do
    runtime, host = build_runtime(endpoint: "http://sync.test///", offline: true)

    result = runtime.sync
    assert_equal false, result["ok"]
    assert_equal true, result["offline"]
    assert_equal "http://sync.test", result["endpoint"]
    assert_equal "Client is in offline mode", result["error"]
    assert_equal 3, result["cursor"]
    assert_equal 1, result["pending"]
    assert_equal "ready", result["bootstrap"]
    assert_equal "user-1", result["identity"]
    assert_kind_of Float, result["elapsed_ms"]
    assert_equal [["cursor", ""]], host.calls
  end

  test "sync reports success, endpoint override, offline exchange failure, and HTTP error status" do
    exchange = InstantRecord::Mcp::HttpExchange.new(adapter: ->(*) { [200, "{}"] })
    runtime, host = build_runtime(
      endpoint: "http://default.test",
      exchange: exchange,
      handlers: {
        "sync" => lambda do |target|
          exchange.call("GET #{target}/bootstrap\n")
          InstantRecord::Mcp::HostProcess::Result.new(out: "changed pending=0", notice: "records_changed")
        end
      }
    )

    ok_result = runtime.sync(endpoint: "http://override.test/")
    assert_equal true, ok_result["ok"]
    assert_equal false, ok_result["offline"]
    assert_equal "http://override.test", ok_result["endpoint"]
    assert_equal true, ok_result["changed"]
    assert_equal "changed pending=0", ok_result["summary"]
    assert_equal "records_changed", ok_result["notice"]
    assert_equal 200, ok_result["http_status"]
    refute ok_result.key?("error")
    assert_kind_of Float, ok_result["elapsed_ms"]
    assert_equal ["sync", "http://override.test"], host.calls.first

    offline_exchange = InstantRecord::Mcp::HttpExchange.new(adapter: ->(*) { raise Errno::ECONNREFUSED })
    offline_runtime, = build_runtime(
      endpoint: "http://sync.test",
      exchange: offline_exchange,
      handlers: {
        "sync" => lambda do |target|
          offline_exchange.call("GET #{target}/bootstrap\n")
          "unchanged"
        end
      }
    )
    unreachable = offline_runtime.sync
    assert_equal false, unreachable["ok"]
    assert_equal true, unreachable["offline"]
    assert_equal false, unreachable["changed"]
    assert_equal 0, unreachable["http_status"]
    assert_equal "Sync server unreachable (offline)", unreachable["error"]
    assert_kind_of Float, unreachable["elapsed_ms"]

    error_exchange = InstantRecord::Mcp::HttpExchange.new(adapter: ->(*) { [503, "down"] })
    error_runtime, = build_runtime(
      endpoint: "http://sync.test",
      exchange: error_exchange,
      handlers: {
        "sync" => lambda do |target|
          error_exchange.call("GET #{target}/bootstrap\n")
          "unchanged"
        end
      }
    )
    http_err = error_runtime.sync
    assert_equal false, http_err["ok"]
    assert_equal false, http_err["offline"]
    assert_equal 503, http_err["http_status"]
    assert_equal "Sync server returned HTTP 503", http_err["error"]
    assert_kind_of Float, http_err["elapsed_ms"]
  end

  test "sync tolerates a minimal exchange object without trace or offline methods" do
    runtime, = build_runtime(
      endpoint: "http://sync.test",
      exchange: MinimalExchange.new,
      handlers: { "sync" => "unchanged" }
    )

    result = runtime.sync
    assert_equal true, result["ok"]
    assert_equal false, result["offline"]
    assert_equal false, result["changed"]
    assert_nil result["http_status"]
    refute result.key?("error")
    assert_kind_of Float, result["elapsed_ms"]
  end

  test "render_screen stringifies params and returns parsed tree with elapsed_ms" do
    runtime, host = build_runtime(
      handlers: { "render" => JSON.generate("kind" => "screen", "items" => []) }
    )

    result = runtime.render_screen(screen: :issues, params: { page: 2, filter: :open })
    assert_equal "issues", result["screen"]
    assert_equal({ "page" => "2", "filter" => "open" }, result["params"])
    assert_equal({ "kind" => "screen", "items" => [] }, result["tree"])
    assert_kind_of Float, result["elapsed_ms"]
    assert_equal JSON.generate("screen" => "issues", "params" => { "page" => "2", "filter" => "open" }), host.calls.first.last
  end

  test "perform_action with sync runs sync after releasing mutex and attaches sync payload" do
    exchange = InstantRecord::Mcp::HttpExchange.new(adapter: ->(*) { [200, "{}"] })
    runtime, = build_runtime(
      endpoint: "http://sync.test",
      exchange: exchange,
      handlers: {
        "action" => InstantRecord::Mcp::HostProcess::Result.new(out: "", notice: "records_changed"),
        "sync" => lambda do |target|
          exchange.call("GET #{target}/bootstrap\n")
          "changed pending=0"
        end
      }
    )

    result = runtime.perform_action(screen: "issues", action: "close", args: { id: 1 }, sync: true)
    assert_equal true, result["ok"]
    assert_equal 1, result["pending"]
    assert_equal "records_changed", result["notice"]
    assert_kind_of Float, result["elapsed_ms"]
    assert_equal true, result.dig("sync", "ok")
    assert_equal 200, result.dig("sync", "http_status")
    assert_kind_of Float, result.dig("sync", "elapsed_ms")
  end

  test "app_request validates method, normalizes paths, encodes GET query params, and omits GET/HEAD bodies" do
    runtime, host = build_runtime(
      handlers: { "request" => "200\nContent-Type: application/json\n\n{\"ok\":true}" }
    )

    err = assert_raises(ArgumentError) { runtime.app_request(method: "", path: "/issues") }
    assert_equal "HTTP method is required", err.message

    get_result = runtime.app_request(
      method: "get",
      path: "issues?existing=1",
      params: { issue: { title: "Hi" }, tags: %w[a b] }
    )
    assert_equal true, get_result["ok"]
    assert_equal({ "ok" => true }, get_result["json"])
    assert_kind_of Float, get_result["elapsed_ms"]

    raw_get = host.calls.first.last
    assert_includes raw_get, "GET /issues?existing=1&issue%5Btitle%5D=Hi&tags%5B%5D=a&tags%5B%5D=b HTTP/1.1\r\n"
    refute_includes raw_get, "Content-Type:"
    refute_includes raw_get, "Content-Length:"

    runtime.app_request(method: "HEAD", path: "/issues", params: { a: 1 }, body: "ignored")
    raw_head = host.calls[2].last
    assert_includes raw_head, "HEAD /issues HTTP/1.1\r\n"
    assert raw_head.end_with?("\r\n\r\n")
  end

  test "app_request encodes bodies and headers and runs sync only on ok responses" do
    exchange = InstantRecord::Mcp::HttpExchange.new(adapter: ->(*) { [200, "{}"] })
    responses = [
      "201\nContent-Type: application/json\n\n{\"id\":1}",
      "422\nContent-Type: application/json\n\nnot-json",
      "200\nContent-Type: text/plain\n\nok"
    ]
    runtime, host = build_runtime(
      endpoint: "http://sync.test",
      exchange: exchange,
      handlers: {
        "request" => ->(_) { responses.shift },
        "sync" => lambda do |target|
          exchange.call("GET #{target}/bootstrap\n")
          "changed"
        end
      }
    )

    created = runtime.app_request(
      method: "POST",
      path: "/issues",
      body: { title: "New" },
      headers: { "Host" => "evil.test", "Content-Length" => "999", "X-Custom" => "yes" },
      sync: true
    )
    assert_equal true, created["ok"]
    assert_equal 201, created["status"]
    assert_equal({ "id" => 1 }, created["json"])
    assert_equal true, created.dig("sync", "ok")
    raw_created = host.calls.first.last
    assert_includes raw_created, "Host: localhost\r\n"
    refute_includes raw_created, "evil.test"
    assert_includes raw_created, "X-Custom: yes\r\n"
    assert_includes raw_created, "Content-Type: application/json\r\n"
    assert_includes raw_created, "Content-Length: 15\r\n"
    assert raw_created.end_with?("\r\n\r\n{\"title\":\"New\"}")

    failed = runtime.app_request(
      method: "POST",
      path: "/issues",
      params: { title: "Bad" },
      content_type: "application/json",
      sync: true
    )
    assert_equal false, failed["ok"]
    assert_equal 422, failed["status"]
    assert_nil failed["json"]
    refute failed.key?("sync")

    custom_ct = runtime.app_request(
      method: "POST",
      path: "/issues",
      body: "a=1",
      headers: { "content-type" => "text/plain" }
    )
    assert_equal true, custom_ct["ok"]
    assert_nil custom_ct["json"]
    raw_custom = host.calls.reverse.find { |entry, _| entry == "request" }.last
    assert_equal 1, raw_custom.scan(/content-type:/i).size
    assert_includes raw_custom, "content-type: text/plain\r\n"
  end

  test "fetch_history inspects local marks without endpoint or network and reports remote errors" do
    local_runtime, host = build_runtime(
      endpoint: nil,
      offline: true,
      handlers: { "history" => JSON.generate("ok" => true, "applied" => 0, "has_more" => true) }
    )

    inspected = local_runtime.fetch_history(key: "older", query: "   ")
    assert_equal true, inspected["ok"]
    assert_equal "older", inspected["key"]
    assert_equal true, inspected["has_more"]
    assert_kind_of Float, inspected["elapsed_ms"]
    assert_equal [["history", JSON.generate("key" => "older")]], host.calls

    err = assert_raises(ArgumentError) { local_runtime.fetch_history(key: "older", query: "type=Issue") }
    assert_equal "No sync endpoint configured for history fetch.", err.message

    offline_runtime, = build_runtime(endpoint: "http://sync.test", offline: true)
    offline_err = assert_raises(InstantRecord::Mcp::Error) { offline_runtime.fetch_history(key: "older", query: "type=Issue") }
    assert_equal "Client is in offline mode", offline_err.message

    exchange = MinimalExchange.new([
      "0\n",
      "502\nBad Gateway",
      "302\nMoved",
      "200\n{\"records\":[]}"
    ])
    remote_runtime, = build_runtime(
      endpoint: "http://default.test",
      exchange: exchange,
      handlers: { "history" => JSON.generate("ok" => true, "applied" => 0, "has_more" => false) }
    )

    unreachable = remote_runtime.fetch_history(key: "older", query: "type=Issue")
    assert_equal [false, "older", true, 0, "History server unreachable (offline)"],
      unreachable.values_at("ok", "key", "offline", "http_status", "error")
    assert_kind_of Float, unreachable["elapsed_ms"]

    bad_gateway = remote_runtime.fetch_history(key: "older", query: "type=Issue")
    assert_equal [false, "older", false, 502, "History request returned HTTP 502"],
      bad_gateway.values_at("ok", "key", "offline", "http_status", "error")
    assert_kind_of Float, bad_gateway["elapsed_ms"]

    redirect = remote_runtime.fetch_history(key: "older", query: "type=Issue")
    assert_equal [false, "older", false, 302, "History request returned HTTP 302"],
      redirect.values_at("ok", "key", "offline", "http_status", "error")

    ok = remote_runtime.fetch_history(key: "older", query: "type=Issue", endpoint: "http://override.test/")
    assert_equal [true, "older", 200], ok.values_at("ok", "key", "http_status")
    assert_kind_of Float, ok["elapsed_ms"]
    assert_equal "GET http://override.test/records?type=Issue\n", exchange.requests.last
  end

  test "open_database switches path, preserves or updates endpoint, and returns cursor position" do
    second_db = File.join(@dir, "second.sqlite3")
    create_sqlite_db(second_db)
    runtime, host = build_runtime(endpoint: "http://initial.test")

    same_ep = runtime.open_database(path: second_db)
    assert_equal true, same_ep["ok"]
    assert_equal second_db, same_ep["database"]
    assert_equal "http://initial.test", same_ep["endpoint"]
    assert_equal 3, same_ep["cursor"]
    assert_kind_of Float, same_ep["elapsed_ms"]
    assert_equal [second_db], host.opened_paths

    updated_ep = runtime.open_database(path: @db_path, endpoint: "http://next.test/")
    assert_equal @db_path, updated_ep["database"]
    assert_equal "http://next.test", updated_ep["endpoint"]
    assert_equal "http://next.test", runtime.endpoint
  end

  private

  def build_runtime(endpoint: "http://sync.test", offline: false, exchange: nil, handlers: {})
    default_handlers = {
      "cursor" => "cursor=3 pending=1 bootstrap=ready identity=user-1"
    }.merge(handlers)
    host = FakeHost.new(default_handlers)
    runtime = InstantRecord::Mcp::Runtime.new(
      database_path: @db_path,
      endpoint: endpoint,
      offline: offline,
      exchange: exchange,
      host_process: host,
      screens: ["issues"]
    )
    @runtimes << runtime
    [runtime, host]
  end

  def create_sqlite_db(path)
    db = SQLite3::Database.new(path)
    db.execute_batch(<<~SQL)
      CREATE TABLE IF NOT EXISTS instant_record_sync_metadata (key TEXT PRIMARY KEY, value TEXT);
      CREATE TABLE IF NOT EXISTS instant_record_outbox (
        id TEXT PRIMARY KEY, record_type TEXT, record_id TEXT, operation TEXT,
        changes_payload TEXT, base_version INTEGER DEFAULT 0, created_at TEXT, updated_at TEXT
      );
    SQL
    db.close
  end
end
