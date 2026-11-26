require "test_helper"
require "instant_record/mcp"
require "json"
require "stringio"
require "tmpdir"

class McpCliTest < ActiveSupport::TestCase
  class FakeRuntime
    attr_reader :calls

    def initialize(results = {})
      @results = results
      @calls = []
    end

    %i[
      sync status list_models query_records get_record search_records outbox
      render_screen perform_action app_request fetch_history close
    ].each do |name|
      define_method(name) do |**options|
        keys = InstantRecord::Mcp::Runtime.instance_method(name).parameters
        required = keys.filter_map { |kind, key| key if kind == :keyreq }
        raise "#{name} does not take #{options.keys}" unless (options.keys - keys.map(&:last)).empty? && (required - options.keys).empty?

        @calls << [name, options]
        result = @results.fetch(name, { "ok" => true })
        result.is_a?(Exception) ? raise(result) : result
      end
    end
  end

  Run = Struct.new(:code, :out, :err, :options, :calls)

  # Arguments => the one call the runtime gets.
  {
    %w[status] => [:status, {}],
    %w[status extra] => [:status, {}],
    %w[models] => [:list_models, {}],
    %w[sync] => [:sync, { endpoint: nil }],
    %w[sync http://e/ir extra] => [:sync, { endpoint: "http://e/ir" }],
    %w[query Issue] => [:query_records, { model: "Issue", where: {}, order: nil, columns: nil, limit: 50, offset: 0 }],
    ["query", "-w", "state=open", "Issue", "--where", "title=a=b", "--where-json", '{"state":"done","n":1}',
     "--order", "created_at desc", "--columns", "id, title ,x", "--limit", "3", "--offset", "4", "extra"] =>
      [:query_records, { model: "Issue", where: { "state" => "done", "title" => "a=b", "n" => 1 },
                         order: "created_at desc", columns: %w[id title x], limit: 3, offset: 4 }],
    ["query", "Issue", "--where-json", '{"a":1}', "-w", "a=", "--columns", "", "--limit", "0x10", "--limit", "0"] =>
      [:query_records, { model: "Issue", where: { "a" => "" }, order: nil, columns: [], limit: 0, offset: 0 }],
    %w[get Issue i-1 extra] => [:get_record, { model: "Issue", id: "i-1" }],
    ["search", " two ", "words "] => [:search_records, { query: "two  words", models: nil, columns: nil, limit: 50 }],
    ["search", "x", "-m", "Issue", "--model", "Task", "--columns", "title, body", "--limit", "2"] =>
      [:search_records, { query: "x", models: %w[Issue Task], columns: %w[title body], limit: 2 }],
    %w[outbox] => [:outbox, { limit: 100 }],
    %w[outbox --limit 7] => [:outbox, { limit: 7 }],
    %w[render issues] => [:render_screen, { screen: "issues", params: {} }],
    %w[render issues -p a=1 --param b=2 -p a=3] => [:render_screen, { screen: "issues", params: { "a" => "3", "b" => "2" } }],
    %w[action issues close] =>
      [:perform_action, { screen: "issues", action: "close", params: {}, args: {}, values: {}, render: false, sync: false }],
    %w[action issues close -p a=1 --param b=2 -a c=3 --arg d=4 -v e=5 --value f=6 --render --sync] =>
      [:perform_action, { screen: "issues", action: "close", params: { "a" => "1", "b" => "2" },
                          args: { "c" => "3", "d" => "4" }, values: { "e" => "5", "f" => "6" }, render: true, sync: true }],
    %w[request GET /issues] =>
      [:app_request, { method: "GET", path: "/issues", body: nil, content_type: nil, headers: {}, sync: false }],
    ["request", "POST", "/issues", "-d", "a=1", "--content-type", "text/plain", "-H", " X-A : b:c ", "--header", "X-D:", "--sync"] =>
      [:app_request, { method: "POST", path: "/issues", body: "a=1", content_type: "text/plain",
                       headers: { "X-A" => "b:c", "X-D" => "" }, sync: true }],
    ["request", "POST", "/issues", "--data", "a=1", "--content-type", "text/plain", "--json", '{ "a": [1, 2] }'] =>
      [:app_request, { method: "POST", path: "/issues", body: '{"a":[1,2]}', content_type: "application/json", headers: {}, sync: false }],
    ["request", "POST", "/issues", "--json", "{}", "--data", "raw", "--content-type", "text/plain"] =>
      [:app_request, { method: "POST", path: "/issues", body: "raw", content_type: "text/plain", headers: {}, sync: false }],
    %w[history older:issues] => [:fetch_history, { key: "older:issues", query: nil }],
    %w[history older:issues --query type=Issue] => [:fetch_history, { key: "older:issues", query: "type=Issue" }]
  }.each do |argv, call|
    test "#{argv.inspect} calls #{call.first}" do
      run = cli(argv)
      assert_equal [0, %({"ok":true}\n), ""], [run.code, run.out, run.err]
      assert_equal [call, [:close, {}]], run.calls
    end
  end

  # Usage errors: the runtime is already there, and is closed.
  {
    %w[query] => "Usage: query <Model> [options]",
    %w[query --limit 1] => "Usage: query <Model> [options]",
    %w[get] => "Usage: get <Model> <id>",
    %w[get Issue] => "Usage: get <Model> <id>",
    %w[search] => "Usage: search <query> [options]",
    ["search", " "] => "Usage: search <query> [options]",
    %w[render] => "Usage: render <screen> [--param k=v]",
    %w[action] => "Usage: action <screen> <action> [--param k=v] [--arg k=v] [--value k=v]",
    %w[action issues] => "Usage: action <screen> <action> [--param k=v] [--arg k=v] [--value k=v]",
    %w[request] => "Usage: request <METHOD> <path> [--data ...]",
    %w[request GET] => "Usage: request <METHOD> <path> [--data ...]",
    %w[history] => "Usage: history <key> [--query ...]"
  }.each do |argv, message|
    test "#{argv.inspect} is a usage error after the initial sync" do
      run = cli(["--sync-on-start", *argv])
      assert_equal [2, ""], [run.code, run.out]
      assert_equal "[instant_record:mcp] initial sync: \nError: #{message}\n", run.err
      assert_equal [[:sync, {}], [:close, {}]], run.calls
    end
  end

  # Option errors come before the runtime, and before missing arguments.
  {
    %w[query --limit x] => "invalid argument: --limit x",
    %w[query --offset 1.5] => "invalid argument: --offset 1.5",
    %w[query --where nope] => 'Expected KEY=VALUE, got "nope"',
    %w[query -w =v] => 'Expected KEY=VALUE, got "=v"',
    %w[query --order] => "missing argument: --order",
    %w[search --limit x] => "invalid argument: --limit x",
    %w[outbox --limit x] => "invalid argument: --limit x",
    %w[render -p nope] => 'Expected KEY=VALUE, got "nope"',
    %w[action -p nope] => 'Expected KEY=VALUE, got "nope"',
    %w[action --arg nope] => 'Expected KEY=VALUE, got "nope"',
    %w[action --value nope] => 'Expected KEY=VALUE, got "nope"',
    %w[request -H nope] => "Header must be 'Name: Value'",
    %w[request -H] => "missing argument: -H",
    %w[history --query] => "missing argument: --query",
    %w[status --limit 1] => "invalid option: --limit",
    %w[status --help --limit 1] => "invalid option: --limit",
    %w[--bogus status] => "invalid option: --bogus",
    %w[--help --bogus] => "invalid option: --bogus",
    %w[--header nope status] => "Header must be 'Name: Value'",
    %w[--timeout x status] => "invalid argument: --timeout x",
    %w[--limit 1 query] => "invalid option: --limit"
  }.each do |argv, message|
    test "#{argv.inspect} is an option error without a runtime" do
      run = cli(argv)
      assert_equal [2, "", "Error: #{message}\n", nil], [run.code, run.out, run.err, run.options]
    end
  end

  test "an abbreviation that fits two options is refused" do
    run = cli(%w[query --o x Issue])
    assert_equal [2, "Error: ambiguous option: --o\n", nil], [run.code, run.err, run.options]
  end

  test "JSON options that do not parse are option errors without a runtime" do
    { "--where-json" => %w[query Issue], "--json" => %w[request POST /issues] }.each do |option, command|
      ["{", "", "{\n\"a\":\nx}", "#{'[' * 200}#{']' * 200}"].each do |json|
        run = cli([*command, option, json])
        assert_equal [2, "", "Error: Expected valid JSON for #{option}\n", nil], [run.code, run.out, run.err, run.options], json
      end
    end

    run = cli(%w[request POST /issues --json 1e999])
    assert_equal [2, "", "Error: Expected valid JSON for --json\n", nil], [run.code, run.out, run.err, run.options]
  end

  test "--where-json takes only an object" do
    ["null", "1", '"s"', "true", "[]", '[["a","b"]]'].each do |json|
      run = cli(["query", "Issue", "--where-json", json])
      assert_equal [2, "", "Error: Expected a JSON object for --where-json\n", nil], [run.code, run.out, run.err, run.options], json
    end
  end

  test "--json takes any JSON value" do
    ["null", "1", '"s"', "true", "[]", '[{"a":1}]'].each do |json|
      run = cli(["request", "POST", "/issues", "--json", json])
      assert_equal [0, ""], [run.code, run.err], json
      assert_equal [json, "application/json"], run.calls.first.last.values_at(:body, :content_type)
    end
  end

  test "INSTANT_RECORD_HEADERS takes only a JSON object, and is not repeated in the error" do
    { "{" => "valid JSON", " " => "valid JSON", "Authorization: secret" => "valid JSON", "null" => "a JSON object",
      "1" => "a JSON object", '"s"' => "a JSON object", "[]" => "a JSON object", '[["a","b"]]' => "a JSON object" }.each do |headers, expected|
      [%w[status], %w[--help], []].each do |argv|
        run = cli(argv, env: { "INSTANT_RECORD_HEADERS" => headers })
        assert_equal [2, "", "Error: Expected #{expected} for INSTANT_RECORD_HEADERS\n", nil],
                     [run.code, run.out, run.err, run.options], headers
      end
    end
  end

  test "an unknown command names the known ones" do
    run = cli(%w[bogus --help])
    assert_equal [2, "", nil], [run.code, run.out, run.options]
    assert_equal "Unknown command: bogus. Available: serve, sync, status, models, query, get, search, outbox, " \
                 "render, action, request, history\n", run.err
  end

  COMMAND_HELP = {
    "query" => [
      "    -w, --where KEY=VALUE            Filter condition (repeatable)",
      "        --where-json JSON            Filter object as JSON",
      "        --order SPEC                 Sort order (e.g. 'created_at desc')",
      "        --columns LIST               Comma-separated column names",
      "        --limit N                    Max rows to return",
      "        --offset N                   Row offset"
    ],
    "search" => [
      "    -m, --model NAME                 Restrict search to model (repeatable)",
      "        --columns LIST               Comma-separated columns to search",
      "        --limit N                    Max matches to return"
    ],
    "outbox" => ["        --limit N                    Max outbox mutations to return"],
    "render" => ["    -p, --param KEY=VALUE            Screen param (repeatable)"],
    "action" => [
      "    -p, --param KEY=VALUE            Screen param (repeatable)",
      "    -a, --arg KEY=VALUE              Action arg (repeatable)",
      "    -v, --value KEY=VALUE            Form field value (repeatable)",
      "        --render                     Re-render the screen after performing the action",
      "        --sync                       Sync with the server after performing the action"
    ],
    "request" => [
      "    -d, --data BODY                  Raw request body",
      "        --json JSON                  JSON object body (sets Content-Type: application/json)",
      "        --content-type TYPE          Content-Type header",
      "    -H, --header HEADER              HTTP header ('Name: Value')",
      "        --sync                       Sync with the server after a successful request"
    ],
    "history" => ["        --query QUERY                /records query string to fetch from the server"]
  }.freeze

  InstantRecord::Mcp::Cli::SUBCOMMANDS.each do |command|
    test "#{command} --help lists its options" do
      expected = [
        "Usage: instant_record_mcp #{command} [options]",
        *COMMAND_HELP[command],
        "        --pretty                     Pretty-print JSON output",
        "    -h, --help                       Show help"
      ].join("\n") + "\n"

      %w[--help -h].each do |flag|
        run = cli([command, flag])
        assert_equal [0, expected, "", nil], [run.code, run.out, run.err, run.options]
      end
    end
  end

  test "--help before the command lists global options and commands" do
    run = cli(%w[--help query])
    assert_equal [0, "", nil], [run.code, run.err, run.options]
    assert_equal <<~TEXT, run.out
      Usage: instant_record_mcp [global options] [command] [command options]
              --host PATH                  Path to compiled native host binary
              --db PATH                    Path to local SQLite replica database
              --endpoint URL               Rails sync endpoint URL
              --token TOKEN                Bearer auth token
              --cookie COOKIE              Session Cookie header value
              --scope SCOPE                Sync scope query parameter
              --header HEADER              Extra HTTP header ('Name: Value'), repeatable
              --offline                    Disable network sync requests
              --sync-on-start              Run a sync pass before executing or serving
              --timeout SECONDS            HTTP sync timeout in seconds
              --build                      Compile native host if missing (when build callback is available)
              --pretty                     Pretty-print JSON output
          -h, --help                       Show help

      Commands (default: serve):
        serve                     Start MCP JSON-RPC 2.0 server over stdio
        sync [endpoint]           Push local outbox mutations and pull latest changes
        status                    Show sync cursor, pending count, models, and screens
        models                    List synced models and local row counts
        query <Model>             Query synced records from the local SQLite replica
        get <Model> <id>          Fetch a single synced record by ID
        search <query>            Search synced records across models
        outbox                    Inspect pending local offline mutations
        render <screen>           Render a compiled native screen as JSON
        action <screen> <action>  Perform a validated local screen action offline
        request <METHOD> <path>   Dispatch a validated local HTTP request offline
        history <key>             Inspect or fetch a windowed history page
    TEXT
  end

  test "--pretty works before and after the command" do
    [%w[--pretty status], %w[status --pretty]].each do |argv|
      run = cli(argv, results: { status: { "ok" => true, "n" => [1] } })
      assert_equal [0, "{\n  \"ok\": true,\n  \"n\": [\n    1\n  ]\n}\n", true], [run.code, run.out, run.options[:pretty]]
    end
  end

  test "exits 1 only for a hash whose ok is false" do
    { { "ok" => false } => 1, { "ok" => nil } => 0, {} => 0, { ok: false } => 0, [] => 0, nil => 0 }.each do |result, code|
      run = cli(%w[status], results: { status: result })
      assert_equal [code, "#{JSON.generate(result)}\n"], [run.code, run.out], result.inspect
    end
  end

  test "runtime errors are reported and the runtime is closed" do
    { InstantRecord::Mcp::HostError.new("host died") => 1, ArgumentError.new("bad") => 2 }.each do |error, code|
      run = cli(%w[status], results: { status: error })
      assert_equal [code, "", "Error: #{error.message}\n"], [run.code, run.out, run.err]
      assert_equal [[:status, {}], [:close, {}]], run.calls
    end
  end

  test "other errors pass through, with the runtime closed" do
    commands = { status: %w[status], query_records: %w[query Issue --where-json {}], app_request: %w[request POST /issues --json {}] }
    [RuntimeError.new("boom"), JSON::ParserError.new("host JSON"), TypeError.new("host type")].each do |error|
      commands.each do |name, argv|
        runtime = FakeRuntime.new(name => error)
        assert_same error, assert_raises(error.class) { cli(argv, runtime: runtime) }
        assert_equal [name, :close], runtime.calls.map(&:first)
      end
    end
  end

  test "--sync-on-start reports the summary or the error, and skips sync itself" do
    run = cli(%w[--sync-on-start status], results: { sync: { "summary" => "pulled 2" } })
    assert_equal "[instant_record:mcp] initial sync: pulled 2\n", run.err
    assert_equal [[:sync, {}], [:status, {}], [:close, {}]], run.calls

    run = cli(%w[--sync-on-start status], results: { sync: { "error" => "down", "summary" => "x" } })
    assert_equal "[instant_record:mcp] initial sync: down\n", run.err

    run = cli(%w[--sync-on-start sync])
    assert_equal [[:sync, { endpoint: nil }], [:close, {}]], run.calls
    assert_equal "", run.err
  end

  test "serve is the default and prints no result of its own" do
    ping = %({"jsonrpc":"2.0","id":1,"method":"ping"}\n)
    [[], %w[serve], %w[--offline], %w[-- serve]].each do |argv|
      run = cli(argv, stdin: ping)
      assert_equal [0, %({"jsonrpc":"2.0","id":1,"result":{}}\n), ""], [run.code, run.out, run.err], argv.inspect
      assert_equal [[:close, {}]], run.calls
    end

    run = cli(%w[--sync-on-start serve], stdin: ping, results: { sync: { "summary" => "pulled 2" } })
    assert_equal [0, %({"jsonrpc":"2.0","id":1,"result":{}}\n), "[instant_record:mcp] initial sync: pulled 2\n"], [run.code, run.out, run.err]
    assert_equal [[:sync, {}], [:close, {}]], run.calls
  end

  test "leaves the given arguments alone" do
    argv = %w[--offline query Issue --limit 2].map(&:freeze).freeze
    assert_equal 0, cli(argv).code
  end

  test "global options reach the runtime and win over the environment" do
    env = {
      "INSTANT_RECORD_HOST" => "eh", "INSTANT_RECORD_DB" => "ed", "INSTANT_RECORD_ENDPOINT" => "ee",
      "INSTANT_RECORD_TOKEN" => "et", "INSTANT_RECORD_COOKIE" => "ec", "INSTANT_RECORD_SCOPE" => "es",
      "INSTANT_RECORD_TIMEOUT" => "3", "INSTANT_RECORD_HEADERS" => '{"A":"env","B":"env"}'
    }
    argv = ["--host", "h", "--db", "d", "--endpoint", "e", "--token", "t", "--cookie", "c", "--scope", "s",
            "--header", " B : cli:1 ", "--offline", "--sync-on-start", "--timeout", "1.5", "--build", "--pretty", "status"]
    expected = {
      host: "h", db: "d", endpoint: "e", token: "t", cookie: "c", scope: "s", headers: { "A" => "env", "B" => "cli:1" },
      offline: true, sync_on_start: true, build: true, timeout: 1.5, models: nil, screens: [], pretty: true, help: false
    }
    assert_equal expected.to_a, cli(argv, env: env).options.to_a
  end

  test "the environment wins over the given defaults" do
    defaults = { host: "dh", db: "dd", endpoint: "de", token: "dt", cookie: "dc", scope: "ds", timeout: 9, offline: 1,
                 sync_on_start: 1, build: 1, headers: { "A" => "d", "B" => "d" }, models: ["M"], screens: ["s"] }
    from_defaults = cli(%w[status], defaults: defaults, env: { "INSTANT_RECORD_OFFLINE" => "0", "INSTANT_RECORD_HEADERS" => "" }).options
    assert_equal({ host: "dh", db: "dd", endpoint: "de", token: "dt", cookie: "dc", scope: "ds", headers: { "A" => "d", "B" => "d" },
                   offline: true, sync_on_start: true, build: true, timeout: 9.0, models: ["M"], screens: ["s"], pretty: false, help: false },
                 from_defaults)

    env = { "INSTANT_RECORD_HOST" => "eh", "INSTANT_RECORD_DB" => "", "INSTANT_RECORD_ENDPOINT" => "ee",
            "INSTANT_RECORD_TOKEN" => "et", "INSTANT_RECORD_COOKIE" => "ec", "INSTANT_RECORD_SCOPE" => "es",
            "INSTANT_RECORD_TIMEOUT" => "3", "INSTANT_RECORD_HEADERS" => '{"B":"e"}' }
    from_env = cli(%w[status], defaults: defaults, env: env).options
    assert_equal({ host: "eh", db: "", endpoint: "ee", token: "et", cookie: "ec", scope: "es", timeout: 3.0,
                   headers: { "A" => "d", "B" => "e" } },
                 from_env.slice(:host, :db, :endpoint, :token, :cookie, :scope, :timeout, :headers))
    assert_equal({ "A" => "d", "B" => "d" }, defaults[:headers])
  end

  test "without settings, paths come from the root and scope, and flags are off" do
    Dir.mktmpdir do |root|
      mcp = InstantRecord::Mcp
      options = cli(%w[--scope later status], defaults: { root: root }, env: { "INSTANT_RECORD_SCOPE" => "a/b" }).options
      assert_equal({ host: mcp.default_host_path(root), db: mcp.default_database_path(root, scope: "a/b"), endpoint: nil,
                     token: nil, cookie: nil, scope: "later", headers: {}, offline: false, sync_on_start: false, build: false,
                     timeout: mcp::HttpExchange::DEFAULT_TIMEOUT.to_f, models: nil, screens: [], pretty: false, help: false }, options)
    end
    assert_equal InstantRecord::Mcp.default_host_path(Dir.pwd), cli(%w[status]).options[:host]
  end

  test "flags in the environment are on for 1, true, yes and on" do
    { "INSTANT_RECORD_OFFLINE" => :offline, "INSTANT_RECORD_SYNC_ON_START" => :sync_on_start, "INSTANT_RECORD_BUILD" => :build }.each do |name, key|
      ["1", "true", " YES ", "On"].each { |value| assert_equal true, cli(%w[sync], env: { name => value }).options[key], value }
      ["", "0", "false", "2"].each { |value| assert_equal false, cli(%w[sync], env: { name => value }).options[key], value }
    end
  end

  private

  def cli(argv, env: {}, defaults: {}, results: {}, stdin: "", runtime: FakeRuntime.new(results))
    out = StringIO.new
    err = StringIO.new
    seen = nil
    factory = lambda do |options|
      seen = options
      runtime
    end
    code = InstantRecord::Mcp::Cli.run(argv, env: env, stdin: StringIO.new(stdin), stdout: out, stderr: err,
                                             defaults: defaults, runtime_factory: factory)
    Run.new(code, out.string, err.string, seen, runtime.calls)
  end
end
