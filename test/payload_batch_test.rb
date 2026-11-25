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

  private

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
