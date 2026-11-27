require "test_helper"
require "instant_record/testing"
require "stringio"

class TestingDriverLifecycleTest < Minitest::Test
  FakeDriver = Struct.new(:name, :closed, :raise_on_close, keyword_init: true) do
    def close
      self.closed = true
      raise raise_on_close if raise_on_close
    end
  end

  FakeServer = Struct.new(:closed, keyword_init: true) do
    def close
      self.closed = true
    end
  end

  def fake_artifacts(native_lib_path: nil)
    InstantRecord::Testing::Artifacts.new(
      wasm_path: "/tmp/fake.wasm",
      native_lib_path: native_lib_path,
      toolchain_path: nil,
      web_node_modules: "/tmp/node_modules"
    )
  end

  def with_stubs(stubs)
    originals = stubs.map do |target, method_name, replacement|
      singleton = target.singleton_class
      original = singleton.instance_method(method_name)
      singleton.define_method(method_name, &replacement)
      [singleton, method_name, original]
    end
    yield
  ensure
    originals&.reverse_each do |singleton, method_name, original|
      singleton.define_method(method_name, original)
    end
  end

  def test_shared_models_and_endpoint_constants_match_testing_defaults
    assert_equal %w[Issue AuthNote], InstantRecord::Testing::DEFAULT_MODELS
    assert InstantRecord::Testing::DEFAULT_MODELS.frozen?
    assert_equal InstantRecord::Testing::DEFAULT_MODELS, InstantRecord::Testing::ParitySuite::MODELS
    assert_equal InstantRecord::Testing::DEFAULT_MODELS, InstantRecord::Testing::ChaosSimulator::MODELS

    assert_equal InstantRecord::DEFAULT_MOUNT_PATH, InstantRecord::Testing::DEFAULT_ENDPOINT
    assert_equal InstantRecord::Testing::DEFAULT_ENDPOINT, InstantRecord::Testing::ParitySuite::ENDPOINT
    assert_equal InstantRecord::Testing::DEFAULT_ENDPOINT, InstantRecord::Testing::ChaosSimulator::ENDPOINT
  end

  def test_build_drivers_constructs_each_requested_runtime_and_rejects_unknown
    artifacts = fake_artifacts(native_lib_path: "/tmp/libfake.dylib")
    server = FakeServer.new(closed: false)
    network = InstantRecord::Testing::FaultNetwork.new(server)
    recorded = {}
    cruby_creations = 0

    with_stubs([
      [InstantRecord::Testing::Runtimes::CRubyRuntime, :new, ->(**kwargs) {
        cruby_creations += 1
        recorded[:cruby] = kwargs
        FakeDriver.new(name: :cruby, closed: false)
      }],
      [InstantRecord::Testing::Runtimes::WasmRuntime, :new, ->(**kwargs) {
        recorded[:wasm] = kwargs
        FakeDriver.new(name: :wasm, closed: false)
      }],
      [InstantRecord::Testing::Runtimes::NativeRuntime, :new, ->(**kwargs) {
        recorded[:native] = kwargs
        FakeDriver.new(name: :native, closed: false)
      }]
    ]) do
      drivers = InstantRecord::Testing.build_drivers(
        runtime_names: [:cruby, "cruby", :wasm, :native],
        artifacts: artifacts,
        network: network,
        server: server
      )

      assert_equal %i[cruby wasm native], drivers.keys
      assert_equal 1, cruby_creations
      assert_equal({ network: network, server: server, model_names: %w[Issue AuthNote] }, recorded[:cruby])
      assert_equal({ wasm_path: "/tmp/fake.wasm", web_node_modules: "/tmp/node_modules", network: network }, recorded[:wasm])
      assert_equal({ lib_path: "/tmp/libfake.dylib", network: network }, recorded[:native])
    end

    err = assert_raises(ArgumentError) do
      InstantRecord::Testing.build_drivers(
        runtime_names: [:bogus],
        artifacts: artifacts,
        network: network,
        server: server
      )
    end
    assert_includes err.message, ":bogus"
  end

  def test_build_drivers_closes_earlier_drivers_when_a_later_runtime_raises
    server = FakeServer.new(closed: false)
    network = InstantRecord::Testing::FaultNetwork.new(server)
    cruby_driver = FakeDriver.new(name: :cruby, closed: false)

    with_stubs([
      [InstantRecord::Testing::Runtimes::CRubyRuntime, :new, ->(**) { cruby_driver }],
      [InstantRecord::Testing::Runtimes::WasmRuntime, :new, ->(**) { raise RuntimeError, "wasm boot boom" }]
    ]) do
      err = assert_raises(RuntimeError) do
        InstantRecord::Testing.build_drivers(
          runtime_names: %i[cruby wasm],
          artifacts: fake_artifacts,
          network: network,
          server: server
        )
      end
      assert_equal "wasm boot boom", err.message
    end

    assert cruby_driver.closed, "already-built driver must be closed when a later driver fails to initialize"
  end

  def test_close_drivers_rescues_driver_close_error_and_closes_remaining_drivers_and_server
    close_order = []
    first = FakeDriver.new(name: :cruby, closed: false, raise_on_close: RuntimeError.new("driver close boom"))
    first.define_singleton_method(:close) do
      close_order << :cruby
      super()
    end
    second = FakeDriver.new(name: :wasm, closed: false)
    second.define_singleton_method(:close) do
      close_order << :wasm
      super()
    end
    server = FakeServer.new(closed: false)
    server.define_singleton_method(:close) do
      close_order << :server
      super()
    end

    InstantRecord::Testing.close_drivers({ cruby: first, wasm: second }, server: server)

    assert first.closed
    assert second.closed
    assert server.closed
    assert_equal %i[cruby wasm server], close_order

    InstantRecord::Testing.close_drivers(nil, server: nil)
  end

  def test_with_runtime_harness_closes_drivers_and_server_on_error_and_when_driver_close_raises
    server = FakeServer.new(closed: false)
    first = FakeDriver.new(name: :cruby, closed: false, raise_on_close: RuntimeError.new("cruby close failed"))
    second = FakeDriver.new(name: :wasm, closed: false)

    with_stubs([
      [InstantRecord::Testing::AuthoritativeServer, :build, ->(**) { server }],
      [InstantRecord::Testing::Runtimes::CRubyRuntime, :new, ->(**) { first }],
      [InstantRecord::Testing::Runtimes::WasmRuntime, :new, ->(**) { second }]
    ]) do
      err = assert_raises(RuntimeError) do
        InstantRecord::Testing.with_runtime_harness(
          runtime_names: %i[cruby wasm],
          artifacts: fake_artifacts
        ) do |yielded_server, yielded_network, yielded_drivers|
          assert_same server, yielded_server
          assert_instance_of InstantRecord::Testing::FaultNetwork, yielded_network
          assert_equal({ cruby: first, wasm: second }, yielded_drivers)
          raise RuntimeError, "block failure"
        end
      end

      assert_equal "block failure", err.message
    end

    assert first.closed
    assert second.closed
    assert server.closed
  end

  def test_with_runtime_harness_closes_server_when_driver_construction_fails
    server = FakeServer.new(closed: false)
    close_calls = 0
    first = FakeDriver.new(name: :cruby, closed: false)
    first.define_singleton_method(:close) do
      close_calls += 1
      super()
    end

    with_stubs([
      [InstantRecord::Testing::AuthoritativeServer, :build, ->(**) { server }],
      [InstantRecord::Testing::Runtimes::CRubyRuntime, :new, ->(**) { first }],
      [InstantRecord::Testing::Runtimes::WasmRuntime, :new, ->(**) { raise RuntimeError, "wasm init failed" }]
    ]) do
      err = assert_raises(RuntimeError) do
        InstantRecord::Testing.with_runtime_harness(runtime_names: %i[cruby wasm], artifacts: fake_artifacts) do
          flunk "block must not execute when driver construction fails"
        end
      end

      assert_equal "wasm init failed", err.message
    end

    assert_equal 1, close_calls, "earlier driver should be closed once during failed initialization"
    assert server.closed, "server must still be closed when driver construction fails"
  end

  def test_parity_suite_and_chaos_simulator_teardown_survives_driver_close_error
    [
      [:parity, ->(io) {
        InstantRecord::Testing::ParitySuite.new(
          runtimes: %i[cruby wasm],
          artifacts: fake_artifacts,
          out: io
        ).run
      }],
      [:chaos, ->(io) {
        InstantRecord::Testing::ChaosSimulator.new(
          seed: 7,
          steps: 1,
          client_count: 2,
          runtimes: %i[cruby wasm],
          artifacts: fake_artifacts,
          out: io
        ).run
      }]
    ].each do |label, runner|
      server = FakeServer.new(closed: false)
      server.define_singleton_method(:backend_label) { "fake" }
      server.define_singleton_method(:reset_data!) { raise RuntimeError, "#{label} boom" }

      first = FakeDriver.new(name: :cruby, closed: false, raise_on_close: RuntimeError.new("cruby close failed"))
      second = FakeDriver.new(name: :wasm, closed: false)

      with_stubs([
        [InstantRecord::Testing::AuthoritativeServer, :build, ->(**) { server }],
        [InstantRecord::Testing::Runtimes::CRubyRuntime, :new, ->(**) { first }],
        [InstantRecord::Testing::Runtimes::WasmRuntime, :new, ->(**) { second }]
      ]) do
        err = assert_raises(RuntimeError) { runner.call(StringIO.new) }
        assert_includes err.message, "#{label} boom"
      end

      assert first.closed, "#{label}: first driver must be closed"
      assert second.closed, "#{label}: remaining driver must still close after first driver close error"
      assert server.closed, "#{label}: server must still close after driver close error"
    end
  end
end
