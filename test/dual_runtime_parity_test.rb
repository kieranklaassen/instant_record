require "test_helper"
require "instant_record/testing"
require "stringio"

class DualRuntimeParityTest < Minitest::Test
  class StubBase
    include InstantRecord::Testing::Runtimes::Base
  end

  def setup
    reset_instant_record_tables!
    @saved_synced = InstantRecord.synced_models.dup
    @saved_scope_from = InstantRecord.config.scope_from
  end

  def teardown
    InstantRecord.sync(*@saved_synced)
    InstantRecord.config.scope_from = @saved_scope_from
  end

  def test_canonical_timestamp_normalizes_postgres_and_sqlite_formats_bit_for_bit
    pg_style = "2026-11-21 22:04:08.123456"
    iso_style = "2026-11-21T22:04:08.123456Z"
    time_obj = Time.utc(2026, 11, 21, 22, 4, 8, 123_456)

    expected = "2026-11-21T22:04:08.123456Z"
    assert_equal expected, InstantRecord::Testing.canonical_timestamp(pg_style)
    assert_equal expected, InstantRecord::Testing.canonical_timestamp(iso_style)
    assert_equal expected, InstantRecord::Testing.canonical_timestamp(time_obj)
  end

  def test_canonical_rows_sorts_deterministically_and_excludes_sync_state
    rows_a = [
      { "id" => "b", "title" => "Two", "server_version" => "2", "sync_state" => "pending", "updated_at" => "2026-11-21 10:00:00.000001" },
      { "id" => "a", "title" => "One", "server_version" => 1, "sync_state" => "synced", "updated_at" => "2026-11-21T10:00:00.000000Z" }
    ]
    rows_b = [
      { id: "a", updated_at: Time.utc(2026, 11, 21, 10, 0, 0, 0), title: "One", server_version: 1, sync_state: "synced" },
      { id: "b", updated_at: "2026-11-21T10:00:00.000001Z", title: "Two", server_version: 2, sync_state: "synced" }
    ]

    assert_equal(
      InstantRecord::Testing.canonical_json(InstantRecord::Testing.canonical_rows(rows_a)),
      InstantRecord::Testing.canonical_json(InstantRecord::Testing.canonical_rows(rows_b))
    )
  end

  def test_strict_stderr_assertion_rejects_any_unexpected_wasi_error
    helper = StubBase.new

    # Clean stderr passes.
    helper.assert_clean_stderr!([], context: "clean")
    helper.assert_clean_stderr!(["", "   "], context: "blank")

    # Any stderr line fails when no network fault was injected.
    err = assert_raises(InstantRecord::Testing::StderrError) do
      helper.assert_clean_stderr!(["RangeError: integer overflow in *"], context: "wasm sync")
    end
    assert_includes err.message, "RangeError: integer overflow in *"

    # Expected offline warning is permitted ONLY when allow_offline_warning: true.
    offline_line = "[instant_record] bootstrap failed (offline?): GET /bootstrap -> 0"
    assert_raises(InstantRecord::Testing::StderrError) do
      helper.assert_clean_stderr!([offline_line], context: "online sync", allow_offline_warning: false)
    end
    helper.assert_clean_stderr!([offline_line], context: "offline sync", allow_offline_warning: true)

    # Even when offline fault was injected, a RangeError or crash MUST still fail.
    assert_raises(InstantRecord::Testing::StderrError) do
      helper.assert_clean_stderr!([offline_line, "RangeError: integer overflow in *"], context: "offline sync", allow_offline_warning: true)
    end
  end

  def test_fault_network_applies_partitions_bootstrap_aborts_and_clock_skew
    fake_server = Object.new
    received = []
    fake_server.define_singleton_method(:exchange) do |method, url, body, identity: nil|
      received << { method: method, url: url, body: body, identity: identity }
      { status: 200, body: '{"ok":true}' }
    end

    net = InstantRecord::Testing::FaultNetwork.new(fake_server)
    net.register_client("c1", identity: "ada", clock_skew: 60.0)

    # One-shot truncated bootstrap abort fires once then clears.
    net.arm_bootstrap_abort("c1", :truncated_body)
    res, fault = net.track_faults { net.exchange("c1", "GET", "/instant_record/bootstrap", "") }
    assert fault
    assert_equal 200, res[:status]
    assert_raises(JSON::ParserError) { JSON.parse(res[:body]) }

    res2, fault2 = net.track_faults { net.exchange("c1", "GET", "/instant_record/bootstrap", "") }
    refute fault2
    assert_equal 200, res2[:status]
    assert_equal "ada", received.last[:identity]

    # Per-client clock skew is tracked on the policy for local writes.
    assert_equal 60.0, net.policy("c1").clock_skew
    net.set_clock_skew("c1", -120.0)
    assert_equal(-120.0, net.policy("c1").clock_skew)

    # drop_after_apply commits on server, then returns status 0 to client and resets to :online.
    payload = JSON.generate(mutations: [{ id: "m1", changes: { title: "hello" } }])
    before_count = received.size
    net.set_partition("c1", :drop_after_apply)
    dropped, dropped_fault = net.track_faults { net.exchange("c1", "POST", "/instant_record/mutations", payload) }
    assert dropped_fault
    assert_equal 0, dropped[:status]
    assert_equal before_count + 1, received.size, "server must have received the POST before response drop"
    assert_equal :online, net.policy("c1").partition
  end

  def test_worker_fetch_wraps_truncated_json_as_transport_error
    transport = InstantRecord::Client::Transport::WorkerFetch.new
    transport.define_singleton_method(:exchange) { |_method, _path, _body| '{"cursor":1,"records":[{"broken' }

    assert_raises(InstantRecord::Client::Transport::Error) do
      transport.get_json("/bootstrap")
    end
    assert_raises(InstantRecord::Client::Transport::Error) do
      transport.post_json("/mutations", { mutations: [] })
    end
  end

  def test_select_runtimes_fails_fast_when_compiled_required_but_missing
    missing = InstantRecord::Testing::Artifacts.new(
      wasm_path: nil,
      native_lib_path: nil,
      toolchain_path: nil,
      web_node_modules: nil
    )

    assert_equal [:cruby], InstantRecord::Testing.select_runtimes(artifacts: missing, require_compiled: false)
    assert_raises(InstantRecord::Testing::Error) do
      InstantRecord::Testing.select_runtimes(artifacts: missing, require_compiled: true)
    end
  end

  def test_parity_suite_passes_end_to_end_on_cruby
    io = StringIO.new
    result = InstantRecord::Testing.verify_parity(runtimes: "cruby", out: io)

    assert result[:ok], io.string
    assert_equal [:cruby], result[:runtimes]
    assert_operator result[:scenarios].size, :>=, 7
    assert_includes io.string, "[PASS] int32_boundary_values"
    assert_includes io.string, "[PASS] identity_scoping_switch_and_reset"
    assert_includes io.string, "[PASS] mid_bootstrap_abort_and_idempotent_retry"
  end
end
