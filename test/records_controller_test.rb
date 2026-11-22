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

  private

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
