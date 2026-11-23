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

  private

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
