require "test_helper"
require "instant_record/testing"

class FaultNetworkTest < Minitest::Test
  class FakeServer
    attr_reader :calls

    def initialize
      @calls = []
    end

    def exchange(verb, path, body, identity:)
      @calls << { verb: verb, path: path, body: body, identity: identity }
      { status: 200, body: "ok:#{verb}:#{path}" }
    end
  end

  def setup
    @server = FakeServer.new
    @network = InstantRecord::Testing::FaultNetwork.new(@server)
  end

  def test_register_client_and_set_partition_validate_partition_modes
    @network.register_client(:c1, identity: "alice", clock_skew: 1.5, partition: "drop_post")
    pol = @network.policy("c1")
    assert_equal :drop_post, pol.partition
    assert_equal "alice", pol.identity
    assert_equal 1.5, pol.clock_skew
    assert_nil pol.bootstrap_abort

    assert_raises(ArgumentError) { @network.register_client("c1", partition: :bogus) }
    assert_raises(ArgumentError) { @network.register_client("c1", partition: nil) }
    assert_equal :drop_post, @network.policy("c1").partition, "invalid register_client must not overwrite policy"

    assert_raises(ArgumentError) { @network.set_partition("c1", :unknown) }
    assert_raises(ArgumentError) { @network.set_partition("c1", 123) }
    assert_equal :drop_post, @network.policy("c1").partition

    @network.set_partition("c1", "offline")
    assert_equal :offline, @network.policy("c1").partition
  end

  def test_partition_modes_control_server_forwarding_and_logging
    @network.register_client("c1", identity: "u1", partition: :online)
    assert_equal({ status: 200, body: "ok:GET:/sync/changes" }, @network.exchange("c1", :get, "/sync/changes"))
    assert_equal 1, @server.calls.size
    assert_nil @network.log.last.fault
    assert_equal "u1", @network.log.last.identity

    @network.set_partition("c1", :offline)
    assert_equal({ status: 0, body: "" }, @network.exchange("c1", "GET", "/sync/changes"))
    assert_equal({ status: 0, body: "" }, @network.exchange("c1", "POST", "/sync/mutations", "{}"))
    assert_equal 1, @server.calls.size
    assert_equal :offline, @network.log.last.fault

    @network.set_partition("c1", :drop_post)
    assert_equal({ status: 0, body: "" }, @network.exchange("c1", "POST", "/sync/mutations", "{}"))
    assert_equal :drop_post, @network.log.last.fault
    assert_equal({ status: 200, body: "ok:GET:/sync/changes" }, @network.exchange("c1", "GET", "/sync/changes"))
    assert_equal 2, @server.calls.size
    assert_nil @network.log.last.fault

    @network.set_partition("c1", :drop_get)
    assert_equal({ status: 0, body: "" }, @network.exchange("c1", "GET", "/sync/changes"))
    assert_equal :drop_get, @network.log.last.fault
    assert_equal({ status: 200, body: "ok:POST:/sync/mutations" }, @network.exchange("c1", "POST", "/sync/mutations", "{}"))
    assert_equal 3, @server.calls.size
    assert_nil @network.log.last.fault

    @network.set_partition("c1", :server_503)
    assert_equal({ status: 503, body: "Service Unavailable" }, @network.exchange("c1", "GET", "/sync/changes"))
    assert_equal({ status: 503, body: "Service Unavailable" }, @network.exchange("c1", "POST", "/sync/mutations", "{}"))
    assert_equal 3, @server.calls.size
    assert_equal :server_503, @network.log.last.fault
  end

  def test_drop_after_apply_forwards_to_server_and_resets_to_online_once
    @network.register_client("c1", identity: "u1", partition: :drop_after_apply)

    # Non-mutation requests pass through without consuming the one-shot drop.
    assert_equal({ status: 200, body: "ok:GET:/sync/changes" }, @network.exchange("c1", "GET", "/sync/changes"))
    assert_equal({ status: 200, body: "ok:POST:/sync/other" }, @network.exchange("c1", "POST", "/sync/other", "{}"))
    assert_equal :drop_after_apply, @network.policy("c1").partition
    assert_equal 2, @server.calls.size

    # POST /mutations is applied on the server, response is dropped, and partition heals to :online.
    reply = @network.exchange("c1", "POST", "/sync/mutations", '{"id":"m1"}')
    assert_equal({ status: 0, body: "" }, reply)
    assert_equal 3, @server.calls.size
    assert_equal({ verb: "POST", path: "/sync/mutations", body: '{"id":"m1"}', identity: "u1" }, @server.calls.last)
    assert_equal :online, @network.policy("c1").partition
    assert_equal :drop_after_apply, @network.log.last.fault

    # Subsequent retry succeeds normally.
    retry_reply = @network.exchange("c1", "POST", "/sync/mutations", '{"id":"m1"}')
    assert_equal({ status: 200, body: "ok:POST:/sync/mutations" }, retry_reply)
    assert_nil @network.log.last.fault
  end

  def test_arm_bootstrap_abort_validates_modes_and_fires_one_shot_with_precedence
    assert_raises(ArgumentError) { @network.arm_bootstrap_abort("c1", :invalid_mode) }
    assert_raises(ArgumentError) { @network.arm_bootstrap_abort("c1", nil) }
    assert_nil @network.policy("c1").bootstrap_abort

    @network.arm_bootstrap_abort("c1")
    assert_equal :network_drop, @network.policy("c1").bootstrap_abort

    # Invalid mode leaves previously armed abort intact.
    assert_raises(ArgumentError) { @network.arm_bootstrap_abort("c1", :bogus) }
    assert_equal :network_drop, @network.policy("c1").bootstrap_abort

    # Non-bootstrap requests and POST /bootstrap do not consume the armed abort.
    assert_equal({ status: 200, body: "ok:GET:/sync/changes" }, @network.exchange("c1", "GET", "/sync/changes"))
    assert_equal({ status: 200, body: "ok:POST:/sync/bootstrap" }, @network.exchange("c1", "POST", "/sync/bootstrap"))
    assert_equal :network_drop, @network.policy("c1").bootstrap_abort

    # Takes precedence over partition rules on GET /bootstrap, then disarms.
    @network.set_partition("c1", :server_503)
    assert_equal({ status: 0, body: "" }, @network.exchange("c1", "GET", "/sync/bootstrap"))
    assert_nil @network.policy("c1").bootstrap_abort
    assert_equal :bootstrap_network_drop, @network.log.last.fault

    @network.set_partition("c1", :online)
    assert_equal({ status: 200, body: "ok:GET:/sync/bootstrap" }, @network.exchange("c1", "GET", "/sync/bootstrap"))

    @network.arm_bootstrap_abort("c1", "server_503")
    assert_equal({ status: 503, body: "Service Unavailable" }, @network.exchange("c1", "GET", "/sync/bootstrap"))
    assert_equal :bootstrap_server_503, @network.log.last.fault
    assert_nil @network.policy("c1").bootstrap_abort

    @network.arm_bootstrap_abort("c1", :truncated_body)
    truncated = @network.exchange("c1", "GET", "/sync/bootstrap")
    assert_equal 200, truncated[:status]
    assert_raises(JSON::ParserError) { JSON.parse(truncated[:body]) }
    assert_equal :bootstrap_truncated_body, @network.log.last.fault
    assert_nil @network.policy("c1").bootstrap_abort
  end

  def test_track_faults_supports_nesting_and_restores_state_on_exception
    @network.register_client("c1", partition: :online)

    res, fired = @network.track_faults do
      @network.exchange("c1", "GET", "/sync/changes")
      :clean
    end
    assert_equal :clean, res
    assert_equal false, fired

    # Inner fault propagates outward while outer clean work before it still sees true.
    outer_res, outer_fired = @network.track_faults do
      @network.exchange("c1", "GET", "/sync/changes")
      inner_res, inner_fired = @network.track_faults do
        @network.set_partition("c1", :offline)
        @network.exchange("c1", "GET", "/sync/changes")
        :inner
      end
      assert_equal :inner, inner_res
      assert_equal true, inner_fired
      :outer
    end
    assert_equal :outer, outer_res
    assert_equal true, outer_fired

    # Outer fault already fired is preserved even when a nested window has no faults.
    @network.set_partition("c1", :offline)
    _, outer_preserved = @network.track_faults do
      @network.exchange("c1", "GET", "/sync/changes")
      @network.set_partition("c1", :online)
      _, nested_clean = @network.track_faults do
        @network.exchange("c1", "GET", "/sync/changes")
      end
      assert_equal false, nested_clean
    end
    assert_equal true, outer_preserved

    # Exception inside nested block still propagates any fault that fired before raising.
    _, propagated_after_raise = @network.track_faults do
      assert_raises(RuntimeError) do
        @network.track_faults do
          @network.set_partition("c1", :server_503)
          @network.exchange("c1", "GET", "/sync/changes")
          raise "boom"
        end
      end
    end
    assert_equal true, propagated_after_raise
  end

  def test_heal_all_resets_partitions_and_bootstrap_aborts_without_dropping_identity_or_skew
    @network.register_client("c1", identity: "alice", clock_skew: 2.5, partition: :offline)
    @network.register_client("c2", identity: "bob", clock_skew: -1.0, partition: :drop_after_apply)
    @network.arm_bootstrap_abort("c1", :server_503)
    @network.arm_bootstrap_abort("c2", :truncated_body)

    @network.heal_all!

    c1 = @network.policy("c1")
    c2 = @network.policy("c2")
    assert_equal :online, c1.partition
    assert_nil c1.bootstrap_abort
    assert_equal "alice", c1.identity
    assert_equal 2.5, c1.clock_skew

    assert_equal :online, c2.partition
    assert_nil c2.bootstrap_abort
    assert_equal "bob", c2.identity
    assert_equal(-1.0, c2.clock_skew)
  end

  def test_invalid_modes_do_not_create_policy_entries_and_constants_are_self_contained
    assert_equal InstantRecord::Testing::BOOTSTRAP_ABORT_MODES,
      InstantRecord::Testing::FaultNetwork::BOOTSTRAP_ABORT_MODES

    assert_raises(ArgumentError) { @network.set_partition("ghost-1", :nope) }
    assert_raises(ArgumentError) { @network.arm_bootstrap_abort("ghost-2", :nope) }
    assert_empty @network.instance_variable_get(:@policies)
  end
end
