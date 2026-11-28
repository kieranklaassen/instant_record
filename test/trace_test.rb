require "test_helper"
require "base64"
require "digest"
require "json"
require "open3"
require "rake"
require "sqlite3"
require "tmpdir"
require "instant_record/trace"

class TraceTest < Minitest::Test
  def test_government_identifiers_are_redacted_without_changing_foreign_keys
    redactor = InstantRecord::Trace::Redactor.new(salt: "test")
    %w[tax_id national_id billing_tax_id customer_national_id].each do |column|
      assert redactor.pii_column?("users", column), column
      refute_equal "123456789", redactor.redact_attributes("users", column => "123456789")[column]
    end
    %w[id user_id account_id created_at].each do |column|
      refute redactor.pii_column?("users", column), column
    end
    safe = InstantRecord::Trace::Redactor.new(safe_columns: { "users" => ["tax_id"] })
    refute safe.pii_column?("users", "tax_id")
  end

  def test_schema_extractor_reads_tables_columns_and_timestamps
    schema_rb = <<~RUBY
      ActiveRecord::Schema[8.1].define(version: 2026_11_21_000001) do
        create_table "users", id: :string, force: :cascade do |t|
          t.string "email", null: false
          t.string "phone"
          t.integer "server_version", default: 0, null: false
          t.timestamps
        end

        create_table "notes", id: :string do |t|
          t.string "title"
          t.text "body"
        end
      end
    RUBY

    extracted = InstantRecord::Trace::SchemaExtractor.from_schema_rb(schema_rb)
    assert_equal %w[id email phone server_version created_at updated_at], extracted["users"]
    assert_equal %w[id title body], extracted["notes"]
  end

  def test_ruby_redactor_scrubs_sqlite_checkpoint_and_vacuums_raw_pii
    raw_bytes = build_sample_sqlite_bytes
    redactor = InstantRecord::Trace::Redactor.new(
      schema: { "users" => %w[id email phone role created_at] },
      salt: "ruby-test-salt"
    )

    trace = {
      "format" => InstantRecord::Trace::FORMAT,
      "version" => InstantRecord::Trace::VERSION,
      "checkpoint" => {
        "mode" => "sqlite3",
        "digest" => Digest::SHA256.hexdigest(raw_bytes),
        "byteLength" => raw_bytes.bytesize,
        "schemaVersion" => 1,
        "encoding" => "base64",
        "data" => Base64.strict_encode64(raw_bytes),
        "env" => { "RAILS_ENV" => "production", "SECRET_KEY_BASE" => "super-secret-key" },
        "cookies" => { "_app_session" => "cookie-val" }
      },
      "steps" => []
    }

    redacted = redactor.redact_trace(trace)
    checkpoint = redacted["checkpoint"]
    clean_bytes = Base64.strict_decode64(checkpoint["data"])

    assert_equal true, checkpoint["redacted"]
    assert_equal Digest::SHA256.hexdigest(clean_bytes), checkpoint["digest"]
    assert_equal Digest::SHA256.hexdigest(raw_bytes), checkpoint["originalDigest"]
    refute_equal checkpoint["digest"], checkpoint["originalDigest"]
    refute_includes clean_bytes, "bob@private.example".b
    refute_includes clean_bytes, "+1-212-555-0144".b
    assert_equal "production", checkpoint["env"]["RAILS_ENV"]
    refute_equal "super-secret-key", checkpoint["env"]["SECRET_KEY_BASE"]
    refute_equal "cookie-val", checkpoint["cookies"]["_app_session"]

    Dir.mktmpdir("irtrace-ruby-verify-") do |dir|
      file = File.join(dir, "clean.sqlite3")
      File.binwrite(file, clean_bytes)
      db = SQLite3::Database.new(file)
      db.results_as_hash = true
      assert_equal "ok", db.get_first_value("PRAGMA integrity_check")
      user = db.execute("SELECT * FROM users WHERE id = 'u-1'").first
      assert_equal "member", user["role"]
      assert_match(/\Aredacted-[0-9a-f]{12}@redacted\.invalid\z/, user["email"])
      outbox = JSON.parse(db.get_first_value("SELECT changes_payload FROM instant_record_outbox WHERE id = 'm-1'"))
      assert_equal user["email"], outbox["email"]
      assert_equal "member", outbox["role"]
      db.close
    end
  end

  def test_ruby_redactor_leaves_no_raw_pii_in_a_wal_mode_checkpoint_with_many_rows
    raw = build_sqlite_bytes do |db|
      db.execute("PRAGMA journal_mode = WAL")
      db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT)")
      db.transaction do
        600.times { |i| db.execute("INSERT INTO users (email) VALUES (?)", ["bob#{i}@private.example" + "x" * 200]) }
      end
      db.execute("DELETE FROM users WHERE id > 300")
    end
    assert_includes raw, "private.example".b

    clean = InstantRecord::Trace::Redactor.new(salt: "test").redact_database(raw)[:bytes]

    refute_includes clean, "private.example".b
    read_sqlite_bytes(clean) do |db|
      assert_equal "ok", db.get_first_value("PRAGMA integrity_check")
      assert_equal 0, db.get_first_value("PRAGMA freelist_count")
      assert_equal 300, db.get_first_value("SELECT count(*) FROM users WHERE email LIKE 'redacted-%' OR email LIKE '[redacted:%'")
    end
  end

  def test_ruby_redactor_raises_the_trigger_error_when_a_trigger_rolls_back
    raw = build_sqlite_bytes do |db|
      db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT)")
      db.execute("INSERT INTO users (email) VALUES ('bob@private.example')")
      db.execute("CREATE TRIGGER stop BEFORE UPDATE ON users BEGIN SELECT RAISE(ROLLBACK, 'users are frozen'); END")
    end

    error = assert_raises(SQLite3::ConstraintException) do
      InstantRecord::Trace::Redactor.new(salt: "test").redact_database(raw)
    end
    assert_match(/users are frozen/, error.message)
  end

  def test_ruby_redactor_commits_each_row_when_the_checkpoint_has_a_virtual_table
    redactor = InstantRecord::Trace::Redactor.new(salt: "test")
    emails = 5.times.map { |i| "bob#{i}@private.example" }
    build = lambda do |&after|
      build_sqlite_bytes do |db|
        db.execute("CREATE VIRTUAL TABLE docs USING fts5(email)")
        emails.each { |email| db.execute("INSERT INTO docs (email) VALUES (?)", [email]) }
        after&.call(db)
      end
    end
    expected = build.call do |db|
      emails.each.with_index(1) do |email, rowid|
        db.execute("UPDATE docs SET email = ? WHERE rowid = ?", [redactor.pseudonymize(email, "email"), rowid])
      end
    end

    clean = redactor.redact_database(build.call)[:bytes]

    index = ->(bytes) { read_sqlite_bytes(bytes) { |db| db.execute("SELECT id, hex(block) FROM docs_data ORDER BY id") } }
    assert_equal index.call(expected), index.call(clean)
  end

  def test_ruby_redactor_preserves_edge_cases_across_tables_indexes_outbox_and_metadata
    redactor = InstantRecord::Trace::Redactor.new(
      schema: { "users" => %w[id email phone full_name role] },
      salt: "edge-salt"
    )
    raw = build_sqlite_bytes do |db|
      db.execute("CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT, phone TEXT, full_name TEXT, role TEXT)")
      db.execute("CREATE INDEX idx_users_email ON users(email)")
      db.execute("CREATE TABLE empty_contacts (id INTEGER PRIMARY KEY, email TEXT, phone TEXT)")
      db.execute('CREATE TABLE "quoted ""table""" (id INTEGER PRIMARY KEY, "user""_email" TEXT, note TEXT)')
      db.execute("CREATE TABLE instant_record_outbox (id TEXT PRIMARY KEY, record_type TEXT, changes_payload TEXT)")
      db.execute("CREATE TABLE instant_record_sync_metadata (key TEXT PRIMARY KEY, value TEXT)")

      db.execute("INSERT INTO users VALUES ('u-1', 'alice@private.example', '+1-212-555-0100', 'Alice A', 'admin')")
      db.execute("INSERT INTO users VALUES ('u-2', '', NULL, 'alt@private.example', 'member')")
      db.execute("INSERT INTO users VALUES ('u-3', 'charlie@private.example', 'phone-mail@private.example', 'Charlie', 'member')")
      db.execute('INSERT INTO "quoted ""table""" VALUES (1, \'quoted@private.example\', \'safe\')')
      db.execute("INSERT INTO instant_record_outbox VALUES ('m-1', 'User', ?)", [JSON.generate("id" => "u-1", "email" => "alice@private.example", "role" => "admin")])
      db.execute("INSERT INTO instant_record_outbox VALUES ('m-2', 'User', ?)", [JSON.generate("id" => "u-2", "role" => "member")])
      db.execute("INSERT INTO instant_record_outbox VALUES ('m-3', 'User', 'not-json{')")
      db.execute("INSERT INTO instant_record_outbox VALUES ('m-4', NULL, '')")
      db.execute("INSERT INTO instant_record_sync_metadata VALUES ('identity', '')")
      db.execute("INSERT INTO instant_record_sync_metadata VALUES ('cursor', '7')")
    end

    result = redactor.redact_database(raw)
    clean = result[:bytes]

    assert_equal Encoding::BINARY, clean.encoding
    assert_equal Digest::SHA256.hexdigest(raw), result[:original_digest]
    assert_equal Digest::SHA256.hexdigest(clean), result[:digest]
    refute_includes clean, "private.example".b
    assert_equal(
      {
        "empty_contacts" => %w[email phone],
        "instant_record_outbox" => %w[changes_payload],
        'quoted "table"' => ['user"_email'],
        "users" => %w[email full_name phone]
      },
      result[:redacted_columns]
    )

    read_sqlite_bytes(clean) do |db|
      assert_equal "ok", db.get_first_value("PRAGMA integrity_check")
      assert_equal 0, db.get_first_value("PRAGMA freelist_count")
      assert_equal "delete", db.get_first_value("PRAGMA journal_mode")

      u1 = db.execute("SELECT email, phone, full_name, role FROM users WHERE id = 'u-1'").first
      assert_equal [
        redactor.pseudonymize("alice@private.example", "email"),
        redactor.pseudonymize("+1-212-555-0100", "phone"),
        redactor.pseudonymize("Alice A", "full_name"),
        "admin"
      ], u1

      u2 = db.execute("SELECT email, phone, full_name FROM users WHERE id = 'u-2'").first
      assert_equal ["", nil, redactor.pseudonymize("alt@private.example", "full_name")], u2
      assert_match(/\Aredacted-[0-9a-f]{12}@redacted\.invalid\z/, u2[2])

      u3_phone = db.get_first_value("SELECT phone FROM users WHERE id = 'u-3'")
      assert_equal redactor.pseudonymize("phone-mail@private.example", "phone"), u3_phone
      assert_match(/\Aredacted-[0-9a-f]{12}@redacted\.invalid\z/, u3_phone)

      quoted_val = db.get_first_value('SELECT "user""_email" FROM "quoted ""table""" WHERE id = 1')
      assert_equal redactor.pseudonymize("quoted@private.example", 'user"_email'), quoted_val

      assert_equal "not-json{", db.get_first_value("SELECT changes_payload FROM instant_record_outbox WHERE id = 'm-3'")
      assert_equal "", db.get_first_value("SELECT value FROM instant_record_sync_metadata WHERE key = 'identity'")
    end
  end

  def test_ruby_redactor_attributes_and_pseudonymize_handle_nested_overrides_and_types
    redactor = InstantRecord::Trace::Redactor.new(
      schema: { "users" => %w[id email phone role] },
      pii_columns: { "users" => ["custom_secret"], "*" => ["global_pii"] },
      safe_columns: { "users" => ["city"], "*" => ["safe_email"] },
      salt: "attr-salt"
    )

    attrs = {
      "id" => "u-1",
      "email" => "alice@private.example",
      "phone" => 555_1234,
      "city" => "Metropolis",
      "safe_email" => "keep-me",
      "bio" => "  padded@private.example  ",
      "custom_secret" => { "k" => "v" },
      "global_pii" => ["one", "", nil],
      "nested" => {
        "street" => "10 Main St",
        "items" => [{ "first_name" => "Bob", "role" => "member" }, "plain"]
      }
    }

    first = redactor.redact_attributes("User", attrs)
    second = redactor.redact_attributes(:users, attrs)
    assert_equal first, second

    assert_equal "u-1", first["id"]
    assert_equal redactor.pseudonymize("alice@private.example", "email"), first["email"]
    assert_equal redactor.pseudonymize(555_1234, "phone"), first["phone"]
    assert_match(/\A\+1-555-[0-9a-f]{4}\z/, first["phone"])
    assert_equal "Metropolis", first["city"]
    assert_equal "keep-me", first["safe_email"]
    assert_equal redactor.pseudonymize("padded@private.example", "email"), first["bio"]
    assert_equal redactor.pseudonymize(JSON.generate("k" => "v"), "custom_secret"), first["custom_secret"]
    assert_equal [redactor.pseudonymize("one", "global_pii"), "", nil], first["global_pii"]
    assert_equal redactor.pseudonymize("10 Main St", "street"), first["nested"]["street"]
    assert_equal redactor.pseudonymize("Bob", "first_name"), first["nested"]["items"][0]["first_name"]
    assert_equal "member", first["nested"]["items"][0]["role"]
    assert_equal "plain", first["nested"]["items"][1]
    assert_nil redactor.pseudonymize(nil, "email")
    assert_equal "", redactor.pseudonymize("", "email")
  end

  def test_replayer_runs_deterministic_node_replay_and_reproduces_wasm_trap
    Dir.mktmpdir("irtrace-replay-") do |dir|
      wasm_path = File.join(dir, "app-test.wasm")
      trace_path = File.join(dir, "fault.irtrace")
      File.binwrite(wasm_path, build_minimal_trapping_wasm)

      trace = {
        "format" => InstantRecord::Trace::FORMAT,
        "version" => InstantRecord::Trace::VERSION,
        "recordedAt" => "2026-11-21T22:00:00.000Z",
        "meta" => { "schemaVersion" => 1 },
        "checkpoint" => { "mode" => "empty", "digest" => nil, "data" => nil, "env" => {}, "cookies" => {} },
        "steps" => [
          {
            "seq" => 1,
            "at" => 1_732_255_200_000,
            "exportName" => "wasm_cursor",
            "input" => { "encoding" => "utf8", "data" => "" },
            "exchanges" => [],
            "outcome" => { "exit" => 0, "trapped" => false, "errors" => [], "events" => [], "fault" => nil }
          },
          {
            "seq" => 2,
            "at" => 1_732_255_200_100,
            "exportName" => "wasm_sync",
            "input" => { "encoding" => "utf8", "data" => "/instant_record" },
            "exchanges" => [],
            "outcome" => {
              "exit" => "trap: unreachable",
              "trapped" => true,
              "errors" => [],
              "events" => [],
              "fault" => { "kind" => "wasm_trap", "exportName" => "wasm_sync", "exit" => "trap: unreachable" }
            }
          }
        ]
      }
      File.write(trace_path, JSON.generate(trace))

      result = InstantRecord::Trace.replay(trace_path: trace_path, wasm_path: wasm_path, json: true)
      assert result.ok?, "expected replay to succeed: #{result.stderr}\n#{result.stdout}"
      assert_equal true, result.report["ok"]
      assert_equal true, result.report["reproducedFault"]
      assert_equal 0, result.report["mismatches"]
      assert_equal 2, result.report["executedSteps"]
      assert_equal true, result.report["steps"][1]["actual"]["trapped"]

      human = InstantRecord::Trace.replay(trace_path: trace_path, wasm_path: wasm_path, json: false)
      assert human.ok?, human.stderr
      assert_includes human.stdout, "FAULT REPRODUCED"
      assert_includes human.stdout, "recorded fault reproduced"
    end
  end

  def test_rake_task_instant_record_replay_runs_with_positional_and_bracket_args
    Dir.mktmpdir("irtrace-rake-") do |dir|
      wasm_path = File.join(dir, "app-test.wasm")
      trace_path = File.join(dir, "fault.irtrace")
      File.binwrite(wasm_path, build_minimal_trapping_wasm)
      File.write(trace_path, JSON.generate(
        "format" => InstantRecord::Trace::FORMAT,
        "version" => InstantRecord::Trace::VERSION,
        "checkpoint" => { "mode" => "empty", "digest" => nil, "data" => nil, "env" => {}, "cookies" => {} },
        "steps" => [
          {
            "seq" => 1,
            "exportName" => "wasm_cursor",
            "input" => { "encoding" => "utf8", "data" => "" },
            "exchanges" => [],
            "outcome" => { "exit" => 0, "trapped" => false, "errors" => [], "events" => [], "fault" => nil }
          }
        ]
      ))

      rake_file = File.expand_path("../lib/tasks/instant_record.rake", __dir__)
      script = <<~RUBY
        $LOAD_PATH.unshift(#{File.expand_path("../lib", __dir__).inspect})
        require "rake"
        require "pathname"
        require "active_support/lazy_load_hooks"
        require "instant_record"
        module Rails
          def self.root = Pathname(#{dir.inspect})
        end
        Rake::Task.define_task(:environment)
        load #{rake_file.inspect}
        Rake::Task["instant_record:replay"].invoke
      RUBY

      out, status = Open3.capture2e(
        RbConfig.ruby, "-e", script, "instant_record:replay", trace_path, "--wasm", wasm_path, "--json"
      )
      assert status.success?, "expected rake task to succeed:\n#{out}"
      parsed = JSON.parse(out)
      assert_equal true, parsed["ok"]
      assert_equal 1, parsed["executedSteps"]
    end
  end

  def test_client_and_notifier_stay_within_spinel_32_bit_integers
    %w[client.rb client/notifier.rb].each do |rel|
      source = File.read(File.expand_path("../lib/instant_record/#{rel}", __dir__), encoding: "UTF-8")
      refute_match(/\d{10,}/, source.gsub(/^\s*#.*$/, ""), "#{rel} contains an integer literal past 32 bits")
    end
  end

  def test_replayer_raises_trace_error_for_missing_trace_wasm_or_node_bin
    Dir.mktmpdir("irtrace-replayer-errors-") do |dir|
      trace_path = File.join(dir, "sample.irtrace")
      wasm_path = File.join(dir, "app-1.wasm")
      empty_gem_root = Pathname(File.join(dir, "empty_gem"))
      FileUtils.mkdir_p(empty_gem_root)

      missing_trace = assert_raises(InstantRecord::Trace::Error) do
        InstantRecord::Trace::Replayer.new(
          trace_path: File.join(dir, "missing.irtrace"),
          wasm_path: wasm_path
        ).run
      end
      assert_includes missing_trace.message, "Trace file not found"

      File.write(trace_path, "{}")

      missing_explicit_wasm = assert_raises(InstantRecord::Trace::Error) do
        InstantRecord::Trace::Replayer.new(
          trace_path: trace_path,
          wasm_path: File.join(dir, "missing.wasm")
        ).run
      end
      assert_includes missing_explicit_wasm.message, "Could not find a compiled app-*.wasm module"

      stub_singleton(InstantRecord::Trace::Replayer, :gem_root, -> { empty_gem_root }) do
        missing_discovered_wasm = assert_raises(InstantRecord::Trace::Error) do
          InstantRecord::Trace::Replayer.new(trace_path: trace_path, root: dir).run
        end
        assert_includes missing_discovered_wasm.message, "Could not find a compiled app-*.wasm module"
      end

      File.binwrite(wasm_path, "wasm")
      missing_node_bin = File.join(dir, "no-such-node")
      missing_node = assert_raises(InstantRecord::Trace::Error) do
        InstantRecord::Trace::Replayer.new(
          trace_path: trace_path,
          wasm_path: wasm_path,
          node_bin: missing_node_bin
        ).run
      end
      assert_includes missing_node.message, "Node executable not found"
      assert_includes missing_node.message, missing_node_bin
    end
  end

  def test_replayer_builds_cli_flags_and_parses_json_stdout_and_exit_status
    Dir.mktmpdir("irtrace-replayer-cli-") do |dir|
      trace_path = File.join(dir, "sample.irtrace")
      wasm_path = File.join(dir, "app-1.wasm")
      db_path = File.join(dir, "state.sqlite3")
      nm_dir = File.join(dir, "node_modules")
      empty_gem_root = Pathname(File.join(dir, "empty_gem"))
      File.write(trace_path, "{}")
      File.binwrite(wasm_path, "wasm")
      FileUtils.mkdir_p(nm_dir)
      FileUtils.mkdir_p(empty_gem_root)

      fake_status = Struct.new(:success?, :exitstatus)
      captured_cmds = []

      with_env("INSTANT_RECORD_WEB_NODE_MODULES", nil) do
        stub_singleton(InstantRecord::Trace::Replayer, :gem_root, -> { empty_gem_root }) do
          stub_singleton(Open3, :capture3, ->(*cmd) {
            captured_cmds << cmd
            ['{"ok":true,"executedSteps":3}', "", fake_status.new(true, 0)]
          }) do
            result = InstantRecord::Trace::Replayer.new(
              trace_path: trace_path,
              wasm_path: wasm_path,
              db_path: db_path,
              node_modules: [nm_dir],
              json: true,
              allow_digest_mismatch: true,
              stop_on_fault: true,
              max_steps: 7,
              node_bin: "/custom/node"
            ).run

            assert result.ok?
            assert_equal 0, result.status
            assert_equal({ "ok" => true, "executedSteps" => 3 }, result.report)
            assert_equal [
              "/custom/node",
              empty_gem_root.join("compiled/web/src/replay.js").to_s,
              File.expand_path(trace_path),
              "--wasm", File.expand_path(wasm_path),
              "--db", File.expand_path(db_path),
              "--node-modules", File.expand_path(nm_dir),
              "--json",
              "--allow-digest-mismatch",
              "--stop-on-fault",
              "--max-steps", "7"
            ], captured_cmds.last
          end

          stub_singleton(Open3, :capture3, ->(*cmd) {
            captured_cmds << cmd
            ["not-valid-json{", "replay error", fake_status.new(false, 2)]
          }) do
            result = InstantRecord::Trace::Replayer.new(
              trace_path: trace_path,
              wasm_path: wasm_path,
              json: true,
              node_bin: "/custom/node"
            ).run

            refute result.ok?
            assert_equal 2, result.status
            assert_equal "replay error", result.stderr
            assert_nil result.report
            assert_equal [
              "/custom/node",
              empty_gem_root.join("compiled/web/src/replay.js").to_s,
              File.expand_path(trace_path),
              "--wasm", File.expand_path(wasm_path),
              "--json"
            ], captured_cmds.last
          end

          stub_singleton(Open3, :capture3, ->(*_cmd) {
            ["   ", "killed by signal", fake_status.new(false, nil)]
          }) do
            result = InstantRecord::Trace::Replayer.new(
              trace_path: trace_path,
              wasm_path: wasm_path,
              json: true,
              node_bin: "/custom/node"
            ).run

            refute result.ok?
            assert_equal 1, result.status
            assert_nil result.report
          end

          stub_singleton(Open3, :capture3, ->(*_cmd) {
            ['{"ok":true}', "", fake_status.new(true, 0)]
          }) do
            result = InstantRecord::Trace::Replayer.new(
              trace_path: trace_path,
              wasm_path: wasm_path,
              json: false,
              node_bin: "/custom/node"
            ).run

            assert result.ok?
            assert_nil result.report
          end
        end
      end
    end
  end

  def test_replayer_discover_wasm_picks_newest_and_ignores_disappearing_files
    Dir.mktmpdir("irtrace-discover-wasm-") do |dir|
      root = File.join(dir, "app")
      tmp_dist = File.join(root, "tmp/instant_record/compiled/web/dist")
      pub_dist = File.join(root, "public/instant_record_compiled/current")
      gem_root = Pathname(File.join(dir, "gem"))
      gem_dist = gem_root.join("compiled/web/dist")
      FileUtils.mkdir_p([tmp_dist, pub_dist, gem_dist])

      trace_path = File.join(dir, "sample.irtrace")
      File.write(trace_path, "{}")

      older = File.join(tmp_dist, "app-older.wasm")
      newer = File.join(tmp_dist, "app-newer.wasm")
      vanishing = File.join(tmp_dist, "app-vanishing.wasm")
      pub_wasm = File.join(pub_dist, "app-public.wasm")
      gem_wasm = gem_dist.join("app-gem.wasm").to_s
      [older, newer, vanishing, pub_wasm, gem_wasm].each { |p| File.binwrite(p, "wasm") }

      now = Time.now
      File.utime(now - 60, now - 60, older)
      File.utime(now - 10, now - 10, newer)

      stub_singleton(InstantRecord::Trace::Replayer, :gem_root, -> { gem_root }) do
        orig_mtime = File.method(:mtime)
        wrapped_mtime = lambda do |path|
          if path == vanishing
            File.unlink(path) if File.exist?(path)
            raise Errno::ENOENT, path
          end
          orig_mtime.call(path)
        end

        stub_singleton(File, :mtime, wrapped_mtime) do
          replayer = InstantRecord::Trace::Replayer.new(trace_path: trace_path, root: root)
          assert_equal newer, replayer.instance_variable_get(:@wasm_path)
        end

        FileUtils.rm_rf(tmp_dist)
        replayer = InstantRecord::Trace::Replayer.new(trace_path: trace_path, root: root)
        assert_equal pub_wasm, replayer.instance_variable_get(:@wasm_path)

        FileUtils.rm_rf(pub_dist)
        replayer = InstantRecord::Trace::Replayer.new(trace_path: trace_path, root: root)
        assert_equal gem_wasm, replayer.instance_variable_get(:@wasm_path)

        FileUtils.rm_rf(gem_dist)
        replayer = InstantRecord::Trace::Replayer.new(trace_path: trace_path, root: root)
        assert_nil replayer.instance_variable_get(:@wasm_path)
      end
    end
  end

  def test_replayer_discover_node_modules_collects_and_deduplicates_sources
    Dir.mktmpdir("irtrace-discover-nm-") do |dir|
      root = File.join(dir, "app")
      explicit_nm = File.join(dir, "explicit_nm")
      env_nm = File.join(dir, "env_nm")
      staged_nm = File.join(root, "tmp/instant_record/compiled/web/node_modules")
      toolchain_nm = File.join(dir, "toolchain_nm")
      gem_root = Pathname(File.join(dir, "gem"))
      gem_nm = gem_root.join("compiled/web/node_modules").to_s
      FileUtils.mkdir_p([explicit_nm, env_nm, staged_nm, toolchain_nm, gem_nm])

      toolchain_file = File.join(dir, "toolchain.env")
      File.write(toolchain_file, "WEB_NODE_MODULES=#{toolchain_nm}\n")
      trace_path = File.join(dir, "sample.irtrace")
      wasm_path = File.join(dir, "app.wasm")
      File.write(trace_path, "{}")
      File.binwrite(wasm_path, "wasm")

      with_env("INSTANT_RECORD_WEB_NODE_MODULES", env_nm) do
        stub_singleton(InstantRecord::Trace::Replayer, :gem_root, -> { gem_root }) do
          replayer = InstantRecord::Trace::Replayer.new(
            trace_path: trace_path,
            wasm_path: wasm_path,
            root: root,
            toolchain: toolchain_file,
            node_modules: [explicit_nm, File.join(dir, "missing_nm"), env_nm]
          )

          assert_equal [
            File.expand_path(explicit_nm),
            File.expand_path(env_nm),
            File.expand_path(staged_nm),
            File.expand_path(toolchain_nm),
            File.expand_path(gem_nm)
          ], replayer.instance_variable_get(:@node_modules)
        end
      end
    end
  end

  private

  def stub_singleton(target, method_name, replacement)
    singleton = target.singleton_class
    had_own = singleton.method_defined?(method_name, false)
    original = target.method(method_name)
    singleton.remove_method(method_name) if had_own
    singleton.define_method(method_name) { |*args, **kwargs, &block| replacement.call(*args, **kwargs, &block) }
    yield
  ensure
    singleton.remove_method(method_name) if singleton.method_defined?(method_name, false)
    singleton.define_method(method_name, original) if had_own
  end

  def with_env(key, value)
    had_key = ENV.key?(key)
    previous = ENV[key]
    value.nil? ? ENV.delete(key) : ENV[key] = value
    yield
  ensure
    had_key ? ENV[key] = previous : ENV.delete(key)
  end

  def build_sample_sqlite_bytes
    Dir.mktmpdir("irtrace-src-") do |dir|
      file = File.join(dir, "src.sqlite3")
      db = SQLite3::Database.new(file)
      db.execute("CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT, phone TEXT, role TEXT, created_at TEXT)")
      db.execute("CREATE TABLE instant_record_outbox (id TEXT PRIMARY KEY, record_type TEXT, changes_payload TEXT)")
      db.execute("CREATE TABLE instant_record_sync_metadata (key TEXT PRIMARY KEY, value TEXT)")
      db.execute("INSERT INTO users VALUES ('u-1', 'bob@private.example', '+1-212-555-0144', 'member', '2026-11-21T00:00:00Z')")
      db.execute(
        "INSERT INTO instant_record_outbox VALUES ('m-1', 'User', ?)",
        [JSON.generate("id" => "u-1", "email" => "bob@private.example", "role" => "member")]
      )
      db.execute("INSERT INTO instant_record_sync_metadata VALUES ('identity', 'bob@private.example')")
      db.close
      File.binread(file)
    end
  end

  def build_sqlite_bytes
    Dir.mktmpdir("irtrace-src-") do |dir|
      file = File.join(dir, "src.sqlite3")
      db = SQLite3::Database.new(file)
      yield db
      db.close
      File.binread(file)
    end
  end

  def read_sqlite_bytes(bytes)
    Dir.mktmpdir("irtrace-ruby-verify-") do |dir|
      file = File.join(dir, "clean.sqlite3")
      File.binwrite(file, bytes)
      db = SQLite3::Database.new(file)
      yield db
    ensure
      db&.close
    end
  end

  # Minimal valid WebAssembly 1.0 reactor binary exporting:
  #   memory (1 page), wasm_boot() -> (), wasm_cursor() -> 0, wasm_sync() -> unreachable trap.
  def build_minimal_trapping_wasm
    section = ->(id, payload) { [id, payload.length, *payload] }
    export_entry = ->(name, kind, idx) { [name.bytesize, *name.bytes, kind, idx] }

    types = [0x02, 0x60, 0x00, 0x00, 0x60, 0x00, 0x01, 0x7f]
    funcs = [0x03, 0x00, 0x01, 0x01]
    memory = [0x01, 0x00, 0x01]
    exports = [
      0x04,
      *export_entry.call("memory", 0x02, 0x00),
      *export_entry.call("wasm_boot", 0x00, 0x00),
      *export_entry.call("wasm_cursor", 0x00, 0x01),
      *export_entry.call("wasm_sync", 0x00, 0x02)
    ]
    code = [
      0x03,
      0x02, 0x00, 0x0b,
      0x04, 0x00, 0x41, 0x00, 0x0b,
      0x03, 0x00, 0x00, 0x0b
    ]

    (
      [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00] +
      section.call(1, types) +
      section.call(3, funcs) +
      section.call(5, memory) +
      section.call(7, exports) +
      section.call(10, code)
    ).pack("C*")
  end
end
