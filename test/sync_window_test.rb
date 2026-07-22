require "test_helper"

class SyncWindowTest < Minitest::Test
  def setup
    reset_instant_record_tables!
  end

  def test_partitioned_window_returns_newest_n_per_partition
    model = windowed_model(limit: 2, partition_by: :state)
    on_server do
      create_item(model, "a-old", state: "a", at: 30.minutes.ago)
      create_item(model, "a-mid", state: "a", at: 20.minutes.ago)
      create_item(model, "a-new", state: "a", at: 10.minutes.ago)
      create_item(model, "b-only", state: "b", at: 40.minutes.ago)
    end

    window = model.instant_record_sync_window
    assert_equal %w[a-mid a-new b-only], window.in_window.order(:id).pluck(:id)
    assert_equal %w[a-old], window.beyond_window.pluck(:id)
  end

  def test_unpartitioned_window_returns_newest_n_overall
    model = windowed_model(limit: 2)
    on_server do
      create_item(model, "one", state: "a", at: 30.minutes.ago)
      create_item(model, "two", state: "b", at: 20.minutes.ago)
      create_item(model, "three", state: "c", at: 10.minutes.ago)
    end

    window = model.instant_record_sync_window
    assert_equal %w[three two], window.in_window.order(created_at: :desc).pluck(:id)
    assert_equal %w[one], window.beyond_window.pluck(:id)
  end

  def test_partition_smaller_than_limit_keeps_all_rows
    model = windowed_model(limit: 5, partition_by: :state)
    on_server { create_item(model, "solo", state: "a", at: 1.hour.ago) }

    assert_equal %w[solo], model.instant_record_sync_window.in_window.pluck(:id)
    assert_empty model.instant_record_sync_window.beyond_window.pluck(:id)
  end

  def test_created_at_ties_break_by_id
    model = windowed_model(limit: 1, partition_by: :state)
    tie = Time.current.change(usec: 0)
    on_server do
      create_item(model, "tie-a", state: "a", at: tie)
      create_item(model, "tie-b", state: "a", at: tie)
    end

    assert_equal %w[tie-b], model.instant_record_sync_window.in_window.pluck(:id)
    assert_equal %w[tie-a], model.instant_record_sync_window.beyond_window.pluck(:id)
  end

  def test_model_without_declaration_reports_no_window
    model = syncable_model("PlainItem")
    assert_nil model.instant_record_sync_window
  end

  def test_non_positive_limit_fails_fast
    error = assert_raises(ArgumentError) { windowed_model(limit: 0) }
    assert_match(/limit/, error.message)
  end

  def test_unknown_partition_column_fails_on_first_use
    model = windowed_model(limit: 2, partition_by: :nonexistent)
    error = assert_raises(ArgumentError) { model.instant_record_sync_window.in_window.to_a }
    assert_match(/nonexistent/, error.message)
  end

  private

  def windowed_model(limit:, partition_by: nil)
    syncable_model("WindowedItem") { sync_window limit: limit, partition_by: partition_by }
  end

  def create_item(model, id, state:, at:)
    model.create!(id: id, title: id, state: state, created_at: at, updated_at: at)
  end
end
