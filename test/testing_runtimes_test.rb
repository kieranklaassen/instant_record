require "test_helper"
require "instant_record/testing"
require "rbconfig"
require "tmpdir"

class TestingRuntimesTest < Minitest::Test
  class DummyBridgeRuntime
    include InstantRecord::Testing::Runtimes::Base
    include InstantRecord::Testing::Runtimes::StdioBridge

    attr_reader :stdin, :stdout, :stderr, :wait_thr

    def initialize(network:, name: :dummy)
      @network = network
      @name = name
    end

    def name = @name

    def start(*command, label: "Dummy")
      start_bridge!(*command, label: label)
    end

    def call_rpc(payload)
      rpc(payload)
    end

    def call_clean_rpc(op, client_id, **kwargs)
      clean_rpc(op, client_id, **kwargs)
    end

    def shutdown(cleanup_dir: nil)
      close_bridge(cleanup_dir: cleanup_dir)
    end
  end

  class RecordingRuntime
    attr_reader :name, :calls

    def initialize(name:, bytes: "sqlite-bytes")
      @name = name
      @bytes = bytes
      @calls = []
    end

    def execute_request(client, method, path, body:, content_type:)
      @calls << [:execute_request, client, method, path, body, content_type]
      :request_result
    end

    def execute_sync(client, endpoint)
      @calls << [:execute_sync, client, endpoint]
      :sync_result
    end

    def execute_sync_pass_only(client, endpoint)
      @calls << [:execute_sync_pass_only, client, endpoint]
      :sync_pass_only_result
    end

    def execute_sync_plan(client)
      @calls << [:execute_sync_plan, client]
      :sync_plan_result
    end

    def execute_consume_stream(client, chunk)
      @calls << [:execute_consume_stream, client, chunk]
      :consume_stream_result
    end

    def execute_sync_state(client)
      @calls << [:execute_sync_state, client]
      :sync_state_result
    end

    def execute_history(client, key, response)
      @calls << [:execute_history, client, key, response]
      :history_result
    end

    def execute_local_write(client, model:, operation:, id:, attributes:)
      @calls << [:execute_local_write, client, model, operation, id, attributes]
      :local_write_result
    end

    def execute_verify_frontend_http(client)
      @calls << [:execute_verify_frontend_http, client]
      :verify_frontend_http_result
    end

    def database_bytes(client)
      @calls << [:database_bytes, client]
      @bytes
    end

    def read_sqlite_file_state(db_path, model_names:)
      @calls << [:read_sqlite_file_state, db_path, model_names]
      :file_state_result
    end

    def read_sqlite_bytes_state(bytes, model_names:)
      @calls << [:read_sqlite_bytes_state, bytes, model_names]
      :bytes_state_result
    end
  end

  def ruby_bridge_cmd(code)
    [RbConfig.ruby, "-rjson", "-e", "$stdout.sync = true\n#{code}"]
  end

  def test_stdio_bridge_startup_failure_reports_stderr_and_closes_io
    bridge = DummyBridgeRuntime.new(network: nil)
    cmd = ruby_bridge_cmd('$stderr.puts("startup boom"); exit 1')

    err = assert_raises(InstantRecord::Testing::Error) do
      bridge.start(*cmd, label: "CRuby")
    end

    assert_includes err.message, "CRuby bridge failed to start: nil"
    assert_includes err.message, "startup boom"
    assert bridge.stdin.closed?
    assert bridge.stdout.closed?
    assert bridge.stderr.closed?
  end

  def test_stdio_bridge_startup_rejects_non_ready_message
    bridge = DummyBridgeRuntime.new(network: nil)
    cmd = ruby_bridge_cmd('puts JSON.generate(type: "not_ready")')

    err = assert_raises(InstantRecord::Testing::Error) do
      bridge.start(*cmd, label: "Wasm")
    end

    assert_includes err.message, "Wasm bridge failed to start:"
    assert_includes err.message, "not_ready"
    assert bridge.stdin.closed?
  end

  def test_stdio_bridge_terminates_hung_child_on_startup_failure_and_does_not_wait_twice
    Dir.mktmpdir("ir-stdio-hung") do |dir|
      pid_file = File.join(dir, "child.pid")
      bridge = DummyBridgeRuntime.new(network: nil)
      cmd = ruby_bridge_cmd(<<~RUBY)
        File.write(#{pid_file.inspect}, Process.pid.to_s)
        puts JSON.generate(type: "not_ready")
        sleep 60
      RUBY

      assert_raises(InstantRecord::Testing::Error) do
        bridge.start(*cmd, label: "Wasm")
      end

      pid = File.read(pid_file).to_i
      assert_nil bridge.wait_thr
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      bridge.shutdown
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator elapsed, :<, 0.5, "follow-up shutdown should not wait a second time"
    end
  end

  def test_stdio_bridge_escalates_to_sigkill_when_child_ignores_sigterm
    Dir.mktmpdir("ir-stdio-kill") do |dir|
      pid_file = File.join(dir, "child.pid")
      bridge = DummyBridgeRuntime.new(network: nil)
      cmd = ruby_bridge_cmd(<<~RUBY)
        Signal.trap("TERM", "IGNORE")
        File.write(#{pid_file.inspect}, Process.pid.to_s)
        puts JSON.generate(type: "not_ready")
        sleep 60
      RUBY

      assert_raises(InstantRecord::Testing::Error) do
        bridge.start(*cmd, label: "Wasm")
      end

      pid = File.read(pid_file).to_i
      assert_nil bridge.wait_thr
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    end
  end

  def test_cruby_runtime_removes_tmpdir_when_bridge_startup_fails
    captured_tmpdir = nil
    failing_runtime = Class.new(InstantRecord::Testing::Runtimes::CRubyRuntime) do
      define_method(:start_bridge!) do |*_, **_|
        captured_tmpdir = @tmpdir
        raise InstantRecord::Testing::Error, "simulated startup failure"
      end
    end

    err = assert_raises(InstantRecord::Testing::Error) do
      failing_runtime.new(network: nil, server: nil)
    end

    assert_equal "simulated startup failure", err.message
    refute_nil captured_tmpdir
    refute Dir.exist?(captured_tmpdir), "CRubyRuntime#initialize must clean up @tmpdir on startup failure"
  ensure
    FileUtils.remove_entry(captured_tmpdir) if captured_tmpdir && Dir.exist?(captured_tmpdir)
  end

  def test_wasm_runtime_removes_stage_dir_when_bridge_startup_fails
    captured_stage_dir = nil
    failing_runtime = Class.new(InstantRecord::Testing::Runtimes::WasmRuntime) do
      define_method(:prepare_app_host_path) do
        @stage_dir = Dir.mktmpdir("ir-wasm-stage-fail")
        captured_stage_dir = @stage_dir
        File.join(@stage_dir, "app-host.js")
      end

      define_method(:start_bridge!) do |*_, **_|
        raise InstantRecord::Testing::Error, "simulated wasm startup failure"
      end
    end

    err = assert_raises(InstantRecord::Testing::Error) do
      failing_runtime.new(wasm_path: "/tmp/app.wasm", web_node_modules: "/tmp/node_modules", network: nil)
    end

    assert_equal "simulated wasm startup failure", err.message
    refute_nil captured_stage_dir
    refute Dir.exist?(captured_stage_dir), "WasmRuntime#initialize must clean up @stage_dir on startup failure"
  ensure
    FileUtils.remove_entry(captured_stage_dir) if captured_stage_dir && Dir.exist?(captured_stage_dir)
  end

  def test_stdio_bridge_exchange_round_trip_and_graceful_shutdown_with_cleanup
    exchanges = []
    network = Object.new
    network.define_singleton_method(:exchange) do |client, method, url, body|
      exchanges << [client, method, url, body]
      { status: 200, body: "reply-for-#{url}" }
    end

    cleanup_dir = Dir.mktmpdir("ir-stdio-bridge-clean")
    bridge = DummyBridgeRuntime.new(network: network)
    cmd = ruby_bridge_cmd(<<~RUBY)
      puts JSON.generate(type: "ready")
      while (line = $stdin.gets)
        cmd = JSON.parse(line)
        case cmd["op"]
        when "sync"
          puts JSON.generate(type: "exchange", client: cmd["client"], method: "POST", url: "/mutations", body: '{"a":1}')
          reply1 = JSON.parse($stdin.gets)
          puts JSON.generate(type: "exchange", client: cmd["client"], method: "GET", url: "/bootstrap", body: "")
          reply2 = JSON.parse($stdin.gets)
          puts JSON.generate(type: "result", replies: [reply1, reply2], errors: [])
        when "shutdown"
          puts JSON.generate(type: "result", ok: true)
          break
        end
      end
    RUBY

    bridge.start(*cmd, label: "CRuby")
    res = bridge.call_rpc({ op: "sync", client: "c1" })

    assert_equal [
      ["c1", "POST", "/mutations", '{"a":1}'],
      ["c1", "GET", "/bootstrap", ""]
    ], exchanges
    assert_equal [
      { "status" => 200, "body" => "reply-for-/mutations" },
      { "status" => 200, "body" => "reply-for-/bootstrap" }
    ], res["replies"]

    bridge.shutdown(cleanup_dir: cleanup_dir)
    assert bridge.stdin.closed?
    assert bridge.stdout.closed?
    assert bridge.stderr.closed?
    refute Dir.exist?(cleanup_dir)
  ensure
    bridge&.shutdown(cleanup_dir: cleanup_dir)
    FileUtils.remove_entry(cleanup_dir) if cleanup_dir && Dir.exist?(cleanup_dir)
  end

  def test_stdio_bridge_error_reply_unexpected_message_and_unexpected_eof
    bridge = DummyBridgeRuntime.new(network: nil)
    cmd = ruby_bridge_cmd(<<~RUBY)
      puts JSON.generate(type: "ready")
      while (line = $stdin.gets)
        cmd = JSON.parse(line)
        case cmd["op"]
        when "fail"
          puts JSON.generate(type: "error", message: "bad op")
        when "weird"
          puts JSON.generate(type: "mystery", value: 42)
        when "crash"
          $stderr.puts("fatal bridge crash")
          exit 2
        end
      end
    RUBY

    bridge.start(*cmd, label: "Wasm")

    err = assert_raises(InstantRecord::Testing::Error) { bridge.call_rpc({ op: "fail" }) }
    assert_equal "Wasm bridge error during fail: bad op", err.message

    unexpected = assert_raises(InstantRecord::Testing::Error) { bridge.call_rpc({ op: "weird" }) }
    assert_includes unexpected.message, "Unexpected Wasm bridge message:"
    assert_includes unexpected.message, "mystery"

    eof = assert_raises(InstantRecord::Testing::Error) { bridge.call_rpc({ op: "crash" }) }
    assert_includes eof.message, "Wasm bridge exited unexpectedly during crash:"
    assert_includes eof.message, "fatal bridge crash"
  ensure
    bridge&.shutdown
  end

  def test_stdio_bridge_close_cleans_up_dir_even_when_shutdown_rpc_fails
    cleanup_dir = Dir.mktmpdir("ir-stdio-bridge-err")
    bridge = DummyBridgeRuntime.new(network: nil)
    cmd = ruby_bridge_cmd(<<~RUBY)
      puts JSON.generate(type: "ready")
      $stdin.gets
      exit 1
    RUBY

    bridge.start(*cmd, label: "CRuby")
    bridge.shutdown(cleanup_dir: cleanup_dir)

    assert bridge.stdin.closed?
    assert bridge.stdout.closed?
    assert bridge.stderr.closed?
    refute Dir.exist?(cleanup_dir), "cleanup_dir must be removed even if shutdown RPC raises"
  ensure
    FileUtils.remove_entry(cleanup_dir) if cleanup_dir && Dir.exist?(cleanup_dir)
  end

  def test_stdio_bridge_clean_rpc_enforces_clean_stderr
    bridge = DummyBridgeRuntime.new(network: nil, name: :cruby)
    cmd = ruby_bridge_cmd(<<~RUBY)
      puts JSON.generate(type: "ready")
      while (line = $stdin.gets)
        cmd = JSON.parse(line)
        case cmd["op"]
        when "ok_op"
          puts JSON.generate(type: "result", ok: true, payload: cmd["extra"], errors: [])
        when "noisy_op"
          puts JSON.generate(type: "result", ok: true, errors: ["RangeError: overflow"])
        when "shutdown"
          puts JSON.generate(type: "result", ok: true)
          break
        end
      end
    RUBY

    bridge.start(*cmd, label: "CRuby")

    ok = bridge.call_clean_rpc("ok_op", "c1", extra: 7)
    assert_equal 7, ok["payload"]

    err = assert_raises(InstantRecord::Testing::StderrError) do
      bridge.call_clean_rpc("noisy_op", "c1")
    end
    assert_includes err.message, "Unexpected stderr during cruby noisy_op(c1):"
    assert_includes err.message, "RangeError: overflow"

    custom = assert_raises(InstantRecord::Testing::StderrError) do
      bridge.call_clean_rpc("noisy_op", "c1", context: "boot(c1)")
    end
    assert_includes custom.message, "Unexpected stderr during cruby boot(c1):"
  ensure
    bridge&.shutdown
  end

  def test_client_handle_shared_delegation_parity_across_all_three_runtimes
    specs = [
      [InstantRecord::Testing::Runtimes::CRubyRuntime::ClientHandle, :cruby, { db_path: "/tmp/cruby.sqlite3" }],
      [InstantRecord::Testing::Runtimes::WasmRuntime::ClientHandle, :wasm, {}],
      [InstantRecord::Testing::Runtimes::NativeRuntime::ClientHandle, :native, { db_path: "/tmp/native.sqlite3" }]
    ]

    specs.each do |handle_class, expected_name, extra_kwargs|
      assert_operator handle_class, :<, InstantRecord::Testing::Runtimes::ClientHandle

      runtime = RecordingRuntime.new(name: expected_name)
      handle = handle_class.new(id: :client_1, runtime: runtime, **extra_kwargs)

      assert_equal "client_1", handle.id
      assert_same runtime, handle.runtime
      assert_equal expected_name, handle.runtime_name

      assert_equal :request_result, handle.request("GET", "/todo")
      assert_equal :request_result, handle.request("POST", "/todo/issues", body: "a=1", content_type: "application/json")
      assert_equal :sync_result, handle.sync
      assert_equal :sync_result, handle.sync("/custom")
      assert_equal :sync_plan_result, handle.sync_plan
      assert_equal :consume_stream_result, handle.consume_stream("data: {}\n\n")
      assert_equal :sync_state_result, handle.sync_state
      assert_equal :history_result, handle.history("k1")
      assert_equal :history_result, handle.history("k1", '{"records":[]}')
      assert_equal :local_write_result, handle.local_write(model: "Issue", operation: "create")
      assert_equal :local_write_result, handle.local_write(model: "Issue", operation: "update", id: "i1", attributes: { state: "done" })

      assert_equal [
        [:execute_request, handle, "GET", "/todo", "", "application/x-www-form-urlencoded"],
        [:execute_request, handle, "POST", "/todo/issues", "a=1", "application/json"],
        [:execute_sync, handle, InstantRecord::DEFAULT_MOUNT_PATH],
        [:execute_sync, handle, "/custom"],
        [:execute_sync_plan, handle],
        [:execute_consume_stream, handle, "data: {}\n\n"],
        [:execute_sync_state, handle],
        [:execute_history, handle, "k1", ""],
        [:execute_history, handle, "k1", '{"records":[]}'],
        [:execute_local_write, handle, "Issue", "create", nil, {}],
        [:execute_local_write, handle, "Issue", "update", "i1", { state: "done" }]
      ], runtime.calls
    end
  end

  def test_client_handle_target_specific_attributes_and_methods
    cruby_rt = RecordingRuntime.new(name: :cruby)
    cruby = InstantRecord::Testing::Runtimes::CRubyRuntime::ClientHandle.new(
      id: "c1", runtime: cruby_rt, db_path: "/tmp/c1.sqlite3"
    )
    assert_equal "/tmp/c1.sqlite3", cruby.db_path
    assert_equal :file_state_result, cruby.snapshot_state(model_names: %w[Issue])
    assert_equal [[:read_sqlite_file_state, "/tmp/c1.sqlite3", %w[Issue]]], cruby_rt.calls

    wasm_rt = RecordingRuntime.new(name: :wasm, bytes: "wasm-db-bytes")
    wasm = InstantRecord::Testing::Runtimes::WasmRuntime::ClientHandle.new(id: "w1", runtime: wasm_rt)
    refute_respond_to wasm, :db_path
    refute_respond_to wasm, :cookies
    assert_equal :sync_pass_only_result, wasm.sync_pass_only
    assert_equal :sync_pass_only_result, wasm.sync_pass_only("/alt")
    assert_equal :verify_frontend_http_result, wasm.verify_frontend_http
    assert_equal :bytes_state_result, wasm.snapshot_state(model_names: %w[Issue AuthNote])
    assert_equal [
      [:execute_sync_pass_only, wasm, InstantRecord::DEFAULT_MOUNT_PATH],
      [:execute_sync_pass_only, wasm, "/alt"],
      [:execute_verify_frontend_http, wasm],
      [:database_bytes, wasm],
      [:read_sqlite_bytes_state, "wasm-db-bytes", %w[Issue AuthNote]]
    ], wasm_rt.calls

    native_rt = RecordingRuntime.new(name: :native)
    native = InstantRecord::Testing::Runtimes::NativeRuntime::ClientHandle.new(
      id: "n1", runtime: native_rt, db_path: "/tmp/n1.sqlite3"
    )
    assert_equal "/tmp/n1.sqlite3", native.db_path
    assert_equal({}, native.cookies)
    native.cookies["sid"] = "abc"
    assert_equal({ "sid" => "abc" }, native.cookies)
    assert_equal :file_state_result, native.snapshot_state(model_names: %w[AuthNote])
    assert_equal [[:read_sqlite_file_state, "/tmp/n1.sqlite3", %w[AuthNote]]], native_rt.calls
  end
end
