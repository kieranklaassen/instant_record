require "test_helper"
require "instant_record/mcp"
require "json"
require "sqlite3"
require "stringio"
require "tmpdir"

class McpServerCliTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir
    @db_path = File.join(@dir, "replica.sqlite3")
    @host_bin = write_sqlite_backed_host(@dir)
  end

  teardown do
    @runtimes&.each(&:close)
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  test "MCP stdio server handles full JSON-RPC 2.0 lifecycle, tools, resources, and error cases" do
    exchange = InstantRecord::Mcp::HttpExchange.new(
      token: "tok-1",
      adapter: lambda do |verb, uri, headers, _body|
        if verb == "GET" && uri.path.end_with?("/bootstrap")
          return [401, "unauthorized"] unless headers["Authorization"] == "Bearer tok-1"

          payload = {
            cursor: 5,
            identity: "maya-id",
            records: [
              { type: "Issue", id: "i-1", version: 1, attributes: { id: "i-1", title: "Ship MCP server", state: "open", created_at: "2026-11-21T10:00:00Z", updated_at: "2026-11-21T10:00:00Z" } }
            ]
          }
          [200, JSON.generate(payload)]
        elsif verb == "GET" && uri.path.end_with?("/records")
          [200, JSON.generate(records: [{ type: "Issue", id: "i-old", version: 1, attributes: { id: "i-old", title: "Older archived issue", state: "done", created_at: "2026-11-19T10:00:00Z", updated_at: "2026-11-19T10:00:00Z" } }], has_more: false)]
        else
          [200, JSON.generate(results: [])]
        end
      end
    )

    runtime = InstantRecord::Mcp::Runtime.new(
      host_binary: @host_bin,
      database_path: @db_path,
      endpoint: "http://127.0.0.1:3000/instant_record",
      exchange: exchange,
      screens: ["issues"]
    )

    requests = [
      { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-03-26", clientInfo: { name: "test", version: "1" } } },
      { jsonrpc: "2.0", method: "notifications/initialized" },
      { jsonrpc: "2.0", id: 2, method: "ping" },
      { jsonrpc: "2.0", id: 3, method: "tools/list" },
      { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "instant_record_sync", arguments: {} } },
      { jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "instant_record_query", arguments: { model: "Issue", where: { state: "open" } } } },
      { jsonrpc: "2.0", id: 6, method: "tools/call", params: { name: "instant_record_search", arguments: { query: "MCP" } } },
      { jsonrpc: "2.0", id: 7, method: "tools/call", params: { name: "instant_record_action", arguments: { screen: "issues", action: "close", args: { id: "i-1" }, render: true } } },
      { jsonrpc: "2.0", id: 8, method: "tools/call", params: { name: "instant_record_request", arguments: { method: "POST", path: "/todo/issues", params: { issue: { title: "Created offline" } } } } },
      { jsonrpc: "2.0", id: 9, method: "tools/call", params: { name: "instant_record_request", arguments: { method: "POST", path: "/todo/issues", params: { issue: { title: "" } } } } },
      { jsonrpc: "2.0", id: 10, method: "tools/call", params: { name: "instant_record_history", arguments: { key: "older:issues", query: "type=Issue&before_id=i-1" } } },
      { jsonrpc: "2.0", id: 11, method: "resources/list" },
      { jsonrpc: "2.0", id: 12, method: "resources/read", params: { uri: "instant-record://models/Issue" } },
      { jsonrpc: "2.0", id: 13, method: "unknown/method" },
      "{not valid json"
    ]

    input = StringIO.new(requests.map { |r| r.is_a?(String) ? r : JSON.generate(r) }.join("\n") + "\n")
    output = StringIO.new
    err = StringIO.new

    InstantRecord::Mcp::Server.new(runtime, input: input, output: output, err: err).run
    responses = output.string.lines.map { |line| JSON.parse(line) }

    # Notification produces no response -> 14 responses for 15 input lines.
    assert_equal 14, responses.size

    by_id = responses.each_with_object({}) { |r, acc| acc[r["id"]] = r }

    assert_equal "2025-03-26", by_id[1].dig("result", "protocolVersion")
    assert_equal "instant_record", by_id[1].dig("result", "serverInfo", "name")
    assert_equal({}, by_id[2]["result"])

    tool_names = by_id[3].dig("result", "tools").map { |t| t["name"] }
    assert_includes tool_names, "instant_record_query"
    assert_includes tool_names, "instant_record_search"
    assert_includes tool_names, "instant_record_action"
    assert_includes tool_names, "instant_record_request"
    assert_includes tool_names, "instant_record_sync"

    sync_data = parse_tool_json(by_id[4])
    assert_equal true, sync_data["ok"]
    assert_equal 5, sync_data["cursor"]
    assert_equal "maya-id", sync_data["identity"]

    query_data = parse_tool_json(by_id[5])
    assert_equal ["i-1"], query_data["rows"].map { |r| r["id"] }

    search_data = parse_tool_json(by_id[6])
    assert_equal ["i-1"], search_data["matches"].map { |m| m["id"] }

    action_data = parse_tool_json(by_id[7])
    assert_equal true, action_data["ok"]
    assert_equal 1, action_data["pending"]
    assert_equal "screen", action_data.dig("rendered", "kind")

    req_ok = parse_tool_json(by_id[8])
    assert_equal true, req_ok["ok"]
    assert_equal 302, req_ok["status"]
    assert_equal 2, req_ok["pending"]

    # Validation error from compiled app returns isError: true and does not enqueue outbox mutation.
    assert_equal true, by_id[9].dig("result", "isError")
    req_bad = parse_tool_json(by_id[9])
    assert_equal false, req_bad["ok"]
    assert_match(/Title can't be blank/, req_bad["error"])

    history_data = parse_tool_json(by_id[10])
    assert_equal true, history_data["ok"]
    assert_equal 1, history_data["applied"]

    resource_uris = by_id[11].dig("result", "resources").map { |r| r["uri"] }
    assert_includes resource_uris, "instant-record://status"
    assert_includes resource_uris, "instant-record://models/Issue"

    issue_resource = JSON.parse(by_id[12].dig("result", "contents", 0, "text"))
    assert_equal 3, issue_resource["total"]

    assert_equal(-32601, by_id[13].dig("error", "code"))
    assert_equal(-32700, by_id[nil].dig("error", "code"))
  ensure
    runtime&.close
  end

  test "CLI executes offline subcommands and supports --build fallback" do
    built = false
    builder = lambda do
      built = true
      @dir
    end

    # When host path does not exist and --build is passed, builder runs and produces host.
    FileUtils.cp(@host_bin, File.join(@dir, "host"))
    out = StringIO.new
    err = StringIO.new
    code = InstantRecord::Mcp::Cli.run(
      ["--host", File.join(@dir, "missing_host"), "--db", @db_path, "--build", "--offline", "status"],
      stdout: out,
      stderr: err,
      defaults: { builder: builder, screens: ["issues"] }
    )
    assert_equal 0, code, err.string
    assert built
    status = JSON.parse(out.string)
    assert_equal true, status["offline"]
    assert_equal ["issues"], status["screens"]

    # Create a record offline via `request`, query it, search it, inspect outbox.
    req_out = StringIO.new
    req_code = InstantRecord::Mcp::Cli.run(
      ["--host", @host_bin, "--db", @db_path, "--offline", "request", "POST", "/todo/issues", "--data", "issue[title]=CLI+offline+task"],
      stdout: req_out,
      stderr: StringIO.new
    )
    assert_equal 0, req_code
    assert_equal 1, JSON.parse(req_out.string)["pending"]

    query_out = StringIO.new
    assert_equal 0, InstantRecord::Mcp::Cli.run(
      ["--host", @host_bin, "--db", @db_path, "--offline", "query", "Issue", "--where", "state=open"],
      stdout: query_out,
      stderr: StringIO.new
    )
    rows = JSON.parse(query_out.string)["rows"]
    assert_equal ["CLI offline task"], rows.map { |r| r["title"] }

    search_out = StringIO.new
    assert_equal 0, InstantRecord::Mcp::Cli.run(
      ["--host", @host_bin, "--db", @db_path, "--offline", "search", "offline", "--model", "Issue"],
      stdout: search_out,
      stderr: StringIO.new
    )
    assert_equal 1, JSON.parse(search_out.string)["count"]

    outbox_out = StringIO.new
    assert_equal 0, InstantRecord::Mcp::Cli.run(
      ["--host", @host_bin, "--db", @db_path, "--offline", "outbox"],
      stdout: outbox_out,
      stderr: StringIO.new
    )
    assert_equal 1, JSON.parse(outbox_out.string)["count"]

    # Unknown command returns exit code 2.
    assert_equal 2, InstantRecord::Mcp::Cli.run(["bogus"], stdout: StringIO.new, stderr: StringIO.new)
  end

  test "a sync that fails after a write leaves the write's result, its exit status and one queued write" do
    commands = {
      %w[action issues close --arg id=i-1 --sync] => ["instant_record_action", { screen: "issues", action: "close", args: { id: "i-1" }, sync: true }],
      ["request", "POST", "/todo/issues", "--data", "issue[title]=Once", "--sync"] =>
        ["instant_record_request", { method: "POST", path: "/todo/issues", body: "issue[title]=Once", sync: true }]
    }
    no_endpoint = "No sync endpoint configured. Pass endpoint or set INSTANT_RECORD_ENDPOINT."
    failures = [
      [nil, nil, no_endpoint],
      ["http://sync.test", InstantRecord::Mcp::HostError.new("host failed"), "host failed"],
      ["http://sync.test", InstantRecord::Mcp::HostCrashedError.new("host died"), "host died"],
      ["http://sync.test", Errno::EPIPE.new, "Broken pipe"]
    ]

    failures.product(commands.to_a).each_with_index do |((endpoint, failure, message), (argv, (tool, arguments))), index|
      runtime = failing_sync_runtime("cli#{index}", endpoint, failure)
      out = StringIO.new
      err = StringIO.new
      code = InstantRecord::Mcp::Cli.run(argv, env: {}, stdout: out, stderr: err, runtime_factory: ->(_) { runtime })
      assert_equal [0, ""], [code, err.string], "#{argv} #{message}"
      assert_write_kept message, JSON.parse(out.string)

      runtime = failing_sync_runtime("tool#{index}", endpoint, failure)
      call = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: tool, arguments: arguments } }
      output = StringIO.new
      InstantRecord::Mcp::Server.new(runtime, input: StringIO.new("#{JSON.generate(call)}\n"), output: output).run
      response = JSON.parse(output.string)
      assert_equal false, response.dig("result", "isError"), output.string
      assert_write_kept message, parse_tool_json(response)
      runtime.close
    end
  end

  test "a sync on its own still raises, and a bug in a sync after a write is not hidden" do
    assert_raises(ArgumentError) { failing_sync_runtime("alone", nil, nil).sync }

    [NoMethodError, ArgumentError, TypeError].each do |bug|
      runtime = failing_sync_runtime(bug.name, "http://sync.test", bug.new("bug"))
      assert_raises(bug) { runtime.perform_action(screen: "issues", action: "close", sync: true) }
      assert_raises(bug) { runtime.app_request(method: "POST", path: "/todo/issues", body: "issue[title]=Once", sync: true) }
    end
  end

  test "a cursor read or re-render that fails after a write leaves the write's result and one queued write" do
    failures = [
      InstantRecord::Mcp::HostError.new("failed"), InstantRecord::Mcp::HostCrashedError.new("failed"), IOError.new("failed")
    ]
    action = ["instant_record_action", { screen: "issues", action: "close", args: { id: "i-1" }, render: true }]
    request = ["instant_record_request", { method: "POST", path: "/todo/issues", body: "issue[title]=Once" }]

    failures.product([["cursor", action], ["cursor", request], ["render", action]]).each_with_index do |(failure, (entry, call)), index|
      data = kept_write(failing_runtime("kept#{index}", entry => failure), *call)
      if entry == "cursor"
        assert data.key?("pending")
        assert_equal [nil, "failed"], data.values_at("pending", "pending_error")
        refute data.key?("rendered_error")
        assert_equal "screen", data.dig("rendered", "kind") if call == action
      else
        assert_equal [1, nil, "failed"], data.values_at("pending", "rendered", "rendered_error")
        refute data.key?("pending_error")
      end
    end

    both = kept_write(failing_runtime("both", "cursor" => failures.first, "render" => failures.first), *action)
    assert_equal %w[failed failed], both.values_at("pending_error", "rendered_error")

    runtime = failing_runtime("cli", "cursor" => failures.first)
    out = StringIO.new
    code = InstantRecord::Mcp::Cli.run(%w[action issues close --arg id=i-1], env: {}, stdout: out, stderr: StringIO.new, runtime_factory: ->(_) { runtime })
    assert_equal [0, true, nil, "failed"], [code, *JSON.parse(out.string).values_at("ok", "pending", "pending_error")]
  end

  test "a re-render JSON cannot read or write leaves the write's result" do
    ["not json", *UNWRITABLE_JSON].each_with_index do |tree, index|
      runtime = failing_runtime("tree#{index}", "render" => tree)
      data = kept_write(runtime, "instant_record_action", { screen: "issues", action: "close", args: { id: "i-1" }, render: true })
      assert_equal [1, nil], data.values_at("pending", "rendered")
      assert_kind_of String, data["rendered_error"]
    end
  end

  test "a cursor reply without a count leaves pending unknown" do
    data = kept_write(failing_runtime("blank", "cursor" => ""), "instant_record_request", { method: "POST", path: "/todo/issues", body: "issue[title]=Once" })
    assert_equal [true, nil], [data.key?("pending"), data["pending"]]
  end

  test "status, sync and open report the whole cursor reply, and defaults for what it leaves out" do
    {
      "cursor=7 pending=2 bootstrap=ready identity=maya" => { "cursor" => 7, "pending" => 2, "bootstrap" => "ready", "identity" => "maya" },
      "" => { "cursor" => 0, "pending" => 0, "bootstrap" => "needed", "identity" => "" }
    }.each_with_index do |(reply, expected), index|
      runtime = failing_runtime("position#{index}", endpoint: "http://sync.test", "cursor" => reply)
      answers = [runtime.status, runtime.sync, runtime.open_database(path: File.join(@dir, "opened#{index}.sqlite3"))]
      runtime.offline = true
      answers << runtime.sync
      answers.each { |answer| assert_equal expected, answer.slice(*expected.keys) }
    end
  end

  test "a bug in a cursor read or re-render after a write is not hidden" do
    [NoMethodError, ArgumentError, TypeError].each do |bug|
      %w[cursor render].each do |entry|
        runtime = failing_runtime("#{bug}#{entry}", entry => bug.new("bug"))
        assert_raises(bug) { runtime.perform_action(screen: "issues", action: "close", render: true) }
        next unless entry == "cursor"

        assert_raises(bug) { runtime.app_request(method: "POST", path: "/todo/issues", body: "issue[title]=Once") }
      end
    end
  end

  test "an app response that is not UTF-8 leaves the write's result" do
    data = raw_response("200\nContent-Type: application/json\nX-Name: caf\xE9\n\n{\"a\":\"\xE9\u00E9\"}")

    assert_equal "caf\u{FFFD}", data.dig("headers", "x-name")
    assert_equal "{\"a\":\"\u{FFFD}\u00E9\"}", data["body"]
    assert_equal({ "a" => "\u{FFFD}\u00E9" }, data["json"])
    assert_equal "records_changed\nIssue:\u{FFFD}", data["notice"]
  end

  test "an app response holding JSON that cannot be written again keeps its body and has no json" do
    UNWRITABLE_JSON.each do |body|
      data = raw_response("200\nContent-Type: application/json\n\n#{body}")
      assert_equal [body, nil], data.values_at("body", "json")
    end
  end

  test "a history page is read as UTF-8, and one that is not is reported and not applied" do
    page = ->(title) { JSON.generate(records: [{ type: "Issue", id: "i-9", version: 1, attributes: { id: "i-9", title: title } }], has_more: false) }
    bad = page.call("bad ?").b.sub("?", "\xE9".b)
    replies = [page.call("caf\u00E9").b, bad, bad.dup.force_encoding(Encoding::UTF_8)]
    exchange = InstantRecord::Mcp::HttpExchange.new(adapter: ->(*) { [200, replies.shift] })
    runtime = InstantRecord::Mcp::Runtime.new(host_binary: @host_bin, database_path: @db_path, endpoint: "http://sync.test", exchange: exchange)
    (@runtimes ||= []) << runtime

    assert_equal [true, 1], runtime.fetch_history(key: "older", query: "q=1").values_at("ok", "applied")
    2.times do
      assert_equal [false, 200, "History response is not valid UTF-8"],
        runtime.fetch_history(key: "older", query: "q=1").values_at("ok", "http_status", "error")
    end
    assert_equal ["caf\u00E9"], runtime.query_records(model: "Issue")["rows"].map { |row| row["title"] }
  end

  private

  # Each parses (the first only in json 2), but holds what JSON.generate refuses
  # once it is in an answer.
  UNWRITABLE_JSON = ['["\udc00"]', "[1e999]", "#{'[' * 100}#{']' * 100}"].freeze
  private_constant :UNWRITABLE_JSON

  def kept_write(runtime, tool, arguments)
    call = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: tool, arguments: arguments } }
    output = StringIO.new
    InstantRecord::Mcp::Server.new(runtime, input: StringIO.new("#{JSON.generate(call)}\n"), output: output, err: StringIO.new).run
    response = JSON.parse(output.string)
    assert_equal false, response.dig("result", "isError"), output.string
    data = parse_tool_json(response)
    assert_equal true, data["ok"]
    assert_equal 1, runtime.outbox["count"]
    data
  end

  # Queues one write in an app that answers with exactly these bytes.
  def raw_response(bytes)
    kept_write(failing_runtime("raw#{@runtimes.to_a.size}"), "instant_record_request", { method: "POST", path: "/raw", body: bytes.unpack1("H*") })
  end

  # A runtime on the real test host, whose "sync" entry raises `failure`.
  def failing_sync_runtime(name, endpoint, failure)
    failing_runtime(name, endpoint: endpoint, "sync" => failure)
  end

  # A runtime on the real test host, where an entry raises or answers as given.
  def failing_runtime(name, endpoint: nil, **entries)
    host = InstantRecord::Mcp::HostProcess.new(binary: @host_bin, database: File.join(@dir, "#{name}.sqlite3"))
    host.define_singleton_method(:call) do |entry, input = ""|
      case (answer = entries[entry])
      when nil then super(entry, input)
      when Exception then raise answer
      else InstantRecord::Mcp::HostProcess::Result.new(out: answer, notice: "")
      end
    end
    runtime = InstantRecord::Mcp::Runtime.new(database_path: host.database_path, endpoint: endpoint, host_process: host)
    (@runtimes ||= []) << runtime
    runtime
  end

  def assert_write_kept(message, data)
    assert_equal [true, 1], data.values_at("ok", "pending"), data.inspect
    assert_equal({ "ok" => false, "error" => message }, data["sync"])
  end

  def parse_tool_json(response)
    JSON.parse(response.dig("result", "content", 0, "text"))
  end

  def write_sqlite_backed_host(dir)
    path = File.join(dir, "sqlite_host")
    File.write(path, "#!#{RbConfig.ruby}\n" + <<~'RUBY')
      require "json"
      require "securerandom"
      require "sqlite3"
      require "time"
      require "uri"

      $stdin.binmode
      $stdout.binmode

      def read_exact(len)
        return "".b if len <= 0
        buf = "".b
        while buf.bytesize < len
          chunk = $stdin.read(len - buf.bytesize)
          exit 2 if chunk.nil? || chunk.empty?
          buf << chunk
        end
        buf
      end

      def send_ok(out = "", notice = "")
        o = out.b
        n = notice.b
        $stdout.write("ok #{o.bytesize} #{n.bytesize}\n")
        $stdout.write(o)
        $stdout.write(n)
        $stdout.flush
      end

      def send_error(msg)
        m = msg.b
        $stdout.write("error #{m.bytesize}\n")
        $stdout.write(m)
        $stdout.flush
      end

      def do_exchange(request)
        req = request.b
        $stdout.write("exchange #{req.bytesize}\n")
        $stdout.write(req)
        $stdout.flush
        len = $stdin.gets.to_i
        read_exact(len).force_encoding(Encoding::UTF_8)
      end

      def open_db(path)
        db = SQLite3::Database.new(path)
        db.results_as_hash = true
        db.execute_batch(<<~SQL)
          CREATE TABLE IF NOT EXISTS instant_record_sync_metadata (key TEXT PRIMARY KEY, value TEXT);
          CREATE TABLE IF NOT EXISTS instant_record_outbox (
            id TEXT PRIMARY KEY, record_type TEXT, record_id TEXT, operation TEXT,
            changes_payload TEXT, base_version INTEGER DEFAULT 0, created_at TEXT, updated_at TEXT
          );
          CREATE TABLE IF NOT EXISTS issues (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'open',
            server_version INTEGER DEFAULT 0, sync_state TEXT DEFAULT 'synced',
            created_at TEXT, updated_at TEXT
          );
          INSERT OR REPLACE INTO instant_record_sync_metadata (key, value) VALUES ('compiled_models', 'Issue');
        SQL
        db
      end

      def meta(db, key)
        db.get_first_value("SELECT value FROM instant_record_sync_metadata WHERE key = ?", [key])
      end

      def set_meta(db, key, val)
        db.execute("INSERT OR REPLACE INTO instant_record_sync_metadata (key, value) VALUES (?, ?)", [key, val.to_s])
      end

      def upsert_issue(db, record)
        attrs = record["attributes"] || {}
        db.execute(
          "INSERT OR REPLACE INTO issues (id, title, state, server_version, sync_state, created_at, updated_at) VALUES (?, ?, ?, ?, 'synced', ?, ?)",
          [attrs["id"], attrs["title"], attrs["state"] || "open", record["version"].to_i, attrs["created_at"], attrs["updated_at"]]
        )
      end

      db = open_db(ARGV[0])
      send_ok

      while (line = $stdin.gets)
        parts = line.strip.split
        case parts[0]
        when "call"
          entry = parts[1]
          input = read_exact(parts[2].to_i).force_encoding(Encoding::UTF_8)
          case entry
          when "cursor"
            c = meta(db, "cursor")
            pending = db.get_first_value("SELECT COUNT(*) FROM instant_record_outbox").to_i
            ident = meta(db, "identity").to_s
            send_ok("cursor=#{c.to_i} pending=#{pending} bootstrap=#{c.nil? ? 'needed' : 'ready'} identity=#{ident}")
          when "sync"
            endpoint = input.strip
            raw = do_exchange("GET #{endpoint}/bootstrap\n")
            status_line, body = raw.split("\n", 2)
            if status_line.to_i == 200
              data = JSON.parse(body)
              Array(data["records"]).each { |rec| upsert_issue(db, rec) }
              set_meta(db, "cursor", data["cursor"].to_i)
              set_meta(db, "identity", data["identity"]) if data["identity"]
              pending = db.get_first_value("SELECT COUNT(*) FROM instant_record_outbox").to_i
              send_ok("changed pending=#{pending} cursor=#{data['cursor'].to_i}", "records_changed")
            else
              pending = db.get_first_value("SELECT COUNT(*) FROM instant_record_outbox").to_i
              send_ok("unchanged pending=#{pending} cursor=#{meta(db, 'cursor').to_i}")
            end
          when "render"
            req = JSON.parse(input)
            rows = db.execute("SELECT id, title, state FROM issues ORDER BY created_at DESC")
            send_ok(JSON.generate(kind: "screen", screen: req["screen"], children: rows.map { |r| { kind: "row", id: r["id"], text: r["title"], state: r["state"] } }))
          when "action"
            req = JSON.parse(input)
            if req["screen"] == "issues" && req["action"] == "close"
              id = req.dig("args", "id").to_s
              now = Time.now.utc.iso8601
              db.execute("UPDATE issues SET state = 'done', sync_state = 'pending', updated_at = ? WHERE id = ?", [now, id])
              db.execute("INSERT INTO instant_record_outbox VALUES (?, 'Issue', ?, 'update', ?, 1, ?, ?)", [SecureRandom.uuid, id, JSON.generate(state: "done"), now, now])
              send_ok("", "records_changed\nIssue:#{id}")
            else
              send_error("Unknown action #{req['action']}")
            end
          when "request"
            head, body = input.split("\r\n\r\n", 2)
            verb, req_path = head.lines.first.split(" ", 3)
            if verb == "POST" && req_path == "/raw"
              now = Time.now.utc.iso8601
              db.execute("INSERT INTO instant_record_outbox VALUES (?, 'Issue', 'raw', 'update', '{}', 1, ?, ?)", [SecureRandom.uuid, now, now])
              send_ok([body].pack("H*"), "records_changed\nIssue:\xFF")
            elsif verb == "POST" && req_path == "/todo/issues"
              form = URI.decode_www_form(body.to_s).to_h
              title = form["issue[title]"].to_s.strip
              if title.empty?
                send_error("ActiveRecord::RecordInvalid: Validation failed: Title can't be blank")
              else
                id = SecureRandom.uuid
                now = Time.now.utc.iso8601
                db.execute("INSERT INTO issues VALUES (?, ?, 'open', 0, 'pending', ?, ?)", [id, title, now, now])
                db.execute("INSERT INTO instant_record_outbox VALUES (?, 'Issue', ?, 'create', ?, 0, ?, ?)", [SecureRandom.uuid, id, JSON.generate(id: id, title: title, state: "open"), now, now])
                send_ok("302\nLocation: /todo\n\n", "records_changed\nIssue:#{id}")
              end
            else
              send_ok("404\nContent-Type: text/plain\n\nNot Found")
            end
          when "history"
            req = JSON.parse(input)
            key = "history:#{req['key']}"
            if req["response"].to_s.empty?
              mark = meta(db, key)
              send_ok(JSON.generate(ok: !mark.nil?, applied: 0, has_more: mark == "more"))
            else
              page = JSON.parse(req["response"])
              records = Array(page["records"])
              records.each { |rec| upsert_issue(db, rec) }
              set_meta(db, key, page["has_more"] ? "more" : "end")
              send_ok(JSON.generate(ok: true, applied: records.size, has_more: !!page["has_more"]))
            end
          else
            send_error("No entry named #{entry}")
          end
        when "open"
          new_path = read_exact(parts[1].to_i).force_encoding(Encoding::UTF_8)
          db.close
          db = open_db(new_path)
          send_ok
        end
      end
    RUBY
    File.chmod(0o755, path)
    path
  end
end
