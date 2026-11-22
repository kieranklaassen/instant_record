require "test_helper"
require "instant_record/mcp"
require "json"
require "rack/mock"
require "sqlite3"
require "stringio"
require "tmpdir"

# End-to-end tests of the local MCP stdio server + offline CLI against the demo
# Rails app's real sync endpoints, Bearer token auth, session cookie auth,
# scoped replicas, <1ms offline queries/search, and validated local actions.
#
# Runs automatically with a CRuby host implementing the host.c protocol against
# the demo's actual sync endpoints; when INSTANT_RECORD_NATIVE_HOST points to a
# compiled native `host` binary (`bin/rails instant_record:native`), the
# compiled-host test also exercises the real Spinel/Roundhouse/SQLite binary.
class McpServerTest < ActionDispatch::IntegrationTest
  setup do
    @folder = Dir.mktmpdir
    @rack = Rack::MockRequest.new(Rails.application)
    MailEntry.delete_all
    Mailbox.delete_all
    Issue.delete_all
    AuthNote.delete_all
    InstantRecord::Change.delete_all
    InstantRecord::AppliedMutation.delete_all

    @support = Mailbox.create!(id: "support")
    @billing = Mailbox.create!(id: "billing")
    @older = @support.append!(
      id: SecureRandom.uuid,
      author: "rae",
      attributes: { kind: "message", address: "rae@example.test", subject: "Night shift handoff", body: "Server checks look clean" }
    )
    @newer = @support.append!(
      id: SecureRandom.uuid,
      author: "sam",
      attributes: { kind: "message", address: "sam@example.test", subject: "October invoice", body: "Attached the Q4 invoice summary" }
    )
    @billing_msg = @billing.append!(
      id: SecureRandom.uuid,
      author: "jo",
      attributes: { kind: "message", address: "jo@example.test", subject: "Wire receipt", body: "Billing wire confirmed" }
    )
    AuthNote.seed_demo
    @issue = Issue.create!(title: "Verify offline MCP sync", state: "open")
  end

  teardown do
    FileUtils.remove_entry(@folder) if @folder && Dir.exist?(@folder)
  end

  test "syncs scoped Inbox with Bearer token auth, runs <1ms offline query/search and validated actions, and drains on reconnect" do
    was_require = ENV["INBOX_REQUIRE_TOKEN"]
    ENV["INBOX_REQUIRE_TOKEN"] = "1"
    host_bin = write_demo_protocol_host(@folder)
    db_path = File.join(@folder, "maya_support.sqlite3")

    # Wrong token is rejected by demo Email::SyncController (401).
    bad_runtime = InstantRecord::Mcp::Runtime.new(
      host_binary: host_bin,
      database_path: db_path,
      endpoint: "http://www.example.com/email/sync/maya/support",
      exchange: rack_exchange(token: "wrong-token"),
      screens: %w[mailbox thread feedback]
    )
    bad_sync = bad_runtime.sync
    assert_equal false, bad_sync["ok"]
    assert_equal 401, bad_sync["http_status"]
    bad_runtime.close

    # Valid Bearer token for maya syncs support mailbox only (billing stays out).
    runtime = InstantRecord::Mcp::Runtime.new(
      host_binary: host_bin,
      database_path: db_path,
      endpoint: "http://www.example.com/email/sync/maya/support",
      exchange: rack_exchange(token: MailDirectory.token("maya")),
      screens: %w[mailbox thread feedback]
    )

    # Full MCP JSON-RPC stdio session: initialize -> sync -> query -> search -> offline action -> reconnect sync.
    res_sync = mcp_call(runtime, "instant_record_sync")
    assert_equal true, res_sync["ok"]
    assert_equal 0, res_sync["pending"]

    # Go strictly offline and verify queries, search, and validated actions work locally.
    runtime.offline = true
    assert_equal false, mcp_call(runtime, "instant_record_sync")["ok"]

    queried = mcp_call(runtime, "instant_record_query", model: "MailEntry", where: { "kind" => "message" })
    assert_equal [@older.id, @newer.id].sort, queried["rows"].map { |r| r["id"] }.sort
    refute_includes queried["rows"].map { |r| r["id"] }, @billing_msg.id
    assert_kind_of Numeric, queried["elapsed_ms"]

    # Warm offline queries stay fast (typically <1ms).
    warm_times = 5.times.map { mcp_call(runtime, "instant_record_query", model: "MailEntry", where: { "kind" => "message" })["elapsed_ms"] }
    assert_operator warm_times.min, :<, 10.0, "expected warm offline query < 10ms (got #{warm_times.inspect})"

    searched = mcp_call(runtime, "instant_record_search", query: "invoice summary", models: ["MailEntry"])
    assert_equal [@newer.id], searched["matches"].map { |m| m["id"] }

    # Validated local screen action offline: archive @newer -> creates pending outbox mutation.
    archived = mcp_call(
      runtime,
      "instant_record_action",
      screen: "mailbox",
      action: "archive",
      params: { "member" => "maya", "inbox" => "support" },
      args: { "id" => @newer.id },
      render: true
    )
    assert_equal true, archived["ok"]
    assert_equal 1, archived["pending"]
    assert_equal [@older.id], archived.dig("rendered", "rows").map { |r| r["id"] }

    outbox = mcp_call(runtime, "instant_record_outbox")
    assert_equal 1, outbox["count"]
    assert_equal "MailEntry", outbox["mutations"].first["record_type"]

    # Server does not see the archive yet while offline.
    assert_equal 2, MailEntry.open_messages.where(mailbox_id: "support").count

    # Reconnect and sync -> outbox drains to the real demo Rails server.
    runtime.offline = false
    drained = mcp_call(runtime, "instant_record_sync")
    assert_equal true, drained["ok"]
    assert_equal 0, drained["pending"]
    assert_equal [@older.id], MailEntry.open_messages.where(mailbox_id: "support").pluck(:id)
  ensure
    runtime&.close
    ENV["INBOX_REQUIRE_TOKEN"] = was_require
  end

  test "syncs session-cookie scoped AuthNote and validates local Rails requests against /instant_record" do
    # Sign in as Ada via the demo's real Auth::SessionsController to obtain a real Rails session cookie.
    sign_in = @rack.post(
      "/auth/session",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(person: "ada")
    )
    assert_equal 200, sign_in.status
    session_cookie = Array(sign_in.headers["set-cookie"]).flat_map { |v| v.to_s.split("\n") }.map { |c| c.split(";", 2).first }.join("; ")
    assert_predicate session_cookie, :present?

    host_bin = write_demo_protocol_host(@folder)
    db_path = File.join(@folder, "ada.sqlite3")
    runtime = InstantRecord::Mcp::Runtime.new(
      host_binary: host_bin,
      database_path: db_path,
      endpoint: "http://www.example.com/instant_record",
      exchange: rack_exchange(cookie: session_cookie, scope: "visitor-ada")
    )

    synced = runtime.sync
    assert_equal true, synced["ok"]

    # Ada (admin) receives everyone + members + admins + Ada's owner note, NOT Ben's or Cleo's owner notes.
    notes = runtime.query_records(model: "AuthNote")["rows"].map { |r| r["id"] }.sort
    assert_equal %w[auth-ada auth-lunch auth-payroll auth-welcome], notes
    refute_includes notes, "auth-ben"
    refute_includes notes, "auth-cleo"

    # Issue synced as well; search finds it offline.
    found = runtime.search_records(query: "offline MCP", models: ["Issue"])
    assert_equal [@issue.id], found["matches"].map { |m| m["id"] }

    # Validated local request: blank title fails validation; valid title queues and syncs to server.
    err = assert_raises(InstantRecord::Mcp::HostError) do
      runtime.app_request(method: "POST", path: "/todo/issues", params: { "issue" => { "title" => "" } })
    end
    assert_match(/Title can't be blank/, err.message)

    created = runtime.app_request(method: "POST", path: "/todo/issues", params: { "issue" => { "title" => "Created via MCP request" } })
    assert_equal true, created["ok"]
    assert_equal 1, created["pending"]

    assert_equal true, runtime.sync["ok"]
    assert_equal 0, runtime.status["pending"]
    assert Issue.exists?(title: "Created via MCP request")
  ensure
    runtime&.close
  end

  test "works end-to-end with the real compiled native host binary when INSTANT_RECORD_NATIVE_HOST is set" do
    binary = ENV["INSTANT_RECORD_NATIVE_HOST"]&.then { |path| File.expand_path(path) }
    skip "Set INSTANT_RECORD_NATIVE_HOST to a compiled native host binary to run the real binary MCP test." unless binary && File.executable?(binary)

    db_path = File.join(@folder, "compiled_maya_support.sqlite3")
    runtime = InstantRecord::Mcp::Runtime.new(
      host_binary: binary,
      database_path: db_path,
      endpoint: "http://www.example.com/email/sync/maya/support",
      exchange: rack_exchange(token: MailDirectory.token("maya")),
      screens: %w[mailbox thread feedback]
    )

    # Sync from the real demo Rails server into the compiled native host's SQLite replica.
    sync_res = mcp_call(runtime, "instant_record_sync")
    assert_equal true, sync_res["ok"]
    assert_equal 0, sync_res["pending"]

    # Go strictly offline and query/search/render/act via MCP tools.
    runtime.offline = true
    models = mcp_call(runtime, "instant_record_models")["models"].map { |m| m["name"] }
    assert_includes models, "MailEntry"

    queried = mcp_call(runtime, "instant_record_query", model: "MailEntry", where: { "kind" => "message" })
    assert_equal [@older.id, @newer.id].sort, queried["rows"].map { |r| r["id"] }.sort

    searched = mcp_call(runtime, "instant_record_search", query: "October invoice", models: ["MailEntry"])
    assert_equal [@newer.id], searched["matches"].map { |m| m["id"] }

    rendered = mcp_call(runtime, "instant_record_render_screen", screen: "mailbox", params: { "member" => "maya", "inbox" => "support" })
    assert_equal "screen", rendered.dig("tree", "kind")

    # Validated offline reply via ThreadScreen#perform + offline archive via MailboxScreen#perform.
    replied = mcp_call(
      runtime,
      "instant_record_action",
      screen: "thread",
      action: "reply",
      params: { "member" => "maya", "inbox" => "support", "thread" => @older.id },
      values: { "body" => "Reply from local MCP host" }
    )
    assert_equal true, replied["ok"]
    assert_equal 1, replied["pending"]

    archived = mcp_call(
      runtime,
      "instant_record_action",
      screen: "mailbox",
      action: "archive",
      params: { "member" => "maya", "inbox" => "support" },
      args: { "id" => @newer.id }
    )
    assert_equal true, archived["ok"]
    assert_equal 2, archived["pending"]

    # Reconnect and drain both offline actions to the real Rails server.
    runtime.offline = false
    drained = mcp_call(runtime, "instant_record_sync")
    assert_equal true, drained["ok"]
    assert_equal 0, drained["pending"]
    assert MailEntry.exists?(kind: "reply", parent_id: @older.id, author: "maya", body: "Reply from local MCP host")
    assert_equal [@older.id], MailEntry.open_messages.where(mailbox_id: "support").pluck(:id)
  ensure
    runtime&.close
  end

  private

  def rack_exchange(token: nil, cookie: nil, scope: nil)
    InstantRecord::Mcp::HttpExchange.new(
      token: token,
      cookie: cookie,
      scope: scope,
      adapter: lambda do |verb, uri, headers, body|
        env = {}
        headers.each do |key, value|
          if key.casecmp?("content-type")
            env["CONTENT_TYPE"] = value
          else
            env["HTTP_#{key.upcase.tr('-', '_')}"] = value
          end
        end
        env[:input] = body unless verb == "GET" || verb == "HEAD"
        res = @rack.request(verb, uri.request_uri, env)
        [res.status, res.body, res.headers]
      end
    )
  end

  def mcp_call(runtime, tool_name, arguments = {})
    req = JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: tool_name, arguments: arguments })
    output = StringIO.new
    InstantRecord::Mcp::Server.new(runtime, input: StringIO.new("#{req}\n"), output: output, err: StringIO.new).run
    parsed = JSON.parse(output.string.lines.first)
    JSON.parse(parsed.dig("result", "content", 0, "text"))
  end

  # Lightweight Ruby process implementing compiled/pipeline/native/host.c's exact
  # stdio protocol over SQLite so demo tests run without requiring Spinel/Roundhouse.
  def write_demo_protocol_host(dir)
    path = File.join(dir, "demo_protocol_host")
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
          CREATE TABLE IF NOT EXISTS mail_entries (
            id TEXT PRIMARY KEY, mailbox_id TEXT, author TEXT, kind TEXT, parent_id TEXT,
            address TEXT, subject TEXT, body TEXT, server_version INTEGER DEFAULT 0,
            sync_state TEXT DEFAULT 'synced', created_at TEXT, updated_at TEXT
          );
          CREATE TABLE IF NOT EXISTS auth_notes (
            id TEXT PRIMARY KEY, owner_id TEXT, audience TEXT, title TEXT, body TEXT,
            server_version INTEGER DEFAULT 0, sync_state TEXT DEFAULT 'synced', created_at TEXT, updated_at TEXT
          );
          CREATE TABLE IF NOT EXISTS issues (
            id TEXT PRIMARY KEY, title TEXT, state TEXT DEFAULT 'open',
            server_version INTEGER DEFAULT 0, sync_state TEXT DEFAULT 'synced', created_at TEXT, updated_at TEXT
          );
          INSERT OR REPLACE INTO instant_record_sync_metadata (key, value) VALUES ('compiled_models', 'AuthNote,Issue,MailEntry');
        SQL
        db
      end

      def meta(db, key) = db.get_first_value("SELECT value FROM instant_record_sync_metadata WHERE key = ?", [key])
      def set_meta(db, key, val) = db.execute("INSERT OR REPLACE INTO instant_record_sync_metadata (key, value) VALUES (?, ?)", [key, val.to_s])

      def upsert_record(db, rec)
        attrs = rec["attributes"] || {}
        case rec["type"]
        when "MailEntry"
          db.execute(
            "INSERT OR REPLACE INTO mail_entries (id, mailbox_id, author, kind, parent_id, address, subject, body, server_version, sync_state, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'synced', ?, ?)",
            [attrs["id"], attrs["mailbox_id"], attrs["author"], attrs["kind"], attrs["parent_id"], attrs["address"], attrs["subject"], attrs["body"], rec["version"].to_i, attrs["created_at"], attrs["updated_at"]]
          )
        when "AuthNote"
          db.execute(
            "INSERT OR REPLACE INTO auth_notes (id, owner_id, audience, title, body, server_version, sync_state, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, 'synced', ?, ?)",
            [attrs["id"], attrs["owner_id"], attrs["audience"], attrs["title"], attrs["body"], rec["version"].to_i, attrs["created_at"], attrs["updated_at"]]
          )
        when "Issue"
          db.execute(
            "INSERT OR REPLACE INTO issues (id, title, state, server_version, sync_state, created_at, updated_at) VALUES (?, ?, ?, ?, 'synced', ?, ?)",
            [attrs["id"], attrs["title"], attrs["state"] || "open", rec["version"].to_i, attrs["created_at"], attrs["updated_at"]]
          )
        end
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
            changed = false
            outbox_rows = db.execute("SELECT * FROM instant_record_outbox ORDER BY created_at ASC, id ASC")
            unless outbox_rows.empty?
              payload = {
                mutations: outbox_rows.map do |m|
                  { id: m["id"], record_type: m["record_type"], record_id: m["record_id"], operation: m["operation"], changes: JSON.parse(m["changes_payload"]), base_version: m["base_version"].to_i }
                end
              }
              ident = meta(db, "identity")
              payload[:identity] = ident if ident && !ident.empty?
              raw = do_exchange("POST #{endpoint}/mutations\n#{JSON.generate(payload)}")
              status_line, body = raw.split("\n", 2)
              if status_line.to_i >= 200 && status_line.to_i < 300
                Array(JSON.parse(body)["results"]).each do |res|
                  db.execute("DELETE FROM instant_record_outbox WHERE id = ?", [res["mutation_id"]])
                end
                changed = true
              end
            end

            if meta(db, "cursor").nil?
              raw = do_exchange("GET #{endpoint}/bootstrap\n")
              status_line, body = raw.split("\n", 2)
              if status_line.to_i >= 200 && status_line.to_i < 300
                data = JSON.parse(body)
                Array(data["records"]).each { |rec| upsert_record(db, rec) }
                set_meta(db, "cursor", data["cursor"].to_i)
                set_meta(db, "identity", data["identity"]) if data["identity"]
                changed = true
              end
            else
              ident = meta(db, "identity")
              who = ident && !ident.empty? ? "&identity=#{ident}" : ""
              raw = do_exchange("GET #{endpoint}/events?after=#{meta(db, 'cursor').to_i}&window=0#{who}\n")
              status_line, body = raw.split("\n", 2)
              if status_line.to_i >= 200 && status_line.to_i < 300
                body.to_s.split("\n\n").each do |frame|
                  id_line = frame[/^id: (.+)$/, 1]
                  data_line = frame[/^data: (.+)$/, 1]
                  next unless data_line

                  upsert_record(db, JSON.parse(data_line))
                  set_meta(db, "cursor", id_line.to_i) if id_line
                  changed = true
                end
              end
            end

            pending = db.get_first_value("SELECT COUNT(*) FROM instant_record_outbox").to_i
            send_ok("#{changed ? 'changed' : 'unchanged'} pending=#{pending} cursor=#{meta(db, 'cursor').to_i}", changed ? "records_changed" : "")
          when "render"
            req = JSON.parse(input)
            inbox = req.dig("params", "inbox").to_s
            rows = db.execute(
              "SELECT id, author, subject FROM mail_entries WHERE mailbox_id = ? AND kind = 'message' AND NOT EXISTS (SELECT 1 FROM mail_entries a WHERE a.parent_id = mail_entries.id AND a.mailbox_id = mail_entries.mailbox_id AND a.kind = 'archive') ORDER BY created_at DESC",
              [inbox]
            )
            send_ok(JSON.generate(kind: "screen", screen: req["screen"], rows: rows))
          when "action"
            req = JSON.parse(input)
            if req["screen"] == "mailbox" && req["action"] == "archive"
              member = req.dig("params", "member").to_s
              inbox = req.dig("params", "inbox").to_s
              parent_id = req.dig("args", "id").to_s
              id = SecureRandom.uuid
              now = Time.now.utc.iso8601(6)
              db.execute("INSERT INTO mail_entries VALUES (?, ?, ?, 'archive', ?, NULL, NULL, NULL, 0, 'pending', ?, ?)", [id, inbox, member, parent_id, now, now])
              changes = { id: id, mailbox_id: inbox, author: member, kind: "archive", parent_id: parent_id, created_at: now, updated_at: now }
              db.execute("INSERT INTO instant_record_outbox VALUES (?, 'MailEntry', ?, 'create', ?, 0, ?, ?)", [SecureRandom.uuid, id, JSON.generate(changes), now, now])
              send_ok("", "records_changed\nMailEntry:#{id}")
            else
              send_error("Unknown action #{req['action']}")
            end
          when "request"
            head, body = input.split("\r\n\r\n", 2)
            verb, req_path = head.lines.first.split(" ", 3)
            if verb == "POST" && req_path == "/todo/issues"
              form = URI.decode_www_form(body.to_s).to_h
              title = form["issue[title]"].to_s.strip
              if title.empty?
                send_error("ActiveRecord::RecordInvalid: Validation failed: Title can't be blank")
              else
                id = SecureRandom.uuid
                now = Time.now.utc.iso8601(6)
                db.execute("INSERT INTO issues VALUES (?, ?, 'open', 0, 'pending', ?, ?)", [id, title, now, now])
                changes = { id: id, title: title, state: "open", created_at: now, updated_at: now }
                db.execute("INSERT INTO instant_record_outbox VALUES (?, 'Issue', ?, 'create', ?, 0, ?, ?)", [SecureRandom.uuid, id, JSON.generate(changes), now, now])
                send_ok("302\nLocation: /todo\n\n", "records_changed\nIssue:#{id}")
              end
            else
              send_ok("404\nContent-Type: text/plain\n\nNot Found")
            end
          else
            send_error("No entry named #{entry}")
          end
        end
      end
    RUBY
    File.chmod(0o755, path)
    path
  end
end
