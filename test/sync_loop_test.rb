require "test_helper"

class FakeTransport
  attr_reader :posts
  attr_accessor :events_to_yield, :on_post

  def initialize
    @posts = []
    @events_to_yield = []
    @results_to_return = []
  end

  def respond_with(results)
    @results_to_return = results
  end

  def post_json(path, payload)
    @on_post&.call
    @posts << [path, payload]
    { "results" => @results_to_return }
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

  def test_nothing_changed_means_no_notification
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
    in_browser do
      @model.create!(title: "hello")
      failing = Object.new
      def failing.post_json(*) = raise(InstantRecord::Client::Transport::Error, "offline")
      def failing.each_event(*) = raise(InstantRecord::Client::Transport::Error, "offline")
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
