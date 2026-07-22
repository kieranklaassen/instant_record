require "test_helper"

ActiveRecord::Schema.define do
  create_table :memos, id: :string, force: true do |t|
    t.string :title
    t.integer :server_version, null: false, default: 0
    t.string :sync_state, null: false, default: "synced"
    t.timestamps
  end
end

class FakeTransport
  attr_reader :posts, :results_to_return
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
    InstantRecord.singleton_class.class_eval do
      alias_method :original_browser?, :browser?
      define_method(:browser?) { true }
    end
    @model = Class.new(ActiveRecord::Base) do
      self.table_name = "memos"
      def self.name = "Memo"
      include InstantRecord::Syncable
    end
    InstantRecord.sync(@model)
    @transport = FakeTransport.new
    @notifier = FakeNotifier.new
    InstantRecord::Client.transport = @transport
    InstantRecord::Client.notifier = @notifier
    @model.delete_all
    InstantRecord::OutboxMutation.delete_all
    InstantRecord::SyncMetadata.delete_all
    InstantRecord.instance_variable_set(:@started, false)
  end

  def teardown
    InstantRecord.sync
    InstantRecord::Client.transport = nil
    InstantRecord::Client.notifier = nil
    InstantRecord.instance_variable_set(:@started, false)
    InstantRecord.singleton_class.class_eval do
      remove_method :browser?
      alias_method :browser?, :original_browser?
      remove_method :original_browser?
    end
  end

  def test_start_is_a_no_op_on_the_server_runtime
    InstantRecord.singleton_class.send(:define_method, :browser?) { false }
    refute InstantRecord.start
    assert_equal :not_started, InstantRecord.tick
  end

  def test_tick_before_start_does_nothing
    assert_equal :not_started, InstantRecord.tick
    assert_empty @transport.posts
  end

  def test_drain_posts_pending_mutations_and_applies_results
    memo = @model.create!(title: "hello")
    mutation_id = InstantRecord::OutboxMutation.sole.id
    @transport.respond_with([{ "mutation_id" => mutation_id, "status" => "applied", "version" => 1 }])

    InstantRecord.start
    assert_equal :ok, InstantRecord.tick

    path, payload = @transport.posts.sole
    assert_equal "/mutations", path
    assert_equal mutation_id, payload[:mutations].first["id"]

    assert_equal 0, InstantRecord.pending_count
    assert_equal "synced", memo.reload.sync_state
    assert_equal 1, @notifier.notifications
  end

  def test_empty_outbox_posts_nothing
    InstantRecord.start
    InstantRecord.tick
    assert_empty @transport.posts
  end

  def test_poll_applies_events_advances_cursor_and_notifies_once
    @transport.events_to_yield = [
      { "type" => "Memo", "id" => "m-1", "operation" => "create", "version" => 1, "cursor" => 7,
        "attributes" => { "id" => "m-1", "title" => "from server", "updated_at" => Time.current.iso8601 } },
      { "type" => "Memo", "id" => "m-2", "operation" => "create", "version" => 1, "cursor" => 8,
        "attributes" => { "id" => "m-2", "title" => "also from server", "updated_at" => Time.current.iso8601 } }
    ]

    InstantRecord.start
    assert_equal :ok, InstantRecord.tick

    assert_equal 2, @model.count
    assert_equal 8, InstantRecord.cursor
    assert_equal 1, @notifier.notifications, "one notification per batch, not per event"
  end

  def test_nothing_changed_means_no_notification
    InstantRecord.start
    InstantRecord.tick
    assert_equal 0, @notifier.notifications
  end

  def test_overlapping_tick_is_skipped_not_queued
    @model.create!(title: "hello")
    nested_result = nil
    @transport.on_post = -> { nested_result = InstantRecord.tick }

    InstantRecord.start
    assert_equal :ok, InstantRecord.tick

    assert_equal :busy, nested_result
    assert_equal 1, @transport.posts.size, "no duplicate POST from the nested tick"
  end

  def test_guard_releases_after_transport_failure
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

  def test_sync_now_works_without_start
    @model.create!(title: "hello")
    mutation_id = InstantRecord::OutboxMutation.sole.id
    @transport.respond_with([{ "mutation_id" => mutation_id, "status" => "applied", "version" => 1 }])

    assert_equal :ok, InstantRecord.sync_now
    assert_equal 0, InstantRecord.pending_count
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
