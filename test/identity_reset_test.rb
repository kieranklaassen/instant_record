require "test_helper"

# What a browser does when the server says the person behind it has changed.
class IdentityResetTransport
  attr_reader :event_paths, :posted
  attr_accessor :bootstrap_body, :events

  def initialize
    @event_paths = []
    @posted = []
    @events = []
    @bootstrap_body = { "cursor" => 0, "records" => [] }
  end

  def get_json(_path) = @bootstrap_body

  def post_json(_path, payload)
    @posted << payload
    { "results" => [] }
  end

  def each_event(path, &block)
    @event_paths << path
    @events.each(&block)
  end
end

class IdentityResetTest < Minitest::Test
  RESET = { "operation" => "reset", "types" => ["Secret"], "identity" => "key-of-ben" }.freeze

  def setup
    @secret = syncable_model("Secret")
    # Its own table: the reset empties a type's whole table, and the helper's
    # models all share one.
    ActiveRecord::Schema.define do
      create_table :open_items, id: :string, force: true do |t|
        t.string :title
        t.integer :server_version, null: false, default: 0
        t.string :sync_state, null: false, default: "synced"
        t.timestamps
      end
    end
    @open = syncable_model("Open") { self.table_name = "open_items" }
    InstantRecord.sync(@secret, @open)
    @transport = IdentityResetTransport.new
    InstantRecord::Client.transport = @transport
    InstantRecord::Client.notifier = Class.new { def records_changed; end }.new
    InstantRecord::Client.streaming = false
    reset_instant_record_tables!
    InstantRecord.instance_variable_set(:@started, false)
  end

  def teardown
    # A poll called on its own leaves its notice for the pass that would follow.
    InstantRecord::Client.notify_changed
    InstantRecord.sync
    InstantRecord::Client.transport = nil
    InstantRecord::Client.notifier = nil
    InstantRecord.instance_variable_set(:@started, false)
  end

  def record(type, id)
    { "type" => type, "id" => id, "version" => 1,
      "attributes" => { "id" => id, "title" => "#{type} #{id}", "updated_at" => Time.current.iso8601 } }
  end

  def sync_as(key, records)
    @transport.bootstrap_body = { "cursor" => 9, "identity" => key, "records" => records }
    in_browser do
      InstantRecord.start
      InstantRecord.tick
    end
  end

  def test_bootstrap_keeps_the_key_and_later_requests_carry_it
    sync_as("key-of-ada", [record("Secret", "s-1")])
    in_browser do
      @open.create!(id: "o-1", title: "queued")
      InstantRecord.tick
    end

    assert_equal "key-of-ada", InstantRecord::Client.identity_key
    assert_equal "/events?after=9&window=0&identity=key-of-ada", @transport.event_paths.last
    assert_equal "key-of-ada", @transport.posted.last[:identity]
  end

  def test_a_server_without_identities_changes_nothing_on_the_wire
    @transport.bootstrap_body = { "cursor" => 9, "records" => [] }
    in_browser do
      InstantRecord.start
      InstantRecord.tick
      @open.create!(id: "o-1", title: "queued")
      InstantRecord.tick
    end

    assert_nil InstantRecord::Client.identity_key
    assert_equal "/events?after=9&window=0", @transport.event_paths.last
    assert_equal [:mutations], @transport.posted.last.keys
  end

  def test_a_reset_drops_the_named_types_their_queued_writes_and_the_cursor_and_nothing_else
    sync_as("key-of-ada", [record("Secret", "s-1"), record("Open", "o-1")])
    in_browser do
      @secret.create!(id: "s-2", title: "queued as ada")
      @open.find("o-1").update!(title: "queued for everyone")
    end
    InstantRecord::SyncMetadata.set("history:Secret", "more")
    InstantRecord::SyncMetadata.set("compiled_models", "Open,Secret")
    @transport.events = [RESET, record("Secret", "s-3").merge("operation" => "create", "cursor" => 12)]

    in_browser { InstantRecord::Client.poll_changes }

    assert_equal 0, @secret.count, "a change that follows the reset must not be applied either"
    assert_equal %w[o-1], @open.pluck(:id)
    assert_equal %w[Open], InstantRecord::OutboxMutation.pluck(:record_type)
    refute InstantRecord::Client.bootstrapped?
    assert_nil InstantRecord::Client.identity_key
    assert_nil InstantRecord::SyncMetadata.get("history:Secret")
    assert_equal "Open,Secret", InstantRecord::SyncMetadata.get("compiled_models")
  end

  def test_the_poll_after_the_new_bootstrap_starts_where_the_old_one_stopped
    sync_as("key-of-ada", [record("Open", "o-1")])
    @transport.events = [RESET]
    in_browser { InstantRecord.tick }
    @transport.events = []
    @transport.bootstrap_body = { "cursor" => 20, "identity" => "key-of-ben", "records" => [] }
    in_browser { 2.times { InstantRecord.tick } }

    assert_equal "/events?after=9&window=0&identity=key-of-ben", @transport.event_paths.last,
      "a destroy between the two cursors would otherwise never reach the rows that stayed"
    assert_nil InstantRecord::SyncMetadata.get("replay_from")
  end

  def test_the_pass_after_a_reset_bootstraps_as_the_new_identity
    sync_as("key-of-ada", [record("Secret", "s-1")])
    @transport.events = [RESET]
    in_browser { InstantRecord.tick }

    @transport.events = []
    @transport.bootstrap_body = { "cursor" => 20, "identity" => "key-of-ben", "records" => [record("Secret", "s-9")] }
    in_browser { InstantRecord.tick }

    assert_equal %w[s-9], @secret.pluck(:id)
    assert_equal "key-of-ben", InstantRecord::Client.identity_key
    assert InstantRecord::Client.bootstrapped?
  end

  def test_a_reset_delivered_through_a_held_stream_leaves_the_client_unbootstrapped
    sync_as("key-of-ada", [record("Secret", "s-1")])

    applied = in_browser { InstantRecord::Client.consume_stream("event: reset\ndata: #{RESET.to_json}\n\n") }

    assert_equal 1, applied
    assert_equal 0, @secret.count
    refute InstantRecord::Client.bootstrapped?
  end
end
