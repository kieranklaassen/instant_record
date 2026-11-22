require "test_helper"

# Transport double local to this file so it runs standalone.
class EvictionTransport
  attr_reader :history_requests
  attr_accessor :history_pages

  def initialize
    @history_requests = []
    @history_pages = []
  end

  def get_json(path)
    if path.start_with?("/records?")
      @history_requests << path
      return @history_pages.shift || { "records" => [], "has_more" => false }
    end

    { "cursor" => 0, "records" => [] }
  end

  def post_json(_path, _payload) = { "results" => [] }
  def each_event(_path); end
end

class EvictionTest < Minitest::Test
  def setup
    @model = syncable_model("Memo") { sync_window limit: 50, partition_by: :state }
    InstantRecord.sync(@model)
    @transport = EvictionTransport.new
    InstantRecord::Client.transport = @transport
    InstantRecord::Client.notifier = Class.new { def records_changed; end }.new
    reset_instant_record_tables!
    InstantRecord::Client.cursor = 0
    InstantRecord.instance_variable_set(:@started, false)
  end

  def teardown
    InstantRecord.sync
    InstantRecord::Client.transport = nil
    InstantRecord::Client.notifier = nil
    InstantRecord.instance_variable_set(:@started, false)
  end

  def seed_rows(count, state:, start_at:, sync_state: "synced")
    InstantRecord::Client.applying_remote do
      count.times do |i|
        at = start_at + i.minutes
        @model.create!(id: "#{state}-#{format('%03d', i)}", state: state, sync_state: sync_state,
          created_at: at, updated_at: at)
      end
    end
  end

  def cold_boot_tick
    in_browser do
      InstantRecord.start
      InstantRecord.tick
    end
  end

  def test_cold_boot_trims_each_partition_to_its_window
    seed_rows(120, state: "a", start_at: 300.minutes.ago)

    cold_boot_tick

    assert_equal 50, @model.count
    assert_equal "a-070", @model.order(:created_at, :id).first.id, "the newest 50 survive"
  end

  def test_pending_rows_survive_eviction
    seed_rows(60, state: "a", start_at: 300.minutes.ago)
    InstantRecord::Client.applying_remote do
      @model.create!(id: "a-pending", state: "a", sync_state: "pending",
        created_at: 2.days.ago, updated_at: 2.days.ago)
    end

    cold_boot_tick

    assert @model.exists?("a-pending"), "pending rows are never evicted"
    assert_equal 50, @model.where(sync_state: "synced").count
  end

  def test_partitions_trim_independently
    seed_rows(55, state: "a", start_at: 300.minutes.ago)
    seed_rows(3, state: "b", start_at: 300.minutes.ago)

    cold_boot_tick

    assert_equal 50, @model.where(state: "a").count
    assert_equal 3, @model.where(state: "b").count
  end

  def test_eviction_runs_once_per_boot
    seed_rows(55, state: "a", start_at: 600.minutes.ago)
    cold_boot_tick
    assert_equal 50, @model.count

    # Rows re-created mid-session (e.g. history pages, live updates to
    # previously evicted rows) must survive later passes.
    seed_rows(5, state: "a", start_at: 900.minutes.ago)
    in_browser { InstantRecord.tick }

    assert_equal 55, @model.count
  end

  def test_warm_restart_skips_eviction
    seed_rows(55, state: "a", start_at: 300.minutes.ago)

    in_browser do
      InstantRecord.start(cold_boot: false)
      InstantRecord.tick
    end

    assert_equal 55, @model.count
  end

  def test_eviction_produces_no_outbox_mutations
    seed_rows(55, state: "a", start_at: 300.minutes.ago)

    cold_boot_tick

    assert_equal 0, InstantRecord::OutboxMutation.count
  end

  def test_windowless_models_are_untouched
    plain = syncable_model("PlainItem")
    InstantRecord.sync(@model, plain)
    InstantRecord::Client.applying_remote do
      plain.create!(id: "keep-me", title: "windowless", created_at: 2.years.ago, updated_at: 2.years.ago)
    end

    cold_boot_tick

    assert plain.exists?("keep-me")
  end

  def history_payloads(count, state:, start_at:)
    (0...count).map do |i|
      at = start_at + i.minutes
      id = "#{state}-old-#{format('%03d', i)}"
      { "type" => "Memo", "id" => id, "version" => 1,
        "attributes" => { "id" => id, "title" => id, "state" => state,
                          "created_at" => at.utc.iso8601(6), "updated_at" => at.utc.iso8601(6) } }
    end.reverse
  end

  def test_cold_boot_eviction_invalidates_history_marks_so_pagination_refetches_evicted_pages
    start_at = 300.minutes.ago
    seed_rows(50, state: "a", start_at: start_at + 10.minutes)
    older_payloads = history_payloads(10, state: "a", start_at: start_at)
    oldest_in_window = @model.where(state: "a").order(:created_at, :id).first
    cursor = { created_at: oldest_in_window.created_at.utc.iso8601(6), id: oldest_in_window.id }

    # Load history all the way to the beginning (has_more: false).
    @transport.history_pages = [{ "records" => older_payloads, "has_more" => false }]
    in_browser do
      first = InstantRecord.fetch_history(@model, partition: "a", before: cursor, limit: 10)
      assert first[:ok]
      assert_equal 10, first[:applied]
      refute first[:has_more]
    end
    assert_equal 60, @model.where(state: "a").count

    # Cold boot trims the 10 older rows back to the 50-row window.
    cold_boot_tick
    assert_equal 50, @model.where(state: "a").count

    # Scrolling past the window must refetch from the server — NOT return a ghost empty page.
    @transport.history_pages = [{ "records" => older_payloads, "has_more" => false }]
    in_browser do
      after_eviction = InstantRecord.fetch_history(@model, partition: "a", before: cursor, limit: 10)
      assert after_eviction[:ok]
      assert_equal 10, after_eviction[:applied], "evicted page must be refetched, not served as empty local page"
      refute after_eviction[:has_more]
    end
    assert_equal 2, @transport.history_requests.size
    assert_equal 60, @model.where(state: "a").count
  end

  def test_cold_boot_eviction_invalidates_wasm_bridge_history_and_clears_legacy_keys
    start_at = 300.minutes.ago
    seed_rows(50, state: "a", start_at: start_at + 10.minutes)
    oldest_in_window = @model.where(state: "a").order(:created_at, :id).first
    query_key = URI.encode_www_form(
      type: "Memo",
      before_created_at: oldest_in_window.created_at.utc.iso8601(6),
      before_id: oldest_in_window.id,
      limit: "10",
      partition: "a"
    )
    older_payloads = history_payloads(10, state: "a", start_at: start_at)

    # Simulate pre-upgrade legacy exact-key cache entry alongside an unrelated opaque Native key.
    InstantRecord::SyncMetadata.set("history:#{query_key}", "end")
    InstantRecord::SyncMetadata.set("history:older:support", "more")

    # Apply history page through the compiled bridge path.
    applied = InstantRecord::Client.handle_history(
      key: query_key,
      response: JSON.generate(records: older_payloads, has_more: false)
    )
    assert applied[:ok]
    assert_equal 10, applied[:applied]
    assert_equal 60, @model.where(state: "a").count

    # Before eviction, probing the bridge serves locally.
    before_eviction = InstantRecord::Client.handle_history(key: query_key)
    assert before_eviction[:ok]
    assert_equal 0, before_eviction[:applied]
    refute before_eviction[:has_more]

    # Cold boot evicts the 10 older rows.
    cold_boot_tick
    assert_equal 50, @model.where(state: "a").count

    # Bridge probe must now miss (ok: false) so the worker fetches from the server,
    # legacy key for the evicted partition is cleared, and unrelated keys survive.
    after_eviction = InstantRecord::Client.handle_history(key: query_key)
    refute after_eviction[:ok], "evicted page must not report ok: true from stale SyncMetadata"
    assert_nil InstantRecord::SyncMetadata.get("history:#{query_key}")
    assert_equal "more", InstantRecord::SyncMetadata.get("history:older:support")
  end

  def test_eviction_preserves_history_marks_of_untouched_partitions
    start_at = 300.minutes.ago
    seed_rows(55, state: "a", start_at: start_at)
    seed_rows(3, state: "b", start_at: start_at)
    oldest_b = @model.where(state: "b").order(:created_at, :id).first

    # Partition "b" reached beginning of history; partition "a" exceeds window.
    @transport.history_pages = [{ "records" => [], "has_more" => false }]
    in_browser do
      InstantRecord.fetch_history(@model, partition: "b",
        before: { created_at: oldest_b.created_at.utc.iso8601(6), id: oldest_b.id }, limit: 10)
    end
    assert_equal 1, @transport.history_requests.size

    cold_boot_tick
    assert_equal 50, @model.where(state: "a").count
    assert_equal 3, @model.where(state: "b").count

    # Partition "b" had nothing evicted, so its contiguity mark still serves locally.
    in_browser do
      still_local = InstantRecord.fetch_history(@model, partition: "b",
        before: { created_at: oldest_b.created_at.utc.iso8601(6), id: oldest_b.id }, limit: 10)
      assert still_local[:ok]
      refute still_local[:has_more]
    end
    assert_equal 1, @transport.history_requests.size
  end

  def test_unpartitioned_window_eviction_invalidates_its_history_mark
    unpartitioned = syncable_model("LogEntry") { sync_window limit: 2 }
    InstantRecord.sync(unpartitioned)
    now = Time.now.utc
    InstantRecord::Client.applying_remote do
      unpartitioned.create!(id: "l-3", created_at: now - 60, updated_at: now - 60)
      unpartitioned.create!(id: "l-2", created_at: now - 120, updated_at: now - 120)
    end
    old_row = { "type" => "LogEntry", "id" => "l-1", "version" => 1,
                "attributes" => { "id" => "l-1", "title" => "l-1",
                                  "created_at" => (now - 180).iso8601(6), "updated_at" => (now - 180).iso8601(6) } }
    cursor = { created_at: (now - 120).iso8601(6), id: "l-2" }

    @transport.history_pages = [{ "records" => [old_row], "has_more" => false }]
    in_browser { InstantRecord.fetch_history(unpartitioned, before: cursor, limit: 2) }
    assert_equal 3, unpartitioned.count

    cold_boot_tick
    assert_equal 2, unpartitioned.count

    @transport.history_pages = [{ "records" => [old_row], "has_more" => false }]
    in_browser do
      result = InstantRecord.fetch_history(unpartitioned, before: cursor, limit: 2)
      assert result[:ok]
      assert_equal 1, result[:applied]
    end
    assert_equal 2, @transport.history_requests.size
  end
end
