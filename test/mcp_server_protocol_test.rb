require "test_helper"
require "instant_record/mcp"
require "json"
require "open3"
require "stringio"

# Pins what the MCP server writes, and what it asks of the runtime, message by
# message.
class McpServerProtocolTest < ActiveSupport::TestCase
  # Answers every runtime call with a canned value (or raises it) and records
  # the call.
  class RecordingRuntime
    METHODS = %i[
      status sync list_models query_records get_record search_records outbox
      render_screen perform_action app_request fetch_history
    ].freeze

    attr_reader :calls

    def initialize(answer = { "answer" => 1 })
      @answer = answer
      @calls = []
    end

    METHODS.each do |name|
      define_method(name) do |**options|
        @calls << [name, options]
        raise @answer if @answer.is_a?(Exception)

        @answer
      end
    end
  end

  setup do
    @runtime = RecordingRuntime.new
    @err = StringIO.new
  end

  test "tools/list writes the same definitions, in the same key order" do
    tools = JSON.parse(File.read(File.expand_path("fixtures/mcp_tools.json", __dir__)))

    assert_equal [%({"jsonrpc":"2.0","id":1,"result":{"tools":#{JSON.generate(tools)}}})], exchange(request("tools/list"))
    assert_empty @runtime.calls
  end

  test "each tool calls the runtime with its required arguments and the defaults" do
    {
      ["status", {}] => [:status, {}],
      ["sync", {}] => [:sync, { endpoint: nil }],
      ["models", {}] => [:list_models, {}],
      ["query", { model: "Issue" }] => [:query_records, { model: "Issue", where: {}, order: nil, limit: 50, offset: 0, columns: nil }],
      ["get", { model: "Issue", id: "i-1" }] => [:get_record, { model: "Issue", id: "i-1" }],
      ["search", { query: "ship" }] => [:search_records, { query: "ship", models: nil, columns: nil, limit: 50 }],
      ["outbox", {}] => [:outbox, { limit: 100 }],
      ["render_screen", { screen: "issues" }] => [:render_screen, { screen: "issues", params: {} }],
      ["action", { screen: "issues", action: "close" }] =>
        [:perform_action, { screen: "issues", action: "close", params: {}, args: {}, values: {}, render: false, sync: false }],
      ["request", { method: "GET", path: "/" }] =>
        [:app_request, { method: "GET", path: "/", params: nil, body: nil, headers: {}, content_type: nil, sync: false }],
      ["history", { key: "older" }] => [:fetch_history, { key: "older", query: nil, endpoint: nil }]
    }.each { |(tool, arguments), call| assert_tool_call call, tool, arguments }
  end

  test "each tool passes every argument on as it came, right type or not, and ignores extra ones" do
    {
      ["status", {}] => [:status, {}],
      ["sync", { endpoint: 1 }] => [:sync, { endpoint: 1 }],
      ["models", {}] => [:list_models, {}],
      ["query", { model: 1, where: "w", order: ["a"], limit: "9", offset: "2", columns: "c" }] =>
        [:query_records, { model: 1, where: "w", order: ["a"], limit: "9", offset: "2", columns: "c" }],
      ["get", { model: nil, id: 7 }] => [:get_record, { model: nil, id: 7 }],
      ["search", { query: ["q"], models: "m", columns: 3, limit: 0 }] =>
        [:search_records, { query: ["q"], models: "m", columns: 3, limit: 0 }],
      ["outbox", { limit: "x" }] => [:outbox, { limit: "x" }],
      ["render_screen", { screen: nil, params: [1] }] => [:render_screen, { screen: nil, params: [1] }],
      ["action", { screen: 1, action: 2, params: "p", args: "a", values: "v", render: "no", sync: 0 }] =>
        [:perform_action, { screen: 1, action: 2, params: "p", args: "a", values: "v", render: true, sync: true }],
      ["request", { method: nil, path: 2, params: "p", body: 3, content_type: 4, headers: "h", sync: 1 }] =>
        [:app_request, { method: nil, path: 2, params: "p", body: 3, headers: "h", content_type: 4, sync: true }],
      ["history", { key: 1, query: 2, endpoint: 3 }] => [:fetch_history, { key: 1, query: 2, endpoint: 3 }]
    }.each { |(tool, arguments), call| assert_tool_call call, tool, arguments.merge(extra: true) }
  end

  test "a missing required argument is a tool error naming the first one missing" do
    {
      ["query", {}] => "model",
      ["get", {}] => "model",
      ["get", { model: "Issue" }] => "id",
      ["get", { id: "i-1" }] => "model",
      ["search", {}] => "query",
      ["render_screen", {}] => "screen",
      ["action", {}] => "screen",
      ["action", { screen: "issues" }] => "action",
      ["action", { action: "close" }] => "screen",
      ["request", {}] => "method",
      ["request", { method: "GET" }] => "path",
      ["request", { path: "/" }] => "method",
      ["history", {}] => "key"
    }.each do |(tool, arguments), missing|
      assert_equal [tool_error("Missing required argument: #{missing}")], exchange(tool_request(tool, arguments)), tool
    end
    assert_empty @runtime.calls
    assert_empty @err.string
  end

  test "unknown tools and arguments that are not an object are tool errors" do
    assert_equal [tool_error("Unknown tool: instant_record_nope")], exchange(tool_request("nope", {}))
    assert_equal [tool_error("Unknown tool: ")], exchange(request("tools/call"))
    assert_equal [tool_error("Unknown tool: 7")], exchange(request("tools/call", params: { name: 7 }))
    [[], "text", 1, true].each do |arguments|
      assert_equal [tool_error("Tool arguments must be an object")], exchange(tool_request("status", arguments))
    end
    assert_empty @runtime.calls

    exchange(tool_request("status", nil), tool_request("status", false))
    assert_equal [[:status, {}], [:status, {}]], @runtime.calls
  end

  test "only an answer whose ok is false is marked as an error" do
    { { "ok" => false } => true, { "ok" => nil } => false, { "ok" => true } => false, {} => false, [] => false, nil => false }.each do |answer, is_error|
      @runtime = RecordingRuntime.new(answer)
      expected = { content: [{ type: "text", text: JSON.generate(answer) }], isError: is_error }

      assert_equal [result(expected)], exchange(tool_request("status", {}))
    end
  end

  test "runtime errors from a tool" do
    [ArgumentError, InstantRecord::Mcp::Error, InstantRecord::Mcp::HostError].each do |error|
      @runtime = RecordingRuntime.new(error.new("boom"))
      assert_equal [tool_error("boom")], exchange(tool_request("status", {}))
    end
    assert_empty @err.string

    @runtime = RecordingRuntime.new(RuntimeError.new("boom"))
    assert_equal [error(-32603, "boom")], exchange(tool_request("status", {}))
    assert_equal "[instant_record:mcp] RuntimeError: boom\n", @err.string
  end

  test "resources/list writes the fixed resources and one for each model" do
    @runtime = RecordingRuntime.new({ "models" => [{ "name" => "Issue", "count" => 3 }] })
    resources = [
      ["status", "Replica Status", "Current sync cursor, pending outbox count, identity, and local SQLite replica metadata."],
      ["models", "Synced Models", "Schema and row counts for every synced model in the local SQLite replica."],
      ["outbox", "Pending Outbox Mutations", "Queued offline mutations waiting to sync to the Rails server."],
      ["models/Issue", "Issue Records", "Recent records of Issue (3 local rows)."]
    ].map { |path, name, description| { uri: "instant-record://#{path}", name: name, description: description, mimeType: "application/json" } }

    assert_equal [result(resources: resources)], exchange(request("resources/list"))
    assert_equal [[:list_models, {}]], @runtime.calls
  end

  test "resources/read reads each resource" do
    {
      "status" => [:status, {}],
      "models" => [:list_models, {}],
      "outbox" => [:outbox, {}],
      "models/Issue" => [:query_records, { model: "Issue" }],
      "models/a/b?c" => [:query_records, { model: "a/b?c" }]
    }.each do |path, call|
      @runtime = RecordingRuntime.new
      uri = "instant-record://#{path}"
      contents = [{ uri: uri, mimeType: "application/json", text: '{"answer":1}' }]

      assert_equal [result(contents: contents)], exchange(request("resources/read", params: { uri: uri }))
      assert_equal [call], @runtime.calls
    end
  end

  test "resources/read rejects a missing or unknown uri" do
    [{}, { uri: nil }, { uri: "" }].each do |params|
      assert_equal [error(-32602, "Missing required param: uri")], exchange(request("resources/read", params: params))
    end
    ["other://status", "instant-record://models/", "instant-record://models/a\nb", "x instant-record://models/a", 5].each do |uri|
      assert_equal [error(-32602, "Unknown resource URI: #{uri}")], exchange(request("resources/read", params: { uri: uri }))
    end
    assert_empty @runtime.calls
  end

  test "runtime errors from a resource" do
    @runtime = RecordingRuntime.new(ArgumentError.new("boom"))
    assert_equal [error(-32602, "boom")] * 2,
      exchange(request("resources/list"), request("resources/read", params: { uri: "instant-record://status" }))
    assert_empty @err.string

    @runtime = RecordingRuntime.new(InstantRecord::Mcp::Error.new("boom"))
    assert_equal [error(-32603, "boom")] * 2,
      exchange(request("resources/list"), request("resources/read", params: { uri: "instant-record://status" }))
    assert_equal "[instant_record:mcp] InstantRecord::Mcp::Error: boom\n" * 2, @err.string
  end

  test "params that are not an object" do
    assert_equal [error(-32603, "no implicit conversion of String into Integer")] * 3,
      %w[initialize tools/call resources/read].flat_map { |method| exchange(request(method, params: [])) }
    assert_equal [tool_error("Unknown tool: ")], exchange(request("tools/call", params: "text"))
  end

  test "initialize negotiates the protocol version" do
    { "2025-06-18" => "2025-06-18", "2025-03-26" => "2025-03-26", "2024-11-05" => "2024-11-05", "1999-01-01" => "2024-11-05", nil => "2024-11-05" }.each do |asked, answered|
      expected = { protocolVersion: answered, capabilities: { tools: {}, resources: {} }, serverInfo: { name: "instant_record", version: InstantRecord::VERSION } }
      assert_equal [result(expected)], exchange(request("initialize", params: { protocolVersion: asked }))
    end
  end

  test "unknown methods are errors unless they are notifications" do
    assert_equal [error(-32601, "Method not found: nope")], exchange(request("nope"))
    assert_equal [error(-32601, "Method not found: nope").sub('"id":1', '"id":null')], exchange(request("nope").merge(id: nil))
    assert_empty exchange(notification("nope"))
  end

  test "notifications are silent when they fail and answered with a null id when a method answers" do
    %w[notifications/initialized notifications/cancelled initialized].each do |method|
      assert_empty exchange(notification(method), request(method))
    end
    assert_empty exchange(notification("resources/read"))
    assert_empty @err.string

    assert_empty exchange(notification("resources/read").merge(params: []))
    assert_equal "[instant_record:mcp] TypeError: no implicit conversion of String into Integer\n", @err.string

    assert_equal ['{"jsonrpc":"2.0","id":null,"result":{}}'], exchange(notification("ping"))
    assert_equal [tool_error("Unknown tool: ").sub('"id":1', '"id":null')], exchange(notification("tools/call"))
  end

  test "invalid requests, batches included, are rejected with the id they carry" do
    message = "Invalid JSON-RPC 2.0 request"
    [[], [request("ping")], "text", 1, nil, {}, request("ping").except(:id).merge(jsonrpc: "1.0")].each do |invalid|
      assert_equal [error(-32600, message).sub('"id":1', '"id":null')], exchange(invalid)
    end
    [{ id: 1 }, request("ping").merge(jsonrpc: "1.0"), request("ping").merge(method: 1)].each do |invalid|
      assert_equal [error(-32600, message)], exchange(invalid)
    end
  end

  test "malformed JSON is a parse error, blank lines are skipped, and the next line is still read" do
    parse_error, pong = exchange_lines("{not json\n\n   \n  #{JSON.generate(request('ping'))}  \n")

    assert parse_error.start_with?('{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error: '), parse_error
    assert_equal result({}), pong
  end

  test "each line is read as UTF-8 and answered in UTF-8, whatever the locale" do
    message = JSON.generate(jsonrpc: "2.0", id: "é✓", method: "nopé")
    answer = JSON.generate(jsonrpc: "2.0", id: "é✓", error: { code: -32601, message: "Method not found: nopé" })

    [[{ "LC_ALL" => "C" }, []], [{}, %w[-E ISO-8859-1:UTF-8]], [{}, %w[-E UTF-8:ISO-8859-1]]].each do |env, flags|
      script = <<~'RUBY'
        require "instant_record/mcp"
        runtime = Object.new
        def runtime.status = raise("bad \u2713")
        InstantRecord::Mcp::Server.new(runtime).run
      RUBY
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), *flags, "-e", script,
        stdin_data: "\xFF\n#{message}\n#{JSON.generate(tool_request('status', {}))}\n", binmode: true)

      assert status.success?, "#{env} #{flags}: #{err}"
      lines = out.force_encoding(Encoding::UTF_8).lines(chomp: true)
      assert_equal [parse_error("invalid UTF-8"), answer, error(-32603, "bad ✓")], lines, "#{env} #{flags}"
      assert_equal "[instant_record:mcp] RuntimeError: bad ✓\n".b, err
    end
  end

  test "the streams keep their encodings once the server is done" do
    input, client = IO.pipe
    reader, output = IO.pipe
    client.close
    input.set_encoding("ISO-8859-1", "UTF-8")
    output.set_encoding(nil)
    before = [input, output].map { |io| [io.external_encoding, io.internal_encoding] }
    InstantRecord::Mcp::Server.new(@runtime, input: input, output: output, err: nil).run
    assert_equal before, [input, output].map { |io| [io.external_encoding, io.internal_encoding] }
  ensure
    [input, client, reader, output].each { |io| io&.close }
  end

  test "a line that is not valid UTF-8 is a parse error, and the next line is still read" do
    ping = JSON.generate(request("ping"))
    ["\xFF\n", "  \xC3\n", %({"jsonrpc":"2.0","id":1,"method":"\xE9"}\n)].each do |line|
      assert_equal [parse_error("invalid UTF-8"), result({})], exchange_lines("#{line}#{ping}\n")
    end
  end

  test "an error that is not valid UTF-8, or an id JSON cannot write, does not stop the server" do
    @runtime = RecordingRuntime.new(RuntimeError.new("bad \xFF".b))
    assert_equal [error(-32603, "bad \u{FFFD}"), result({})], exchange(tool_request("status", {}), request("ping"))

    # Some json versions refuse the nested id when they read it.
    { "1e999" => [-32603], "#{'[' * 100}#{']' * 100}" => [-32603, -32700] }.each do |id, codes|
      failed, pong = exchange_lines(%({"jsonrpc":"2.0","id":#{id},"method":"ping"}\n#{JSON.generate(request('ping'))}\n))
      assert_nil JSON.parse(failed)["id"]
      assert_includes codes, JSON.parse(failed).dig("error", "code")
      assert_equal result({}), pong
    end
  end

  private

  def parse_error(reason) = error(-32700, "Parse error: #{reason}").sub('"id":1', '"id":null')

  def request(method, params: nil)
    { jsonrpc: "2.0", id: 1, method: method, params: params }.compact
  end

  def notification(method) = { jsonrpc: "2.0", method: method }

  def tool_request(tool, arguments)
    request("tools/call", params: { name: "instant_record_#{tool}", arguments: arguments })
  end

  def exchange(*messages) = exchange_lines(messages.map { |message| "#{JSON.generate(message)}\n" }.join)

  def exchange_lines(input)
    output = StringIO.new
    InstantRecord::Mcp::Server.new(@runtime, input: StringIO.new(input), output: output, err: @err).run
    output.string.lines(chomp: true)
  end

  def result(payload) = JSON.generate(jsonrpc: "2.0", id: 1, result: payload)

  def error(code, message) = JSON.generate(jsonrpc: "2.0", id: 1, error: { code: code, message: message })

  def tool_error(message)
    result(content: [{ type: "text", text: JSON.generate(ok: false, error: message) }], isError: true)
  end

  def assert_tool_call(call, tool, arguments)
    @runtime = RecordingRuntime.new
    expected = result(content: [{ type: "text", text: '{"answer":1}' }], isError: false)

    assert_equal [expected], exchange(tool_request(tool, arguments)), tool
    assert_equal [call], @runtime.calls
  end
end
