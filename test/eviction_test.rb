require "test_helper"

# Transport double local to this file so it runs standalone.
class EvictionTransport
  def get_json(_path) = { "cursor" => 0, "records" => [] }
  def post_json(_path, _payload) = { "results" => [] }
  def each_event(_path); end
end

class EvictionTest < Minitest::Test
  def setup
    @model = syncable_model("Memo") { sync_window limit: 50, partition_by: :state }
    InstantRecord.sync(@model)
    InstantRecord::Client.transport = EvictionTransport.new
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
end
