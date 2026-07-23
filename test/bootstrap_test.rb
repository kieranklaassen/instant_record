require "test_helper"

# Transport double local to this file so it runs standalone under
# `ruby -Itest test/bootstrap_test.rb` (rake loads all files, order unknown).
class BootstrapTransport
  attr_reader :bootstrap_requests, :event_paths
  attr_accessor :bootstrap_body, :fail_bootstrap, :events_to_yield

  def initialize
    @bootstrap_requests = []
    @event_paths = []
    @bootstrap_body = { "cursor" => 0, "records" => [] }
    @events_to_yield = []
  end

  def get_json(path)
    @bootstrap_requests << path
    raise InstantRecord::Client::Transport::Error, "offline" if fail_bootstrap

    @bootstrap_body
  end

  def post_json(_path, _payload)
    { "results" => [] }
  end

  def each_event(path, &block)
    @event_paths << path
    @events_to_yield.each(&block)
  end
end

class BootstrapTest < Minitest::Test
  def setup
    @model = syncable_model("Memo")
    InstantRecord.sync(@model)
    @transport = BootstrapTransport.new
    InstantRecord::Client.transport = @transport
    InstantRecord::Client.notifier = Class.new { def records_changed; end }.new
    reset_instant_record_tables!
    InstantRecord.instance_variable_set(:@started, false)
  end

  def teardown
    InstantRecord.sync
    InstantRecord::Client.transport = nil
    InstantRecord::Client.notifier = nil
    InstantRecord.instance_variable_set(:@started, false)
  end

  def snapshot_body
    {
      "cursor" => 42,
      "records" => [
        { "type" => "Memo", "id" => "m-1", "version" => 3,
          "attributes" => { "id" => "m-1", "title" => "from snapshot", "updated_at" => Time.current.iso8601 } },
        { "type" => "Memo", "id" => "m-2", "version" => 1,
          "attributes" => { "id" => "m-2", "title" => "also snapshot", "updated_at" => Time.current.iso8601 } }
      ]
    }
  end

  def test_fresh_client_bootstraps_then_polls_from_the_returned_cursor
    @transport.bootstrap_body = snapshot_body

    in_browser do
      InstantRecord.start
      InstantRecord.tick
    end

    assert_equal ["/bootstrap"], @transport.bootstrap_requests
    assert_empty @transport.event_paths, "bootstrap pass must not also poll"
    assert_equal 2, @model.count
    assert_equal 42, InstantRecord.cursor
    assert_equal 3, @model.find("m-1").server_version
    assert_equal "synced", @model.find("m-1").sync_state

    in_browser { InstantRecord.tick }
    assert_includes @transport.event_paths.last, "after=42"
    assert_equal 1, @transport.bootstrap_requests.size, "bootstrap runs once"
  end

  def test_reapplying_the_same_snapshot_is_idempotent
    @transport.bootstrap_body = snapshot_body

    in_browser do
      InstantRecord.start
      InstantRecord.tick
      InstantRecord::SyncMetadata.find_by(key: "cursor")&.destroy!  # simulate crash before cursor write
      InstantRecord.tick
    end

    assert_equal 2, @model.count
    assert_equal 42, InstantRecord.cursor
    assert_equal 2, @transport.bootstrap_requests.size
  end

  def test_existing_client_never_bootstraps
    InstantRecord::Client.cursor = 7

    in_browser do
      InstantRecord.start
      InstantRecord.tick
    end

    assert_empty @transport.bootstrap_requests
    assert_includes @transport.event_paths.last, "after=7"
  end

  def test_failed_bootstrap_retries_next_tick_and_never_polls_from_zero
    @transport.fail_bootstrap = true

    in_browser do
      InstantRecord.start
      InstantRecord.tick
    end

    assert_empty @transport.event_paths, "a failed bootstrap must not fall through to a cursor-0 poll"
    assert_nil InstantRecord::SyncMetadata.get("cursor")

    @transport.fail_bootstrap = false
    @transport.bootstrap_body = snapshot_body
    in_browser { InstantRecord.tick }

    assert_equal 42, InstantRecord.cursor
    assert_equal 2, @model.count
  end

  def test_snapshot_apply_creates_no_outbox_mutations
    @transport.bootstrap_body = snapshot_body

    in_browser do
      InstantRecord.start
      InstantRecord.tick
    end

    assert_equal 0, InstantRecord::OutboxMutation.count
  end

  # KTD2: the cursor is captured before rows, so an event committed between
  # snapshot and response re-applies over the snapshot row. LWW on updated_at
  # must keep the newer of the two — proving the overlap is safe, not doubled.
  def test_overlapping_change_after_snapshot_applies_by_lww
    older = 2.minutes.ago
    @transport.bootstrap_body = {
      "cursor" => 42,
      "records" => [
        { "type" => "Memo", "id" => "m-1", "version" => 1,
          "attributes" => { "id" => "m-1", "title" => "snapshot value", "updated_at" => older.iso8601 } }
      ]
    }
    @transport.events_to_yield = [
      { "type" => "Memo", "id" => "m-1", "operation" => "update", "version" => 2, "cursor" => 43,
        "attributes" => { "id" => "m-1", "title" => "newer value", "updated_at" => Time.current.iso8601 } }
    ]

    in_browser do
      InstantRecord.start
      InstantRecord.tick  # bootstrap applies the snapshot row
      InstantRecord.tick  # next poll delivers the overlapping newer event
    end

    assert_equal 1, @model.count, "overlap upserts, never duplicates"
    assert_equal "newer value", @model.find("m-1").title, "LWW keeps the newer overlapping change"
    assert_equal 43, InstantRecord.cursor
  end
end
