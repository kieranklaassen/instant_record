require "test_helper"

class HlcTest < Minitest::Test
  HLC = InstantRecord::HLC

  def setup
    @model = syncable_model("Note")
    InstantRecord.sync(@model)
    reset_instant_record_tables!
    @previous_drift = InstantRecord.config.max_clock_drift
    InstantRecord.config.max_clock_drift = 5
  end

  def teardown
    InstantRecord.config.max_clock_drift = @previous_drift
    InstantRecord.sync
    InstantRecord::Client.transport = nil
    InstantRecord::Client.notifier = nil
    InstantRecord.instance_variable_set(:@started, false)
  end

  def test_string_encoded_format_is_fixed_width_and_lexicographically_sortable
    t1 = Time.utc(2026, 11, 21, 10, 0, 0, 1)
    t2 = Time.utc(2026, 11, 21, 10, 0, 0, 2)

    a = HLC.from_time(t1, counter: 0, node: "00000001")
    b = HLC.from_time(t1, counter: 0, node: "00000002")
    c = HLC.from_time(t1, counter: 9, node: "00000001")
    d = HLC.from_time(t1, counter: 10, node: "00000001")
    e = HLC.from_time(t1, counter: 65_535, node: "ffffffff")
    f = HLC.from_time(t2, counter: 0, node: "00000000")

    ordered = [a, b, c, d, e, f]
    ordered.each { |stamp| assert HLC.valid?(stamp), "expected valid HLC: #{stamp}" }
    assert_equal ordered, ordered.reverse.sort
    assert_equal "2026-11-21T10:00:00.000001Z-000A-00000001", d
  end

  def test_tick_is_strictly_monotonic_under_frozen_and_backward_wall_clocks
    t_now = Time.utc(2026, 11, 21, 12, 0, 0, 500_000)
    t_past = Time.utc(2026, 11, 21, 11, 0, 0, 0)

    in_browser do
      h1 = HLC.tick(now: t_now)
      h2 = HLC.tick(now: t_now)
      h3 = HLC.tick(now: t_past)

      assert_operator h1, :<, h2
      assert_operator h2, :<, h3
      assert_equal 0, HLC.parse(h1)[:counter]
      assert_equal 1, HLC.parse(h2)[:counter]
      assert_equal 2, HLC.parse(h3)[:counter]
      assert_equal HLC.parse(h1)[:pt], HLC.parse(h3)[:pt]
    end
  end

  def test_counter_rollover_at_ffff_advances_physical_time_by_one_microsecond
    t = Time.utc(2026, 11, 21, 12, 0, 0, 100)
    InstantRecord::SyncMetadata.set(HLC::KEY_LAST, HLC.from_time(t, counter: HLC::MAX_COUNTER, node: "abcd1234"))

    next_hlc = in_browser { HLC.tick(now: t, node: "abcd1234") }

    parsed = HLC.parse(next_hlc)
    assert_equal "2026-11-21T12:00:00.000101Z", parsed[:pt]
    assert_equal 0, parsed[:counter]
    assert_operator InstantRecord::SyncMetadata.get(HLC::KEY_LAST), :==, next_hlc
  end

  def test_hlc_source_avoids_64_bit_integer_packing_for_spinel_wasm32
    source = File.read(File.expand_path("../lib/instant_record/hlc.rb", __dir__), encoding: "UTF-8")
    stripped = source.gsub(/^\s*#.*$/, "")
    refute_match(/\d\s*\*\s*\d|\*\*|\d{10,}|\d\s*<<|<<\s*\d|\d\s*>>|>>\s*\d/, stripped,
      "hlc.rb must stay string-encoded and 32-bit safe for Spinel wasm32")
  end

  def test_observe_server_time_anchors_fast_and_slow_client_clocks
    server_t = Time.utc(2026, 11, 21, 12, 0, 0, 0)
    fast_local_t = server_t + 3600 # +1 hour fast

    in_browser do
      HLC.observe_server_time(server_t.iso8601(6), now: fast_local_t)
      assert_in_delta(-3600.0, HLC.offset, 0.001)

      stamped = HLC.tick(now: fast_local_t + 2)
      assert_in_delta (server_t + 2).to_f, HLC.physical_time(stamped).to_f, 0.001
    end

    reset_instant_record_tables!
    slow_local_t = server_t - 7200 # -2 hours slow

    in_browser do
      HLC.observe_server_time(server_t.iso8601(6), now: slow_local_t)
      assert_in_delta 7200.0, HLC.offset, 0.001

      stamped = HLC.tick(now: slow_local_t + 3)
      assert_in_delta (server_t + 3).to_f, HLC.physical_time(stamped).to_f, 0.001
    end
  end

  def test_observe_server_time_reanchors_previously_drifted_offline_last_hlc
    server_t = Time.utc(2026, 11, 21, 12, 0, 0, 0)
    fast_local_t = server_t + 7200 # +2 hours ahead before ever syncing

    in_browser do
      drifted = HLC.tick(now: fast_local_t)
      assert_operator HLC.physical_time(drifted), :>, server_t + 3600

      HLC.observe_server_time(server_t.iso8601(6), now: fast_local_t)
      after = HLC.tick(now: fast_local_t + 1)
      assert_in_delta (server_t + 1).to_f, HLC.physical_time(after).to_f, 0.001
    end
  end

  def test_clamp_bounds_extreme_forward_skew_without_touching_past_offline_writes
    server_now = Time.utc(2026, 11, 21, 12, 0, 0, 0)
    far_future = HLC.from_time(server_now + 3600, counter: 3, node: "fast0001")
    slight_future = HLC.from_time(server_now + 2, counter: 1, node: "near0001")
    old_offline = HLC.from_time(server_now - 7200, counter: 0, node: "slow0001")

    clamped_future = HLC.clamp(far_future, now: server_now, max_drift: 5)
    assert_equal HLC.from_time(server_now, counter: 3, node: "fast0001"), clamped_future
    assert_equal slight_future, HLC.clamp(slight_future, now: server_now, max_drift: 5)
    assert_equal old_offline, HLC.clamp(old_offline, now: server_now, max_drift: 5)
  end

  def test_receive_clamps_rogue_future_remote_hlc
    now = Time.utc(2026, 11, 21, 12, 0, 0, 0)
    rogue = HLC.from_time(now + 86_400, counter: 0, node: "evil0001")

    in_browser do
      HLC.receive(rogue, now: now)
      assert_operator HLC.physical_time(HLC.last), :<=, now + 5
    end
  end

  # Directly verifies the bug noted at client.rb:560-561: a client whose wall
  # clock runs hours ahead must NOT win writes against a later honest client.
  def test_anchored_fast_clock_client_loses_to_later_honest_write
    real_t0 = Time.utc(2026, 11, 21, 12, 0, 0, 0)
    record = nil

    HLC.with_clock(-> { real_t0 }) do
      record = on_server { @model.create!(id: "n-1", title: "initial") }
    end

    # Fast client (+3h wall clock) anchors via bootstrap server_time at real_t0.
    in_browser do
      HLC.observe_server_time(real_t0.iso8601(6), now: real_t0 + 10_800)

      # Fast client edits at real_t0 + 1s (local wall clock says +3h + 1s).
      HLC.with_clock(-> { real_t0 + 10_801 }) do
        record.update!(title: "fast client earlier edit")
      end
    end
    fast_mutation = InstantRecord::OutboxMutation.sole.as_mutation
    fast_hlc = fast_mutation[:hlc]
    InstantRecord::OutboxMutation.delete_all

    # Honest client edits the same column later, at real_t0 + 2s, and lands first.
    honest_hlc = HLC.from_time(real_t0 + 2, counter: 0, node: "honest01")
    HLC.with_clock(-> { real_t0 + 2 }) do
      res = on_server do
        InstantRecord::MutationApplier.apply(
          id: "honest-m1", record_type: "Note", record_id: "n-1", operation: "update",
          base_version: 1, hlc: honest_hlc, changes: { "title" => "honest later edit" }
        )
      end
      assert_equal "applied", res[:status]
      refute res[:skipped]
    end

    # Fast client's earlier write arrives at real_t0 + 3s and MUST lose to honest write.
    assert_operator fast_hlc, :<, honest_hlc
    result = HLC.with_clock(-> { real_t0 + 3 }) do
      on_server { InstantRecord::MutationApplier.apply(fast_mutation) }
    end

    assert result[:skipped], "fast-clock client's earlier write must lose to later honest write"
    assert_equal "honest later edit", record.reload.title
  end

  # Even if a fast-clock client NEVER synced before writing offline, server-side
  # skew clamping stops it from poisoning updated_at or beating future honest writes.
  def test_unanchored_fast_clock_client_is_clamped_on_the_server
    real_t0 = Time.utc(2026, 11, 21, 12, 0, 0, 0)
    record = HLC.with_clock(-> { real_t0 }) do
      on_server { @model.create!(id: "n-2", title: "initial") }
    end

    # Rogue/unanchored client claims a timestamp 2 hours in the future.
    future_t = real_t0 + 7200
    future_hlc = HLC.from_time(future_t, counter: 0, node: "fast9999")
    res1 = HLC.with_clock(-> { real_t0 + 1 }) do
      on_server do
        InstantRecord::MutationApplier.apply(
          id: "fast-unanchored", record_type: "Note", record_id: "n-2", operation: "update",
          base_version: 1, hlc: future_hlc,
          changes: { "title" => "fast write", "updated_at" => future_t.iso8601(6) }
        )
      end
    end

    assert_equal "applied", res1[:status]
    assert_in_delta (real_t0 + 1).to_f, HLC.physical_time(res1[:hlc]).to_f, 0.001,
      "server must clamp extreme forward HLC skew to server UTC"
    assert_operator record.reload.updated_at, :<=, real_t0 + 5,
      "server must clamp updated_at so Postgres is not poisoned into the future"

    # Honest client writes 2 seconds later and MUST win over the clamped fast write.
    honest_hlc = HLC.from_time(real_t0 + 3, counter: 0, node: "honest02")
    res2 = HLC.with_clock(-> { real_t0 + 3 }) do
      on_server do
        InstantRecord::MutationApplier.apply(
          id: "honest-after", record_type: "Note", record_id: "n-2", operation: "update",
          base_version: 2, hlc: honest_hlc, changes: { "title" => "honest wins" }
        )
      end
    end

    refute res2[:skipped]
    assert_equal "honest wins", record.reload.title
  end

  def test_client_bootstrap_and_drain_anchor_clock_from_server_time
    server_t = Time.utc(2026, 11, 21, 12, 0, 0, 0)
    skewed_local_t = server_t + 3600

    transport = Object.new
    transport.define_singleton_method(:get_json) do |_path|
      { "cursor" => 1, "records" => [], "server_time" => server_t.iso8601(6) }
    end
    transport.define_singleton_method(:post_json) do |_path, payload|
      {
        "results" => payload[:mutations].map { |m| { "mutation_id" => m[:id], "status" => "applied", "version" => 1, "hlc" => m[:hlc] } },
        "server_time" => (server_t + 5).iso8601(6)
      }
    end
    transport.define_singleton_method(:each_event) { |_path| nil }

    InstantRecord::Client.transport = transport
    InstantRecord::Client.notifier = Class.new { def records_changed; end }.new

    in_browser do
      HLC.with_clock(-> { skewed_local_t }) do
        InstantRecord::Client.bootstrap
        assert_in_delta(-3600.0, HLC.offset, 0.001)
      end

      HLC.with_clock(-> { skewed_local_t + 5 }) do
        @model.create!(id: "c-1", title: "anchored")
        mutation = InstantRecord::OutboxMutation.sole
        assert_in_delta (server_t + 5).to_f, HLC.physical_time(mutation.hlc).to_f, 0.001

        InstantRecord::Client.drain
      end
    end

    assert_equal 0, InstantRecord::OutboxMutation.count
    assert_nil HLC.mutation_hlc("anything")
  end

  def test_client_apply_change_uses_hlc_over_skewed_local_updated_at
    server_t = Time.utc(2026, 11, 21, 12, 0, 0, 0)
    fast_local_t = server_t + 7200 # local wall clock +2h ahead

    note = nil
    in_browser do
      HLC.observe_server_time(server_t.iso8601(6), now: fast_local_t)
      HLC.with_clock(-> { fast_local_t + 1 }) do
        # ActiveRecord writes updated_at with raw fast wall clock, while HLC is anchored to server_t + 1s.
        note = @model.create!(id: "skew-1", title: "local fast clock", updated_at: fast_local_t + 1)
      end
    end

    # Remote write happened AFTER local write at server_t + 2s, even though its updated_at
    # is ~2 hours EARLIER than local raw updated_at!
    remote_hlc = HLC.from_time(server_t + 2, counter: 0, node: "peer0001")
    applied = in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => "skew-1", "operation" => "update", "version" => 2,
        "hlc" => remote_hlc,
        "attributes" => {
          "id" => "skew-1", "title" => "newer remote write",
          "updated_at" => (server_t + 2).iso8601(6)
        }
      )
    end

    assert applied, "remote write with newer HLC must win even when local raw updated_at is hours ahead"
    assert_equal "newer remote write", note.reload.title
    assert_equal remote_hlc, HLC.row_hlc("Note", "skew-1")
  end

  def test_client_echo_with_matching_hlc_is_dropped_quietly
    discarded = []
    model = syncable_model("Note") { on_discarded_change { |attrs| discarded << attrs } }
    InstantRecord.sync(model)

    note = in_browser { model.create!(id: "echo-1", title: "mine") }
    local_hlc = HLC.row_hlc("Note", "echo-1")

    applied = in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => "echo-1", "operation" => "create", "version" => 1,
        "hlc" => local_hlc,
        "attributes" => InstantRecord.wire_attributes(note.attributes)
      )
    end

    refute applied
    assert_empty discarded
  end

  def test_reset_cleans_row_hlcs_for_reset_types_while_keeping_device_clock
    server_t = Time.utc(2026, 11, 21, 12, 0, 0, 0)
    in_browser do
      HLC.observe_server_time(server_t.iso8601(6), now: server_t + 60)
      @model.create!(id: "r-1", title: "scoped")
      assert HLC.row_hlc("Note", "r-1")

      InstantRecord::Client.reset("operation" => "reset", "types" => ["Note"])

      assert_nil HLC.row_hlc("Note", "r-1")
      assert HLC.last, "device HLC clock must survive identity reset"
      assert_in_delta(-60.0, HLC.offset, 0.001)
    end
  end

  def test_record_payload_and_change_event_carry_hlc_and_stream_piggybacks_server_time
    require "action_controller"
    require File.expand_path("../app/controllers/instant_record/events_controller", __dir__)

    t0 = Time.utc(2026, 11, 21, 12, 0, 0, 0)
    record = HLC.with_clock(-> { t0 }) do
      on_server { @model.create!(id: "wire-1", title: "hello") }
    end

    payload = InstantRecord.record_payload(record)
    assert HLC.valid?(payload[:hlc])

    change = InstantRecord::Change.sole
    assert_equal payload[:hlc], change.hlc
    assert_equal payload[:hlc], change.as_event[:hlc]

    stream = InstantRecord::EventsController::EventStream.new(cursor: 0, deadline: Time.current, heartbeat: 0)
    events = []
    parser = InstantRecord::Client::Transport::SseParser.new { |event| events << event }
    HLC.with_clock(-> { t0 + 10 }) do
      stream.each { |chunk| parser.feed(chunk) }
    end

    event = events.sole
    assert_equal payload[:hlc], event["hlc"]
    assert_equal (t0 + 10).iso8601(6), event["server_time"]

    # Consuming that streamed event anchors a skewed client's clock.
    in_browser do
      HLC.with_clock(-> { t0 + 10 + 1800 }) do
        InstantRecord::Client.apply_events([event])
        assert_in_delta(-1800.0, HLC.offset, 0.001)
      end
    end
  end
end
