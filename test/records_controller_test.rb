require "test_helper"
require "rails"
require "action_controller"
require "rack/mock"
require File.expand_path("../app/controllers/instant_record/records_controller", __dir__)

class RecordsControllerTest < Minitest::Test
  def setup
    reset_instant_record_tables!
    @previous_scope = InstantRecord.config.scope_from
  end

  def teardown
    InstantRecord.sync
    InstantRecord.config.scope_from = @previous_scope
  end

  def test_multi_tenant_history_pages_return_quiet_tenants_rows_without_starvation_or_leakage
    model = syncable_model("TenantMessage") do
      sync_scope :owner
      sync_window limit: 2, partition_by: :state
    end
    InstantRecord.sync(model)
    InstantRecord.config.scope_from = ->(request) { request.params["scope"] }

    on_server do
      create_row(model, "ada-1", state: "open", owner: "ada", at: 90.minutes.ago)
      create_row(model, "ada-2", state: "open", owner: "ada", at: 80.minutes.ago)
      create_row(model, "ada-3", state: "open", owner: "ada", at: 70.minutes.ago)
      create_row(model, "ada-4", state: "open", owner: "ada", at: 60.minutes.ago)
      5.times { |i| create_row(model, "bob-#{i}", state: "open", owner: "bob", at: (55 + i).minutes.ago) }
    end

    cursor = model.find("ada-3")
    page = fetch_records(type: "TenantMessage", partition: "open", before_at: cursor.created_at, before_id: cursor.id, scope: "ada")

    assert_equal %w[ada-2 ada-1], page.fetch("records").map { |r| r.fetch("id") }
    assert_equal false, page.fetch("has_more")
  end

  def test_history_page_preserves_both_partition_and_visibility_on_same_column
    model = syncable_model("ScopedState") do
      sync_window limit: 2, partition_by: :state
      syncable_to { |who| who&.id ? where(state: ["public", who.id]) : where(state: "public") }
    end
    InstantRecord.sync(model)
    InstantRecord.config.scope_from = ->(request) { Person.new(request.params["scope"]) }

    on_server do
      create_row(model, "pub-1", state: "public", at: 30.minutes.ago)
      create_row(model, "ada-1", state: "ada", at: 20.minutes.ago)
      create_row(model, "ben-1", state: "ben", at: 10.minutes.ago)
    end

    public_page = fetch_records(type: "ScopedState", partition: "public", before_at: Time.zone.now, before_id: "zzz", scope: "ada")
    assert_equal %w[pub-1], public_page.fetch("records").map { |r| r.fetch("id") }

    forbidden_page = fetch_records(type: "ScopedState", partition: "ben", before_at: Time.zone.now, before_id: "zzz", scope: "ada")
    assert_empty forbidden_page.fetch("records")
  end

  def test_window_pages_walk_every_row_once_through_rows_of_one_instant
    model = syncable_model("TiedMessage") { sync_window limit: 2, partition_by: :state }
    InstantRecord.sync(model)
    create_tied_rows(model)

    assert_equal TIED_IDS, walk("TiedMessage", partition: "open", limit: 2)
    assert_equal TIED_IDS, on_postgresql(model) { walk("TiedMessage", partition: "open", limit: 2) }
  end

  def test_shape_pages_walk_every_row_once_through_rows_of_one_instant
    model = syncable_model("TiedShape") { sync_shape limit: 2, roots: -> { where(state: "open") } }
    InstantRecord.sync(model)
    create_tied_rows(model)

    assert_equal TIED_IDS, walk("TiedShape", partition: nil, limit: 2)
    assert_equal TIED_IDS, on_postgresql(model) { walk("TiedShape", partition: nil, limit: 2) }
  end

  def test_pages_bound_created_at_where_the_database_takes_no_range_from_an_or
    window = syncable_model("BoundWindow") { sync_window limit: 2, partition_by: :state }
    shape = syncable_model("BoundShape") { sync_shape limit: 2 }
    InstantRecord.sync(window, shape)
    create_tied_rows(window)

    [window, shape].each do |model|
      pages = -> { page_sql { walk(model.name, partition: "open", limit: 2) } }
      binds = pages.call
      literals = model.connection.unprepared_statement(&pages)
      postgresql = on_postgresql(model, &pages)

      assert_operator binds.size, :>, 1
      assert_equal [binds.size] * 2, [literals.size, postgresql.size]
      literals.each { |sql| refute_match(/created_at"? <= /, sql) }
      (binds + postgresql).each { |sql| assert_match(/created_at"? <= /, sql) }
    end
  end

  def test_a_deep_page_enters_the_index_at_the_page
    model = syncable_model("IndexedWindow") { sync_window limit: 2, partition_by: :state }
    shape = syncable_model("IndexedShape") { sync_shape limit: 2, roots: -> { where(state: "open") } }
    InstantRecord.sync(model, shape)
    create_tied_rows(model)
    connection = model.connection
    connection.add_index :items, %i[state created_at id], name: "items_page"

    [model, shape].each do |type|
      [false, true].each do |unprepared|
        pages = -> { page_plans(connection) { walk(type.name, partition: "open", limit: 2) } }
        plans = unprepared ? connection.unprepared_statement(&pages) : pages.call

        plans.each { |plan| assert_match(/items_page \(state=\? AND created_at<\?\)/, plan) }
      end
    end
  ensure
    connection&.remove_index :items, name: "items_page", if_exists: true
  end

  def test_a_page_asks_for_the_database_without_keeping_a_connection
    model = syncable_model("LeasedShape") { sync_shape limit: 2 }
    pool = model.connection_pool
    pool.release_connection

    assert InstantRecord::SyncShape.needs_range?(model)
    refute pool.active_connection?
  end

  TIED_AT = Time.utc(2026, 11, 20, 12)
  TIED_IDS = %w[n-2 n-1 t-5 t-4 t-3 t-2 t-1 o-2 o-1].freeze

  private

  def create_tied_rows(model)
    on_server do
      2.times { |i| create_row(model, "n-#{i + 1}", state: "open", at: TIED_AT + 1 + i) }
      5.times { |i| create_row(model, "t-#{i + 1}", state: "open", at: TIED_AT) }
      2.times { |i| create_row(model, "o-#{i + 1}", state: "open", at: TIED_AT - 2 + i) }
      create_row(model, "elsewhere", state: "closed", at: TIED_AT)
    end
  end

  # Every id the pages give, newest first, following each page's cursor.
  def walk(type, partition:, limit:)
    at = TIED_AT + 60
    id = "zzz"
    ids = []
    loop do
      page = fetch_records(type: type, partition: partition, before_at: at, before_id: id, scope: nil, limit: limit)
      ids.concat(page.fetch("records").map { |record| record.fetch("id") })
      return ids unless page.fetch("has_more")

      at = Time.zone.parse(page.dig("next_before", "created_at"))
      id = page.dig("next_before", "id")
    end
  end

  # The connection says it is PostgreSQL's for the block; the SQL asked of it
  # is SQL both databases take.
  def on_postgresql(model)
    connection = model.connection
    connection.define_singleton_method(:adapter_name) { "PostgreSQL" }
    yield
  ensure
    connection.singleton_class.send(:remove_method, :adapter_name)
  end

  def page_sql
    seen = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      seen << payload[:sql] if payload[:sql].match?(/FROM "items".*ORDER BY/)
    end
    yield
    seen
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # SQLite's plan for each page query of the block.
  def page_plans(connection)
    seen = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      seen << [payload[:sql], payload[:type_casted_binds]] if payload[:sql].match?(/\ASELECT.*FROM "items".*ORDER BY/)
    end
    yield
    refute_empty seen
    seen.map do |sql, binds|
      binds = binds.call if binds.respond_to?(:call)
      connection.raw_connection.execute("EXPLAIN QUERY PLAN #{sql}", binds.to_a).map { |row| row["detail"] }.join("\n")
    end
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def create_row(model, id, state:, at:, owner: nil)
    model.create!(id: id, title: id, state: state, owner: owner, created_at: at, updated_at: at)
  end

  def fetch_records(type:, partition:, before_at:, before_id:, scope:, limit: nil)
    params = {
      type: type,
      partition: partition,
      before_created_at: before_at.utc.iso8601(6),
      before_id: before_id,
      scope: scope
    }
    params[:limit] = limit if limit
    env = Rack::MockRequest.env_for("/instant_record/records?#{Rack::Utils.build_query(params)}")
    status, _headers, body = InstantRecord::RecordsController.action(:index).call(env)
    assert_equal 200, status

    json = +""
    body.each { |part| json << part }
    body.close if body.respond_to?(:close)
    JSON.parse(json)
  end
end
