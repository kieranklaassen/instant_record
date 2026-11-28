require "test_helper"

class SyncShapeTest < Minitest::Test
  def setup
    reset_instant_record_tables!
  end

  def test_joined_roots_keyset_paging_qualifies_columns_and_walks_pages
    connection = ActiveRecord::Base.connection
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Schema.define do
        create_table :item_tags, id: :string, force: true do |t|
          t.string :item_id, null: false
          t.string :tag, null: false
          t.timestamps
        end
      end
    end

    model = syncable_model("TaggedItem") do
      sync_shape(
        limit: 2,
        roots: -> { joins("INNER JOIN item_tags ON item_tags.item_id = items.id").where("item_tags.tag = ?", "inbox") }
      )
    end

    tie = Time.utc(2026, 11, 20, 12, 0, 0)
    on_server do
      model.create!(id: "i-1", title: "one", state: "open", created_at: tie - 2, updated_at: tie - 2)
      model.create!(id: "i-2", title: "two", state: "open", created_at: tie, updated_at: tie)
      model.create!(id: "i-3", title: "three", state: "open", created_at: tie, updated_at: tie)
      model.create!(id: "i-4", title: "four", state: "open", created_at: tie + 2, updated_at: tie + 2)
      model.create!(id: "other", title: "other", state: "open", created_at: tie + 5, updated_at: tie + 5)
    end

    tag_time = tie.iso8601(6)
    %w[i-1 i-2 i-3 i-4].each_with_index do |item_id, idx|
      connection.execute(
        "INSERT INTO item_tags (id, item_id, tag, created_at, updated_at) " \
        "VALUES ('t-#{idx}', '#{item_id}', 'inbox', '#{tag_time}', '#{tag_time}')"
      )
    end
    connection.execute(
      "INSERT INTO item_tags (id, item_id, tag, created_at, updated_at) " \
      "VALUES ('t-other', 'other', 'archive', '#{tag_time}', '#{tag_time}')"
    )

    shape = model.instant_record_sync_shape
    walk = lambda do
      seen = []
      before_at = nil
      before_id = nil
      loop do
        res = shape.page(model.all, before_at: before_at, before_id: before_id, limit: 2)
        seen.concat(res[:records].map(&:id))
        break unless res[:has_more]

        before_at = Time.zone.parse(res[:next_before][:created_at])
        before_id = res[:next_before][:id]
      end
      seen
    end

    assert_equal %w[i-4 i-3 i-2 i-1], walk.call
    assert_equal %w[i-4 i-3 i-2 i-1], connection.unprepared_statement(&walk)
  ensure
    ActiveRecord::Base.connection.drop_table(:item_tags, if_exists: true)
  end

  def test_keyset_page_preserves_sqlite_index_range_plan
    model = syncable_model("IndexedShape") { sync_shape limit: 2, roots: -> { where(state: "open") } }
    connection = model.connection
    connection.add_index :items, %i[state created_at id], name: "items_shape_page"

    tie = Time.utc(2026, 11, 20, 12, 0, 0)
    on_server do
      model.create!(id: "i-1", title: "one", state: "open", created_at: tie - 1, updated_at: tie - 1)
      model.create!(id: "i-2", title: "two", state: "open", created_at: tie, updated_at: tie)
      model.create!(id: "i-3", title: "three", state: "open", created_at: tie + 1, updated_at: tie + 1)
    end

    shape = model.instant_record_sync_shape
    [false, true].each do |unprepared|
      seen = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        seen << [payload[:sql], payload[:type_casted_binds]] if payload[:sql].match?(/\ASELECT.*FROM "items".*ORDER BY/)
      end
      begin
        run = -> { shape.page(model.all, before_at: tie + 10, before_id: "zzz", limit: 2) }
        unprepared ? connection.unprepared_statement(&run) : run.call
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      refute_empty seen
      seen.each do |sql, binds|
        binds = binds.call if binds.respond_to?(:call)
        plan = connection.raw_connection.execute("EXPLAIN QUERY PLAN #{sql}", binds.to_a).map { |row| row["detail"] }.join("\n")
        assert_match(/items_shape_page \(state=\? AND created_at<\?\)/, plan)
      end
    end
  ensure
    connection&.remove_index :items, name: "items_shape_page", if_exists: true
  end

  def test_validates_fill_page_size_and_fill_budget_bytes
    model = syncable_model("ValidatedShape")

    [0, -1, "10", 1.5, false].each do |bad|
      err = assert_raises(ArgumentError) do
        InstantRecord::SyncShape.new(model, fill_page_size: bad)
      end
      assert_match(/fill_page_size/, err.message)

      err = assert_raises(ArgumentError) do
        InstantRecord::SyncShape.new(model, fill_budget_bytes: bad)
      end
      assert_match(/fill_budget_bytes/, err.message)
    end

    default_shape = InstantRecord::SyncShape.new(model, limit: 10, max_limit: 75, background_fill: true)
    assert_equal 75, default_shape.fill_page_size
    assert_nil default_shape.fill_budget_bytes
    assert_equal({ type: "ValidatedShape", page_size: 75 }, default_shape.fill_descriptor)

    configured = InstantRecord::SyncShape.new(
      model,
      limit: 10,
      max_limit: 75,
      background_fill: true,
      fill_page_size: 25,
      fill_budget_bytes: 1_048_576
    )
    assert_equal 25, configured.fill_page_size
    assert_equal 1_048_576, configured.fill_budget_bytes
    assert_equal(
      { type: "ValidatedShape", page_size: 25, budget_bytes: 1_048_576 },
      configured.fill_descriptor
    )
  end

  def test_page_handles_nil_created_at_on_last_record
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Schema.define do
        create_table :nullable_items, id: :string, force: true do |t|
          t.string :title
          t.integer :server_version, null: false, default: 0
          t.string :sync_state, null: false, default: "synced"
          t.timestamps null: true
        end
      end
    end

    model = Class.new(ActiveRecord::Base) do
      self.table_name = "nullable_items"
      define_singleton_method(:name) { "NullableItem" }
      include InstantRecord::Syncable
      sync_shape limit: 2
    end

    ActiveRecord::Base.connection.execute(
      "INSERT INTO nullable_items (id, title, server_version, sync_state, created_at, updated_at) " \
      "VALUES ('nil-1', 'no timestamp', 1, 'synced', NULL, NULL)"
    )

    page = model.instant_record_sync_shape.page(model.all, limit: 2)
    assert_equal %w[nil-1], page[:records].map(&:id)
    assert_equal false, page[:has_more]
    assert_nil page[:next_before]
  ensure
    ActiveRecord::Base.connection.drop_table(:nullable_items, if_exists: true)
  end
end
