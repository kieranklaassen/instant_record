require "test_helper"
require "rails"
require "action_controller"
require "rack/mock"
require "instant_record/shell"
require "instant_record/testing"
require File.expand_path("../app/controllers/instant_record/bootstraps_controller", __dir__)
require File.expand_path("../app/controllers/instant_record/records_controller", __dir__)

# Clocks read in batches: the same JSON the single forms give, in a fixed
# number of queries.
class PayloadBatchTest < Minitest::Test
  HLC = InstantRecord::HLC

  def setup
    @open = syncable_model("Open")
    @ruled = syncable_model("Ruled") { syncable_to { |owner| where(owner: owner) } }
    InstantRecord.sync(@open, @ruled)
    reset_instant_record_tables!
  end

  def teardown
    InstantRecord.sync
  end

  def seed(model, count, prefix: model.name.downcase, owner: "ada")
    on_server { count.times { |i| model.create!(id: "#{prefix}-#{i}", title: "t#{i}", owner: owner) } }
  end

  # Statements that reached the database, cache hits left out.
  def sql
    statements = []
    counter = lambda do |*, payload|
      statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    statements
  end

  # How many rows of @open were asked for their `attributes`.
  def columns_asked(&block)
    calls = 0
    method = ActiveRecord::AttributeMethods.instance_method(:attributes)
    TracePoint.new(:call) { |trace| calls += 1 if trace.self.instance_of?(@open) }.enable(target: method, &block)
    calls
  end

  # What events_for did before it read clocks together.
  def one_by_one(changes, identity)
    changes.map do |change|
      next [change.id, change.as_event] if change.operation == "destroy" || change.record_type == "Open"

      record = @ruled.where(owner: identity).find_by(id: change.record_id)
      event =
        if record
          InstantRecord.record_payload(record).merge(operation: change.operation)
        else
          { type: change.record_type, id: change.record_id, operation: "destroy", version: 0, attributes: {} }
        end
      [change.id, event]
    end
  end

  def test_record_payloads_are_the_single_payloads
    seed(@open, 4)
    HLC.delete_record_hlc("Open", "open-1")
    InstantRecord::SyncMetadata.set("#{HLC::RECORD_PREFIX}Open:open-2", "not a clock")
    records = @open.order(:id).to_a

    batched = InstantRecord.record_payloads(records)

    assert_equal records.map { |record| InstantRecord.record_payload(record) }.to_json, batched.to_json
    refute batched[1].key?(:hlc)
    assert_equal "not a clock", batched[2][:hlc]
    assert HLC.valid?(batched[3][:hlc])
    assert_equal batched.to_json, InstantRecord.record_payloads(@open.order(:id)).to_json
  end

  # Rows of one query are read together. Each of these has a row that differs.
  def test_a_relation_of_unlike_rows_is_the_single_payloads
    extension = Module.new { def attributes = super.slice("id", "title").merge("extra" => 1) }
    # A saved change leaves a row's attributes in another order.
    reorder = lambda do |record|
      next unless record.id.to_s.end_with?("-2")

      record.state = "closed"
      record.send(:clear_changes_information)
    end
    models = {
      "answers for its attributes" => syncable_model { def attributes = super.except("owner").merge("extra" => 1) },
      "answers for one attribute" => syncable_model { def _read_attribute(name, &block) = name == "title" ? "other" : super },
      "has other readers" => syncable_model { def title = "reader" },
      "has a virtual attribute" => syncable_model { attribute :virtual, :integer, default: 7 },
      "extends one row" => syncable_model { after_find { extend(extension) if id.end_with?("-0") } },
      "extends another row" => syncable_model { after_find { extend(extension) if id.end_with?("-2") } },
      "reorders one row as it is found" => syncable_model { after_find { reorder.call(self) } },
      "reorders one row as it is made" => syncable_model { after_initialize { reorder.call(self) } }
    }
    seed(@open, 4)

    models.each do |how, model|
      singles = model.order(:id).map { |record| InstantRecord.record_payload(record) }
      assert_equal singles.to_json, InstantRecord.record_payloads(model.order(:id)).to_json, how
      assert_equal singles.to_json, InstantRecord.record_payloads(model.order(:id).load).to_json, how
    end

    loaded = @open.order(:id).load
    reorder.call(loaded.to_a[2])
    assert_equal loaded.map { |record| InstantRecord.record_payload(record) }.to_json, InstantRecord.record_payloads(loaded).to_json
  end

  def test_an_extended_relation_is_the_single_payloads
    hiding = Module.new { def attributes = super.except("owner") }
    extension = Module.new do
      define_method(:records) { super().each { |record| record.extend(hiding) if record.id.end_with?("-2") } }
    end
    seed(@open, 4)

    rows = @open.order(:id).extending(extension)
    singles = rows.spawn.map { |record| InstantRecord.record_payload(record) }

    refute singles[2][:attributes].key?("owner")
    assert_equal singles.to_json, InstantRecord.record_payloads(rows.spawn).to_json
  end

  # As above, with the relation given the same by Object#extend, and by a
  # method of its own. The extension's method may be private.
  def test_a_relation_with_methods_of_its_own_is_the_single_payloads
    hiding = Module.new { def attributes = super.except("owner") }
    hide = ->(records) { records.each { |record| record.extend(hiding) if record.id.end_with?("-2") } }
    open = Module.new { define_method(:records) { hide.call(super()) } }
    hidden = Module.new do
      define_method(:exec_queries) { |&block| hide.call(super(&block)) }
      private :exec_queries
    end
    seed(@open, 4)

    {
      "extended" => ->(rows) { rows.extend(open) },
      "extended in private" => ->(rows) { rows.extend(hidden) },
      "by extending, in private" => ->(rows) { rows.extending(hidden) },
      "its own" => ->(rows) { rows.tap { rows.define_singleton_method(:records) { hide.call(super()) } } }
    }.each do |how, change|
      singles = change.call(@open.order(:id)).to_a.map { |record| InstantRecord.record_payload(record) }

      refute singles[2][:attributes].key?("owner"), how
      assert_equal singles.to_json, InstantRecord.record_payloads(change.call(@open.order(:id))).to_json, how
    end
  end

  # A collection puts the rows it was given in place of the ones it reads.
  def test_an_associations_collection_is_the_single_payloads
    children
    given = @open.find("open-2")
    given.extend(Module.new { def attributes = super.except("title") })
    rows = @open.find("parent").children
    on_server { rows << given }
    refute rows.loaded?

    batched = InstantRecord.record_payloads(rows)

    assert_equal rows.map { |record| InstantRecord.record_payload(record) }.to_json, batched.to_json
    assert_equal 1, batched.count { |payload| !payload[:attributes].key?("title") }
  end

  # The output is the same either way: these rows are asked one by one because
  # Active Record makes them from a join.
  def test_eager_loaded_rows_are_asked_one_by_one
    children
    rows = @open.where(owner: "parent").eager_load(:children).order(:id)
    singles = rows.spawn.map { |record| InstantRecord.record_payload(record) }

    assert_equal singles.to_json, InstantRecord.record_payloads(rows.spawn).to_json
    assert_equal 4, columns_asked { InstantRecord.record_payloads(rows.spawn) }
  end

  # The output is the same either way, so this is what says the rows of a
  # bootstrap are read by name.
  def test_a_relation_asks_one_row_of_a_class_for_its_columns
    seed(@open, 4)

    assert_equal 1, columns_asked { InstantRecord.record_payloads(@open.order(:id)) }
    assert_equal 4, columns_asked { InstantRecord.record_payloads(@open.order(:id).to_a) }
    assert_equal 4, columns_asked { InstantRecord.record_payloads(@open.order(:id).load) }
    assert_equal 1, columns_asked { get(InstantRecord::BootstrapsController, :show) }
  end

  def test_rows_of_several_classes_and_selections_are_the_single_payloads
    base = syncable_model("Base") { self.inheritance_column = "state" }
    wide = Class.new(base) { attribute :virtual, :integer, default: 3 }
    narrow = Class.new(base) { def attributes = super.except("owner") }
    classes = { "wide" => wide, "narrow" => narrow }
    base.define_singleton_method(:find_sti_class) { |name| classes.fetch(name, base) }
    seed(@open, 6)
    @open.where(id: %w[open-1 open-4]).update_all(state: "wide")
    @open.where(id: %w[open-2 open-5]).update_all(state: "narrow")

    [
      base.order(:id),
      @open.order(:id).select(:id, :title, :server_version),
      @open.order(:id).select("items.*", "1 + 1 AS two")
    ].each do |rows|
      singles = rows.spawn.map { |record| InstantRecord.record_payload(record) }
      assert_equal singles.to_json, InstantRecord.record_payloads(rows.spawn).to_json
    end
  end

  def test_events_are_the_single_events
    seed(@open, 3)
    seed(@ruled, 3)
    seed(@ruled, 2, prefix: "hidden", owner: "bob")
    on_server do
      @ruled.find("ruled-0").update!(title: "again")
      @ruled.find("ruled-2").destroy!
      @open.find("open-2").destroy!
    end
    ids = InstantRecord::Change.order(:id).pluck(:id)
    InstantRecord::SyncMetadata.delete("#{HLC::CHANGE_PREFIX}#{ids[0]}")
    InstantRecord::SyncMetadata.set("#{HLC::CHANGE_PREFIX}#{ids[1]}", "not a clock")
    HLC.delete_record_hlc("Ruled", "ruled-1")
    changes = InstantRecord::Change.order(:id).to_a

    batched = InstantRecord::SyncScope.events_for(changes, "ada")

    assert_equal one_by_one(changes, "ada").to_json, batched.to_json
    refute batched[0].last.key?(:hlc)
    assert_equal "not a clock", batched[1].last[:hlc]
  end

  def test_record_payloads_read_every_clock_at_once
    seed(@open, 30)
    records = @open.all.to_a

    assert_equal 1, sql { InstantRecord.record_payloads(records) }.size
    assert_empty sql { InstantRecord.record_payloads([]) }
  end

  def test_events_take_the_same_queries_however_many_changes
    seed(@open, 30)
    changes = InstantRecord::Change.order(:id).to_a
    assert_equal 1, sql { InstantRecord::SyncScope.events_for(changes, "ada") }.size

    seed(@ruled, 30)
    changes = InstantRecord::Change.order(:id).to_a

    # The visible rows, their clocks, and the open changes' clocks.
    assert_equal 3, sql { InstantRecord::SyncScope.events_for(changes, "ada") }.size
    assert_empty sql { InstantRecord::SyncScope.events_for([], "ada") }
  end

  def test_a_long_list_of_clocks_is_read_in_slices
    slice = InstantRecord::PayloadBatch::SLICE
    last = "#{HLC::CHANGE_PREFIX}#{slice + 1}"
    InstantRecord::SyncMetadata.set(last, "stamp")
    keys = (1..slice + 1).map { |id| "#{HLC::CHANGE_PREFIX}#{id}" }
    stamps = nil

    assert_equal 2, sql { stamps = InstantRecord::PayloadBatch.stamps(keys) }.size
    assert_equal({ last => "stamp" }, stamps)
  end

  def test_a_poll_inside_a_query_cache_sees_a_clock_written_elsewhere
    key = "#{HLC::CHANGE_PREFIX}1"
    InstantRecord::SyncMetadata.set(key, "old")

    ActiveRecord::Base.cache do
      InstantRecord::PayloadBatch.stamps([key])
      # Straight to the driver, as another process would: no cache is cleared.
      ActiveRecord::Base.connection.raw_connection
        .execute("UPDATE instant_record_sync_metadata SET value = 'new' WHERE key = '#{key}'")

      assert_equal({ key => "new" }, InstantRecord::PayloadBatch.stamps([key]))
    end
  end

  def test_bootstrap_sends_the_single_payloads_for_whole_shaped_and_windowed_models
    shaped = syncable_model("Shaped") { sync_shape limit: 10 }
    windowed = syncable_model("Windowed") { sync_window limit: 10 }

    [@open, shaped, windowed].each do |model|
      reset_instant_record_tables!
      InstantRecord.sync(model)
      seed(model, 3)
      records = nil
      few = sql { records = get(InstantRecord::BootstrapsController, :show) }.size
      assert_sends_single_payloads(model, records, 3)

      seed(model, 4, prefix: "more")
      assert_equal few, sql { get(InstantRecord::BootstrapsController, :show) }.size, model.name
    end
  end

  def test_a_shaped_lookup_and_page_send_the_single_payloads
    shaped = syncable_model("Shaped") { sync_shape limit: 10 }
    InstantRecord.sync(shaped)
    seed(shaped, 3)

    assert_sends_single_payloads(shaped, get(InstantRecord::RecordsController, :index, type: "Shaped", id: "shaped-1"), 1)
    older = { type: "Shaped", before_created_at: 1.hour.from_now.utc.iso8601(6), before_id: "zzz" }
    assert_sends_single_payloads(shaped, get(InstantRecord::RecordsController, :index, **older), 3)
  end

  def test_a_window_page_sends_the_single_payloads
    windowed = syncable_model("Windowed") { sync_window limit: 10 }
    InstantRecord.sync(windowed)
    seed(windowed, 3)

    older = { type: "Windowed", before_created_at: 1.hour.from_now.utc.iso8601(6), before_id: "zzz" }
    assert_sends_single_payloads(windowed, get(InstantRecord::RecordsController, :index, **older), 3)
  end

  def test_a_shell_snapshot_holds_the_single_payloads
    seed(@open, 3)

    records = InstantRecord::Shell.snapshot(models: [@open])[:records]
    assert_sends_single_payloads(@open, JSON.parse(records.to_json), 3)
  end

  def test_the_standalone_server_sends_the_single_payloads
    server = InstantRecord::Testing::AuthoritativeServer.build(database_url: nil)
    windowed = syncable_model("Windowed") do
      self.table_name = "issues"
      sync_window limit: 10
    end
    server.send(:with_server_shard) do
      InstantRecord.sync(windowed)
      on_server { 3.times { |i| windowed.create!(id: "w-#{i}", title: "t#{i}") } }
      url = "/instant_record/records?" + Rack::Utils.build_query(
        type: "Windowed", before_created_at: 1.hour.from_now.utc.iso8601(6), before_id: "zzz"
      )

      response = server.exchange("GET", url)
      assert_equal 200, response[:status]
      assert_sends_single_payloads(windowed, JSON.parse(response[:body]).fetch("records"), 3)
    end
  ensure
    server&.close
  end

  def test_record_payloads_exact_parity_across_types_timezones_and_edge_cases
    ActiveRecord::Schema.define do
      create_table :rich_items, id: :string, force: true do |t|
        t.string :title
        t.text :body
        t.integer :count
        t.boolean :active
        t.date :due_on
        t.datetime :happened_at
        t.integer :server_version
        t.timestamps
      end
    end

    custom_usec_class = Struct.new(:stamp) do
      def usec = 0
      def iso8601(precision = 0) = "#{stamp}.#{'0' * precision}Z"
    end
    custom_type = Class.new(ActiveModel::Type::Value) do
      define_method(:deserialize) { |v| v ? custom_usec_class.new(v) : nil }
    end

    rich = Class.new(ActiveRecord::Base) do
      self.table_name = "rich_items"
      define_singleton_method(:name) { "RichItem" }
      include InstantRecord::Syncable
      attribute :title, custom_type.new
    end

    plain_rich = Class.new(ActiveRecord::Base) do
      self.table_name = "rich_items"
      define_singleton_method(:name) { "PlainRichItem" }
      include InstantRecord::Syncable
    end

    plain_rich.insert_all!([
      { id: "r-1", title: "2026-01-02T03:04:05", body: "hello", count: 10, active: true, due_on: Date.new(2026, 5, 1), happened_at: Time.utc(2024, 2, 29, 12, 30, 45, 123456), server_version: 2, created_at: Time.utc(2026, 11, 28, 5, 6, 7, 890123), updated_at: Time.utc(2026, 11, 28, 5, 6, 7, 0) },
      { id: "r-2", title: nil, body: nil, count: nil, active: false, due_on: nil, happened_at: nil, server_version: nil, created_at: Time.utc(2026, 3, 15, 0, 0, 0, 0), updated_at: Time.utc(2026, 3, 15, 23, 59, 59, 999999) },
      { id: "r'quote\\slash", title: "2026-06-07T08:09:10", body: "quoted", count: -5, active: true, due_on: Date.new(2025, 12, 31), happened_at: Time.utc(2026, 7, 4, 1, 2, 3, 456000), server_version: 0, created_at: Time.utc(2026, 7, 4, 1, 2, 3, 0), updated_at: Time.utc(2026, 7, 4, 1, 2, 3, 456789) }
    ])
    InstantRecord::SyncMetadata.set("#{HLC::RECORD_PREFIX}PlainRichItem:r'quote\\slash", "2026-11-28T00:00:00.000000Z-0000-00000000")
    InstantRecord::SyncMetadata.set("#{HLC::RECORD_PREFIX}RichItem:r-1", "2026-11-28T00:00:00.000001Z-0000-00000000")

    # Plain model without sync_state column, with Date, nil server_version, leap day, special chars in key
    assert_exact_payload_parity(plain_rich.order(:id))
    assert_exact_payload_parity(plain_rich.order(:id).to_a)
    # Custom type returning an object responding to :usec
    assert_exact_payload_parity(rich.order(:id))
    assert_exact_payload_parity(rich.order(:id).to_a)

    # Non-UTC and GMT time zones with time_zone_aware_attributes enabled
    previous_tz_aware = plain_rich.time_zone_aware_attributes
    begin
      plain_rich.time_zone_aware_attributes = true
      plain_rich.reset_column_information
      ["UTC", "GMT", "America/New_York"].each do |zone|
        Time.use_zone(zone) do
          assert_exact_payload_parity(plain_rich.order(:id), "zone=#{zone}")
        end
      end
    ensure
      plain_rich.time_zone_aware_attributes = previous_tz_aware
      plain_rich.reset_column_information
    end

    # ActiveRecord.default_timezone = :local
    previous_default_tz = ActiveRecord.default_timezone
    begin
      ActiveRecord.default_timezone = :local
      assert_exact_payload_parity(plain_rich.order(:id), "default_timezone=:local")
    ensure
      ActiveRecord.default_timezone = previous_default_tz
    end
  end

  def test_record_payloads_preserves_frozen_and_shared_attributes_and_heterogeneous_arrays
    seed(@open, 3)
    seed(@ruled, 2)

    frozen_model = syncable_model("FrozenModel") do
      def attributes
        super.freeze
      end
    end
    shared_hash = { "id" => "open-0", "title" => "kept", "sync_state" => "synced", "server_version" => 1 }
    shared_model = syncable_model("SharedModel") do
      define_method(:attributes) { shared_hash }
    end
    custom_id_model = syncable_model("CustomId") do
      def id = "custom:#{super}"
    end
    custom_bracket_model = syncable_model("CustomBracket") do
      def [](attr)
        attr == :server_version ? 42 : super
      end
    end

    [frozen_model, shared_model, custom_id_model, custom_bracket_model].each do |model|
      assert_exact_payload_parity(model.order(:id), model.name)
      assert_exact_payload_parity(model.order(:id).to_a, "#{model.name} array")
    end
    assert shared_hash.key?("sync_state"), "shared attribute hash must not be mutated"

    # Heterogeneous array: multiple classes, mixed select projections, duplicates, singleton overrides
    r_full = @open.order(:id).first
    r_narrow = @open.select(:id, :title, :server_version).order(:id).second
    r_ruled = @ruled.order(:id).first
    r_ext = @open.order(:id).last
    r_ext.extend(Module.new { def [](attr) = attr == :server_version ? 99 : super })
    mixed = [r_full, r_narrow, r_full, r_ruled, r_ext]

    assert_exact_payload_parity(mixed, "heterogeneous array")
    assert_equal [], InstantRecord.record_payloads(@open.none)
    assert_equal [], InstantRecord.record_payloads(@open.where(id: []))
    assert_equal [], InstantRecord.record_payloads([])
  end

  def test_record_payloads_query_cache_and_row_reader_api
    seed(@open, 3)

    ActiveRecord::Base.cache do
      first = InstantRecord.record_payloads(@open.order(:id))
      second = InstantRecord.record_payloads(@open.order(:id))
      expected = @open.order(:id).to_a.map { |r| InstantRecord.record_payload(r) }
      assert_equal expected, first
      assert_equal expected, second
    end

    # Duplicate column names from a join fall back cleanly to Active Record instantiation.
    assert_exact_payload_parity(@open.select("items.*", "items.id AS id").order(:id), "duplicate select column")

    # Plain non-Syncable ActiveRecord model (zero find callbacks).
    plain_ar = Class.new(ActiveRecord::Base) do
      self.table_name = "items"
      define_singleton_method(:name) { "PlainAr" }
    end
    assert_exact_payload_parity(plain_ar.order(:id), "non-syncable AR model")

    # When SyncActions is enforcing a server mutator, Syncable's after_find still runs.
    noted = []
    InstantRecord::SyncActions.singleton_class.class_eval do
      alias_method :orig_enforcing_server_mutator?, :enforcing_server_mutator?
      alias_method :orig_server_note_read, :server_note_read
      remove_method :enforcing_server_mutator?, :server_note_read
      define_method(:enforcing_server_mutator?) { true }
      define_method(:server_note_read) { |record| noted << record.id }
    end
    begin
      assert_exact_payload_parity(@open.order(:id), "enforcing server mutator")
    ensure
      InstantRecord::SyncActions.singleton_class.class_eval do
        remove_method :enforcing_server_mutator?, :server_note_read
        alias_method :enforcing_server_mutator?, :orig_enforcing_server_mutator?
        alias_method :server_note_read, :orig_server_note_read
        remove_method :orig_enforcing_server_mutator?, :orig_server_note_read
      end
    end
    assert_equal %w[open-0 open-1 open-2], noted.uniq.sort

    reader = InstantRecord::PayloadBatch::RowReader.new
    rows = @open.order(:id).to_a
    assert_equal rows.map(&:attributes), rows.map { |r| reader.attributes(r) }
  end

  def test_record_payloads_honors_singleton_bracket_missing_version_usec_pk_callbacks_and_non_plain_stamps
    seed(@open, 3)

    # Finding #1a: unloaded relation whose after_find extends a row with singleton [] or read_attribute.
    singleton_bracket = syncable_model("SingletonBracket") do
      after_find do
        extend(Module.new { def [](attr) = attr == :server_version ? 999 : super }) if id == "open-1"
      end
    end
    singleton_reader = syncable_model("SingletonReader") do
      after_find do
        extend(Module.new { def read_attribute(attr, &block) = attr.to_s == "server_version" ? 777 : super }) if id == "open-2"
      end
    end
    assert_exact_payload_parity(singleton_bracket.order(:id), "singleton [] in after_find")
    assert_exact_payload_parity(singleton_reader.order(:id), "singleton read_attribute in after_find")

    # Finding #1b: partial select omitting server_version raises ActiveModel::MissingAttributeError on fallback path.
    virt_model = syncable_model("VirtModel") { attribute :virtual_tag, :string, default: "v" }
    assert_raises(ActiveModel::MissingAttributeError) do
      InstantRecord.record_payloads(virt_model.select(:id, :title).order(:id))
    end

    # Finding #2: :usec-typed primary_key and server_version keep unformatted Ruby values on rows 1..N.
    ActiveRecord::Schema.define do
      create_table :dt_key_items, id: false, force: true do |t|
        t.datetime :happened_at, null: false
        t.datetime :server_version
        t.string :title
      end
    end
    dt_pk = Class.new(ActiveRecord::Base) do
      self.table_name = "dt_key_items"
      self.primary_key = "happened_at"
      define_singleton_method(:name) { "DtPkItem" }
      include InstantRecord::Syncable
    end
    t1 = Time.utc(2026, 1, 1, 1, 2, 3, 123456)
    t2 = Time.utc(2026, 1, 2, 4, 5, 6, 654321)
    dt_pk.insert_all!([
      { happened_at: t1, server_version: t1, title: "one" },
      { happened_at: t2, server_version: t2, title: "two" }
    ])
    InstantRecord::SyncMetadata.set("#{HLC::RECORD_PREFIX}DtPkItem:#{t2}", "2026-11-28T00:00:00.000002Z-0000-00000000")
    assert_exact_payload_parity(dt_pk.order(:happened_at), "datetime pk and server_version")

    # Finding #3: init_with_attributes, attributes_builder, and reset_callbacks(:find) + custom after_find.
    init_override = syncable_model("InitOverride") do
      def init_with_attributes(attributes, &block)
        super
        write_attribute(:title, "init:#{self[:title]}")
        self
      end
    end
    builder_override = syncable_model("BuilderOverride") do
      def self.attributes_builder
        super
      end
    end
    fired = []
    custom_find = syncable_model("CustomFindOnly") do
      reset_callbacks(:find)
      after_find do
        fired << id
        write_attribute(:title, "found:#{id}")
      end
    end
    assert_exact_payload_parity(init_override.order(:id), "init_with_attributes override")
    refute InstantRecord::PayloadBatch.direct_relation?(builder_override.order(:id))
    assert_exact_payload_parity(builder_override.order(:id), "attributes_builder override")
    refute InstantRecord::PayloadBatch.direct_relation?(custom_find.order(:id))
    fired.clear
    assert_exact_payload_parity(custom_find.order(:id), "reset_callbacks(:find) + custom after_find")
    assert_equal %w[open-0 open-1 open-2 open-0 open-1 open-2], fired

    # Finding #4: PayloadBatch.stamps handles non-String keys, nil, and invalid UTF-8 safely.
    InstantRecord::SyncMetadata.set("123", "num-stamp")
    assert_equal({ "123" => "num-stamp" }, InstantRecord::PayloadBatch.stamps([123]))
    assert_equal({ "123" => "num-stamp" }, InstantRecord::PayloadBatch.stamps([nil, 123]))
    assert_equal({}, InstantRecord::PayloadBatch.stamps([nil]))
    bad_utf8 = "\xFF".dup.force_encoding(Encoding::UTF_8)
    refute InstantRecord::PayloadBatch.send(:plain_sql_string?, bad_utf8)
    assert_equal({}, InstantRecord::PayloadBatch.stamps([bad_utf8]))
  end

  private

  def assert_exact_payload_parity(records, label = nil)
    materialized = records.is_a?(ActiveRecord::Relation) ? records.spawn.to_a : records
    expected = materialized.map { |r| InstantRecord.record_payload(r) }
    actual = InstantRecord.record_payloads(records)

    assert_equal expected, actual, label
    assert_equal expected.to_json, actual.to_json, label
    expected.zip(actual).each_with_index do |(exp, act), idx|
      assert_equal exp.keys, act.keys, "#{label} row #{idx} top keys"
      assert_equal exp[:id].class, act[:id].class, "#{label} row #{idx} id class"
      assert_equal exp[:version].class, act[:version].class, "#{label} row #{idx} version class"
      assert_equal exp[:attributes].keys, act[:attributes].keys, "#{label} row #{idx} attr keys"
      assert_equal exp[:attributes].values.map(&:class), act[:attributes].values.map(&:class), "#{label} row #{idx} attr value classes"
    end
  end

  # Four rows that belong to another, "parent".
  def children
    model = @open
    model.has_many :children, -> { order(:id) }, anonymous_class: model, foreign_key: :owner
    on_server { model.create!(id: "parent", title: "p", owner: "ada") }
    seed(model, 4, owner: "parent")
  end

  def get(controller, action, **params)
    app = Struct.new(:config).new(Struct.new(:eager_load).new(true))
    with_rails_application(app) do
      status, _headers, body = controller.action(action).call(Rack::MockRequest.env_for("/?#{Rack::Utils.build_query(params)}"))
      assert_equal 200, status

      json = +""
      body.each { |part| json << part }
      body.close if body.respond_to?(:close)
      JSON.parse(json).fetch("records")
    end
  end

  def assert_sends_single_payloads(model, sent, count)
    assert_equal count, sent.size
    expected = sent.map { |record| InstantRecord.record_payload(model.find(record["id"])) }
    assert_equal JSON.generate(JSON.parse(expected.to_json)), JSON.generate(sent)
    assert(sent.all? { |record| HLC.valid?(record["hlc"]) })
  end
end
