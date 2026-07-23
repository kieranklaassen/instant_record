require "test_helper"

class FakeTransport
  attr_reader :posts, :gets
  attr_accessor :events_to_yield, :on_post, :bootstrap_body

  def initialize
    @posts = []
    @gets = []
    @events_to_yield = []
    @results_to_return = []
    @bootstrap_body = { "cursor" => 0, "records" => [] }
  end

  def respond_with(results)
    @results_to_return = results
  end

  def post_json(path, payload)
    @on_post&.call
    @posts << [path, payload]
    { "results" => @results_to_return }
  end

  def get_json(path)
    @gets << path
    @bootstrap_body
  end

  def each_event(_path, &block)
    @events_to_yield.each(&block)
  end
end

class FakeNotifier
  attr_reader :notifications

  def initialize = @notifications = 0
  def records_changed = @notifications += 1
end

class ConfigurationTest < Minitest::Test
  def test_defaults
    config = InstantRecord::Configuration.new
    assert_equal "/instant_record", config.endpoint
    assert_equal 3, config.sync_interval
  end

  def test_configure_yields_the_memoized_config
    InstantRecord.configure do |c|
      c.endpoint = "http://localhost:3000/instant_record"
      c.sync_interval = 5
    end

    assert_equal "http://localhost:3000/instant_record", InstantRecord.config.endpoint
    assert_equal 5, InstantRecord.config.sync_interval
  ensure
    InstantRecord.instance_variable_set(:@config, nil)
  end
end

