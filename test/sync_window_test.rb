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

  def test_in_window_ranks_strictly_within_base_scope_unpartitioned
    model = windowed_model(limit: 2)
    on_server do
      create_item(model, "ada-1", state: "a", owner: "ada", at: 60.minutes.ago)
      create_item(model, "ada-2", state: "a", owner: "ada", at: 50.minutes.ago)
      create_item(model, "ada-3", state: "a", owner: "ada", at: 40.minutes.ago)
      5.times { |i| create_item(model, "bob-#{i}", state: "a", owner: "bob", at: (10 - i).minutes.ago) }
    end

    window = model.instant_record_sync_window
    ada_scope = model.where(owner: "ada")

    assert_equal %w[ada-2 ada-3], window.in_window(ada_scope).order(:id).pluck(:id)
    assert_equal %w[ada-1], window.beyond_window(ada_scope).pluck(:id)
  end

  def test_in_window_ranks_strictly_within_base_scope_partitioned
    model = windowed_model(limit: 2, partition_by: :state)
    on_server do
      create_item(model, "ada-open-1", state: "open", owner: "ada", at: 60.minutes.ago)
      create_item(model, "ada-open-2", state: "open", owner: "ada", at: 50.minutes.ago)
      create_item(model, "ada-open-3", state: "open", owner: "ada", at: 40.minutes.ago)
      create_item(model, "ada-closed-1", state: "closed", owner: "ada", at: 70.minutes.ago)
      4.times { |i| create_item(model, "bob-open-#{i}", state: "open", owner: "bob", at: (10 - i).minutes.ago) }
    end

    window = model.instant_record_sync_window
    ada_scope = model.where(owner: "ada")

    assert_equal %w[ada-closed-1 ada-open-2 ada-open-3], window.in_window(ada_scope).order(:id).pluck(:id)
    assert_equal %w[ada-open-1], window.beyond_window(ada_scope).pluck(:id)
  end

  def test_in_window_handles_null_relation_and_ordered_selected_scopes
    model = windowed_model(limit: 2)
    on_server do
      create_item(model, "ada-1", state: "a", owner: "ada", at: 30.minutes.ago)
      create_item(model, "ada-2", state: "a", owner: "ada", at: 20.minutes.ago)
      create_item(model, "ada-3", state: "a", owner: "ada", at: 10.minutes.ago)
    end

    window = model.instant_record_sync_window

    assert_empty window.in_window(model.none).pluck(:id)
    assert window.in_window(model.none).null_relation?
    assert_empty window.beyond_window(model.none).pluck(:id)
    assert window.beyond_window(model.none).null_relation?

    custom_scope = model.where(owner: "ada").select(:id, :title).order(:title)
    assert_equal %w[ada-2 ada-3], window.in_window(custom_scope).order(:id).pluck(:id)

    distinct_limited = model.where(owner: "ada").distinct.order(created_at: :desc).limit(2)
    assert_equal %w[ada-2 ada-3], window.in_window(distinct_limited).order(:id).pluck(:id)
    refute_match(/SELECT DISTINCT "items"\."id" FROM "items".*ORDER BY/, window.in_window(distinct_limited).to_sql)

    minimal_scope = Struct.new(:to_sql).new(model.where(owner: "ada").to_sql)
    assert_equal %w[ada-2 ada-3], window.in_window(minimal_scope).order(:id).pluck(:id)
  end

  def test_in_window_and_keyset_below_deduplicate_rows_from_joined_base_scope
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Schema.define do
        create_table :item_grants, id: :string, force: true do |t|
          t.string :item_id
          t.string :grantee
        end
      end
    end

    model = windowed_model(limit: 2)
    on_server do
      create_item(model, "ada-1", state: "a", owner: "ada", at: 30.minutes.ago)
      create_item(model, "ada-2", state: "a", owner: "ada", at: 10.minutes.ago)
    end

    conn = ActiveRecord::Base.connection
    conn.execute("INSERT INTO item_grants (id, item_id, grantee) VALUES ('g1', 'ada-2', 'ada'), ('g2', 'ada-2', 'ada'), ('g3', 'ada-1', 'ada')")

    joined_scope = model.joins("INNER JOIN item_grants ON item_grants.item_id = items.id")
      .where("item_grants.grantee = 'ada'")

    window = model.instant_record_sync_window
    assert_equal %w[ada-1 ada-2], window.in_window(joined_scope).order(:id).pluck(:id)
    assert_equal %w[ada-2 ada-1], window.keyset_below(at: Time.current, id: "zzz", scope: joined_scope).pluck(:id)
  ensure
    ActiveRecord::Base.connection.drop_table(:item_grants, if_exists: true)
  end

  def test_in_window_respects_unscoped_when_model_has_default_scope
    model = syncable_model("ActiveOnlyItem") do
      default_scope { where(state: "active") }
      sync_window limit: 2
    end
    on_server do
      create_item(model, "archived-1", state: "archived", at: 30.minutes.ago)
      create_item(model, "active-1", state: "active", at: 20.minutes.ago)
      create_item(model, "archived-2", state: "archived", at: 10.minutes.ago)
    end

    window = model.instant_record_sync_window
    assert_equal %w[active-1], window.in_window.pluck(:id)
    assert_equal %w[active-1 archived-2], window.in_window(model.unscoped).order(:id).pluck(:id)
  end

  def test_keyset_below_combines_partition_and_scope_on_same_column_and_reorders
    model = windowed_model(limit: 2, partition_by: :state)
    on_server do
      create_item(model, "pub-1", state: "public", at: 40.minutes.ago)
      create_item(model, "pub-2", state: "public", at: 30.minutes.ago)
      create_item(model, "ada-1", state: "ada", at: 20.minutes.ago)
      create_item(model, "ben-1", state: "ben", at: 10.minutes.ago)
    end

    window = model.instant_record_sync_window
    visible = model.where(state: %w[public ada]).select(:id, :title).order(:id)

    page = window.keyset_below(at: Time.current, id: "zzz", partition: "public", scope: visible).to_a
    assert_equal %w[pub-2 pub-1], page.map(&:id)
    assert_equal [1, 1], page.map(&:server_version), "custom select on scope must not strip serialized attributes"
    assert_empty window.keyset_below(at: Time.current, id: "zzz", partition: "ben", scope: visible).pluck(:id)
    assert_empty window.keyset_below(at: Time.current, id: "zzz", partition: "public", scope: model.none).pluck(:id)
  end

  private

  def windowed_model(limit:, partition_by: nil)
    syncable_model("WindowedItem") { sync_window limit: limit, partition_by: partition_by }
  end

  def create_item(model, id, state:, at:, owner: nil)
    model.create!(id: id, title: id, state: state, owner: owner, created_at: at, updated_at: at)
  end
end