class SyncLoopTest < Minitest::Test
  def setup
    @model = syncable_model("Memo")
    InstantRecord.sync(@model)
    @transport = FakeTransport.new
    @notifier = FakeNotifier.new
    InstantRecord::Client.transport = @transport
    InstantRecord::Client.notifier = @notifier
    reset_instant_record_tables!
    InstantRecord.instance_variable_set(:@started, false)
  end

  def teardown
    InstantRecord.sync
    InstantRecord::Client.transport = nil
    InstantRecord::Client.notifier = nil
    InstantRecord.instance_variable_set(:@started, false)
  end

  def test_start_is_a_no_op_on_the_server_runtime
    on_server do
      refute InstantRecord.start
      assert_equal :not_started, InstantRecord.tick
    end
  end

  def test_tick_before_start_does_nothing
    in_browser do
      assert_equal :not_started, InstantRecord.tick
    end
    assert_empty @transport.posts
  end

  def test_drain_posts_pending_mutations_and_applies_results
    in_browser do
      memo = @model.create!(title: "hello")
      mutation_id = InstantRecord::OutboxMutation.sole.id
      @transport.respond_with([{ "mutation_id" => mutation_id, "status" => "applied", "version" => 1 }])

      InstantRecord.start
      assert_equal :ok, InstantRecord.tick

      path, payload = @transport.posts.sole
      assert_equal "/mutations", path
      assert_equal mutation_id, payload[:mutations].first[:id]

      assert_equal 0, InstantRecord.pending_count
      assert_equal "synced", memo.reload.sync_state
      assert_equal 1, @notifier.notifications
    end
  end

  def test_empty_outbox_posts_nothing
    in_browser do
      InstantRecord.start
      InstantRecord.tick
    end
    assert_empty @transport.posts
  end

  def test_poll_requests_a_zero_window_so_ticks_never_hold_a_stream
    InstantRecord::Client.cursor = 0 # already bootstrapped; exercise the poll branch
    in_browser do
      InstantRecord.start
      captured_path = nil
      @transport.define_singleton_method(:each_event) { |path, &blk| captured_path = path }
      InstantRecord.tick

      assert_includes captured_path, "window=0",
        "poll must ask the server to close after catch-up; a held stream starves the tick"
    end
  end

  def test_poll_applies_events_advances_cursor_once_and_notifies_once
    InstantRecord::Client.cursor = 0 # already bootstrapped; exercise the poll branch
    @transport.events_to_yield = [
      { "type" => "Memo", "id" => "m-1", "operation" => "create", "version" => 1, "cursor" => 7,
        "attributes" => { "id" => "m-1", "title" => "from server", "updated_at" => Time.current.iso8601 } },
      { "type" => "Memo", "id" => "m-2", "operation" => "create", "version" => 1, "cursor" => 8,
        "attributes" => { "id" => "m-2", "title" => "also from server", "updated_at" => Time.current.iso8601 } }
    ]

    in_browser do
      InstantRecord.start
      assert_equal :ok, InstantRecord.tick
    end

    assert_equal 2, @model.count
    assert_equal 8, InstantRecord.cursor
    assert_equal 1, @notifier.notifications, "one notification per pass, not per event"
  end

  def test_many_queued_writes_go_up_in_a_single_request
    in_browser do
      InstantRecord.start
      500.times { |i| @model.create!(id: "burst-#{i}", title: "burst #{i}") }

      # Ack everything the batch carries, as the real server would.
      @transport.respond_with(
        InstantRecord::OutboxMutation.pluck(:id).map do |id|
          { "mutation_id" => id, "status" => "applied", "version" => 1 }
        end
      )

      InstantRecord.tick
    end

    assert_equal 1, @transport.posts.size,
      "one pass must batch the whole outbox into one request, not one per write"
    assert_equal 500, @transport.posts.first.last[:mutations].size
    assert_equal 0, InstantRecord.pending_count, "acked mutations leave the outbox"
  end

  # A write of your own comes straight back down the stream. Re-applying it
  # changes nothing locally, so it must not be announced as a change — every
  # notification reloads pages that have no in-place refresh.

  def test_the_echo_of_your_own_write_is_not_announced_as_a_change
    in_browser do
      InstantRecord.start
      @model.create!(id: "mine", title: "my own write")

      @transport.respond_with(
        InstantRecord::OutboxMutation.pluck(:id).map do |id|
          { "mutation_id" => id, "status" => "applied", "version" => 1 }
        end
      )
      InstantRecord.tick

      notifications_before = @notifier.notifications
      row = @model.find("mine")

      # The server logs the change and streams it back to us.
      applied = InstantRecord::Client.apply_events([
        { "type" => "Memo", "id" => "mine", "operation" => "update", "version" => 1, "cursor" => 90,
          "attributes" => { "id" => "mine", "title" => "my own write", "state" => row.state,
                            "created_at" => row.created_at.iso8601(6), "updated_at" => row.updated_at.iso8601(6) } }
      ])

      assert_equal 0, applied, "re-applying our own row changes nothing"
      assert_equal notifications_before, @notifier.notifications,
        "announcing it would reload every tab for no reason"
    end
  end

  def test_a_genuine_remote_change_is_still_announced
    in_browser do
      InstantRecord.start
      @model.create!(id: "theirs", title: "original")

      before = @notifier.notifications
      applied = InstantRecord::Client.apply_events([
        { "type" => "Memo", "id" => "theirs", "operation" => "update", "version" => 2, "cursor" => 91,
          "attributes" => { "id" => "theirs", "title" => "edited elsewhere",
                            "updated_at" => (Time.current + 60).iso8601(6) } }
      ])

      assert_equal 1, applied
      assert_equal before + 1, @notifier.notifications
      assert_equal "edited elsewhere", @model.find("theirs").title
    end
  end

  # --- Consuming the change stream -------------------------------------------
  # The worker owns the socket because Ruby awaiting chunks would suspend the
  # sync guard. The wire format is parsed here, by the same SseParser the poll
  # path uses — one implementation, not two.

  def sse_frame(id, record_id)
    payload = JSON.generate(
      "type" => "Memo", "id" => record_id, "operation" => "create", "version" => 1,
      "attributes" => { "id" => record_id, "title" => record_id, "updated_at" => Time.current.iso8601 }
    )
    "id: #{id}\ndata: #{payload}\n\n"
  end

  def test_a_chunk_of_frames_is_parsed_and_applied
    in_browser do
      applied = InstantRecord::Client.consume_stream(sse_frame(31, "c-1") + sse_frame(32, "c-2"))

      assert_equal 2, applied
    end

    assert_equal %w[c-1 c-2], @model.order(:id).pluck(:id)
    assert_equal 32, InstantRecord.cursor
    assert_equal 1, @notifier.notifications, "one notification per chunk, not per event"
  end

  def test_a_frame_split_across_chunks_is_applied_once_whole
    frame = sse_frame(41, "split-1")
    head, tail = frame[0, 30], frame[30..]

    in_browser do
      assert_equal 0, InstantRecord::Client.consume_stream(head),
        "half a frame is not an event yet"
      assert_equal 0, @model.count

      assert_equal 1, InstantRecord::Client.consume_stream(tail)
    end

    assert_equal %w[split-1], @model.pluck(:id)
    assert_equal 41, InstantRecord.cursor
  end

  def test_reopening_the_stream_discards_a_half_received_frame
    in_browser do
      InstantRecord::Client.consume_stream(sse_frame(51, "dropped")[0, 25]) # connection dies mid-frame
      InstantRecord::Client.reset_stream

      # The next stream starts clean; the stale prefix must not corrupt it.
      assert_equal 1, InstantRecord::Client.consume_stream(sse_frame(52, "after-reconnect"))
    end

    assert_equal %w[after-reconnect], @model.pluck(:id)
    assert_equal 52, InstantRecord.cursor
  end

  def test_consume_stream_b64_round_trips_and_answers_busy
    encoded = Base64.strict_encode64(sse_frame(61, "b64-1"))

    in_browser do
      reply = JSON.parse(InstantRecord.consume_stream_b64(encoded))
      assert reply["ok"]
      assert_equal 1, reply["applied"]
      assert_equal 61, reply["cursor"]

      InstantRecord.instance_variable_set(:@ticking, true)
      assert_equal true, JSON.parse(InstantRecord.consume_stream_b64(encoded))["busy"],
        "a busy reply must leave the chunk unconsumed so the worker can resend it"
    end
  ensure
    InstantRecord.instance_variable_set(:@ticking, false)
  end

  def test_a_busy_chunk_is_not_half_consumed
    encoded = Base64.strict_encode64(sse_frame(71, "resend-me"))

    in_browser do
      InstantRecord.instance_variable_set(:@ticking, true)
      InstantRecord.consume_stream_b64(encoded)
      InstantRecord.instance_variable_set(:@ticking, false)

      # The worker resends the same chunk; it must apply exactly once.
      reply = JSON.parse(InstantRecord.consume_stream_b64(encoded))
      assert_equal 1, reply["applied"]
    end

    assert_equal %w[resend-me], @model.pluck(:id)
  end

  # Coalescing: the VM must not be re-entered, so a pass already in flight is
  # the natural place to absorb every request that arrives while it runs.

  def test_requests_arriving_during_a_pass_coalesce_into_one_more_pass
    in_browser do
      InstantRecord.start
      @model.create!(id: "first", title: "first")

      # 50 writes land while the pass is posting. None may start a second pass,
      # and none may be dropped — so exactly one more pass should follow.
      once = true
      @transport.on_post = lambda do
        next unless once

        once = false
        50.times { |i| @model.create!(id: "during-#{i}", title: "during #{i}") }
        50.times { InstantRecord.tick }
      end

      InstantRecord.tick
    end

    assert_equal 2, @transport.posts.size,
      "50 requests during one pass must collapse into a single extra pass"
    carried = @transport.posts.last.last[:mutations].map { |m| m[:record_id] || m["record_id"] }
    50.times { |i| assert_includes carried, "during-#{i}" }
  end

  def test_a_request_arriving_during_a_pass_is_never_dropped
    in_browser do
      InstantRecord.start
      @model.create!(id: "first", title: "first")

      once = true
      @transport.on_post = lambda do
        next unless once

        once = false
        @model.create!(id: "late", title: "arrived mid-pass")
        InstantRecord.tick
      end

      InstantRecord.tick
    end

    posted = @transport.posts.flat_map { |(_path, body)| body[:mutations].map { |m| m[:record_id] || m["record_id"] } }
    assert_includes posted, "late", "a write that arrived mid-pass must still reach the server"
  end

  def test_a_history_fetch_holding_the_guard_still_reports_busy
    in_browser do
      InstantRecord.start
      InstantRecord.instance_variable_set(:@ticking, true)

      assert_equal :busy, InstantRecord.tick,
        "the worker needs to hear busy so it retries; nothing is looping to absorb it"
    end
  ensure
    InstantRecord.instance_variable_set(:@ticking, false)
  end

  # --- tick_json: the worker's retry signal ----------------------------------
  # There is no heartbeat, so the pass has to say whether it is worth coming back.

  def test_tick_json_reports_an_empty_outbox_so_an_idle_client_goes_quiet
    in_browser do
      InstantRecord.start
      reply = JSON.parse(InstantRecord.tick_json)

      assert reply["ok"]
      assert_equal 0, reply["pending"], "nothing queued means the worker stops retrying"
    end
  end

  def test_tick_json_reports_work_still_queued_when_the_drain_fails
    @transport.define_singleton_method(:post_json) { |*| raise InstantRecord::Client::Transport::Error, "offline" }

    in_browser do
      InstantRecord.start
      @model.create!(id: "stuck-1", title: "cannot go up yet")
      reply = JSON.parse(InstantRecord.tick_json)

      assert_equal 1, reply["pending"], "a failed drain must keep the retry alive"
    end
  end

  def test_tick_json_answers_busy_rather_than_re_entering_the_vm
    InstantRecord.instance_variable_set(:@ticking, true)

    in_browser do
      InstantRecord.start
      assert_equal true, JSON.parse(InstantRecord.tick_json)["busy"]
    end
  ensure
    InstantRecord.instance_variable_set(:@ticking, false)
  end

  def test_tick_json_never_raises_across_the_boundary
    @transport.define_singleton_method(:post_json) { |*| raise "something unexpected" }

    in_browser do
      InstantRecord.start
      @model.create!(id: "boom-1", title: "unexpected failure")
      reply = JSON.parse(InstantRecord.tick_json)

      refute reply["ok"]
      assert_equal 1, reply["pending"], "an unexpected failure must still be retried"
    end
  end

  # --- Streamed changes ------------------------------------------------------
  # Ruby can't hold a tailing stream (each awaited chunk would suspend the
  # single-flight tick), so the worker holds it and feeds events in.

  def streamed_event(id, cursor)
    { "type" => "Memo", "id" => id, "operation" => "create", "version" => 1, "cursor" => cursor,
      "attributes" => { "id" => id, "title" => id, "updated_at" => Time.current.iso8601 } }
  end

  def test_streamed_events_apply_advance_the_cursor_and_notify_once
    in_browser do
      applied = InstantRecord.apply_events([streamed_event("s-1", 11), streamed_event("s-2", 12)])

      assert_equal 2, applied
    end

    assert_equal %w[s-1 s-2], @model.order(:id).pluck(:id)
    assert_equal 12, InstantRecord.cursor
    assert_equal 1, @notifier.notifications, "one notification per batch, not per event"
  end

  def test_streamed_events_are_idempotent
    in_browser do
      InstantRecord.apply_events([streamed_event("s-1", 11)])
      InstantRecord.apply_events([streamed_event("s-1", 11)])
    end

    assert_equal 1, @model.count, "a replayed batch must not duplicate rows"
    assert_equal 11, InstantRecord.cursor
  end

  def test_an_empty_batch_changes_nothing_and_stays_quiet
    in_browser { assert_equal 0, InstantRecord.apply_events([]) }

    assert_equal 0, @notifier.notifications
    assert_equal 0, InstantRecord.cursor
  end

  def test_a_live_stream_stands_the_catch_up_poll_down
    InstantRecord::Client.cursor = 0 # already bootstrapped; exercise the poll branch
    polled = false
    @transport.define_singleton_method(:each_event) { |_path, &_blk| polled = true }

    in_browser do
      InstantRecord.start
      InstantRecord.streaming = true
      InstantRecord.tick

      refute polled, "the stream is already delivering; the poll must not duplicate it"

      # And when the stream drops, the poll takes over again.
      InstantRecord.streaming = false
      InstantRecord.tick
      assert polled
    end
  ensure
    InstantRecord.streaming = false
  end

  def test_streaming_does_not_stop_the_outbox_draining
    in_browser do
      InstantRecord.start
      InstantRecord.streaming = true
      @model.create!(id: "local-1", title: "written locally")
      InstantRecord.tick
    end

    assert_equal 1, @transport.posts.size, "writes must still go up while the stream carries changes down"
  ensure
    InstantRecord.streaming = false
  end

  def test_nothing_changed_means_no_notification
    InstantRecord::Client.cursor = 0 # already bootstrapped; a fresh client's bootstrap counts as a change
    in_browser do
      InstantRecord.start
      InstantRecord.tick
    end
    assert_equal 0, @notifier.notifications
  end

  def test_overlapping_tick_is_skipped_not_queued
    in_browser do
      @model.create!(title: "hello")
      nested_result = nil
      @transport.on_post = -> { nested_result = InstantRecord.tick }

      InstantRecord.start
      assert_equal :ok, InstantRecord.tick

      assert_equal :busy, nested_result
      assert_equal 1, @transport.posts.size, "no duplicate POST from the nested tick"
    end
  end

  def test_guard_releases_after_transport_failure
    InstantRecord::Client.cursor = 0
    in_browser do
      @model.create!(title: "hello")
      failing = Object.new
      def failing.post_json(*) = raise(InstantRecord::Client::Transport::Error, "offline")
      def failing.each_event(*) = raise(InstantRecord::Client::Transport::Error, "offline")
      def failing.get_json(*) = raise(InstantRecord::Client::Transport::Error, "offline")
      InstantRecord::Client.transport = failing

      InstantRecord.start
      assert_equal :ok, InstantRecord.tick, "failures are caught per phase"
      assert_equal 1, InstantRecord.pending_count, "mutation stays queued for retry"

      InstantRecord::Client.transport = @transport
      assert_equal :ok, InstantRecord.tick, "guard released; next tick runs"
      assert_equal 1, @transport.posts.size
    end
  end

  def test_sync_now_works_without_start
    in_browser do
      @model.create!(title: "hello")
      mutation_id = InstantRecord::OutboxMutation.sole.id
      @transport.respond_with([{ "mutation_id" => mutation_id, "status" => "applied", "version" => 1 }])

      assert_equal :ok, InstantRecord.sync_now
      assert_equal 0, InstantRecord.pending_count
    end
  end
end

class SseParserTest < Minitest::Test
  def test_parses_events_and_merges_cursor_from_id
    events = []
    parser = InstantRecord::Client::Transport::SseParser.new { |e| events << e }

    parser.feed("id: 42\nevent: change\ndata: {\"type\":\"Memo\",\"id\":\"m-1\"}\n\n")

    assert_equal [{ "type" => "Memo", "id" => "m-1", "cursor" => 42 }], events
  end

  def test_handles_chunks_split_mid_event
    events = []
    parser = InstantRecord::Client::Transport::SseParser.new { |e| events << e }

    parser.feed("id: 7\nevent: change\ndata: {\"a\"")
    assert_empty events

    parser.feed(":1}\n\nid: 8\nevent: change\ndata: {\"a\":2}\n\n")
    assert_equal [{ "a" => 1, "cursor" => 7 }, { "a" => 2, "cursor" => 8 }], events
  end

  def test_ignores_blocks_without_data
    events = []
    parser = InstantRecord::Client::Transport::SseParser.new { |e| events << e }

    parser.feed(": keepalive comment\n\n")
    assert_empty events
  end
end
