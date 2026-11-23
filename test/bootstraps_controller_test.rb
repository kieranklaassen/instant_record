require "test_helper"
require "rails"
require "action_controller"
require "rack/mock"
require File.expand_path("../app/controllers/instant_record/bootstraps_controller", __dir__)

class BootstrapsControllerTest < Minitest::Test
  def setup
    reset_instant_record_tables!
    @previous_scope = InstantRecord.config.scope_from
  end

  def teardown
    InstantRecord.sync
    InstantRecord.config.scope_from = @previous_scope
  end

  def test_quiet_tenant_receives_limit_rows_when_another_tenant_writes_newer_rows_unpartitioned
    model = syncable_model("TenantNote") do
      sync_scope :owner
      sync_window limit: 2
    end
    InstantRecord.sync(model)
    InstantRecord.config.scope_from = ->(request) { request.params["scope"] }

    on_server do
      create_row(model, "ada-1", owner: "ada", at: 60.minutes.ago)
      create_row(model, "ada-2", owner: "ada", at: 50.minutes.ago)
      create_row(model, "ada-3", owner: "ada", at: 40.minutes.ago)
      5.times { |i| create_row(model, "bob-#{i}", owner: "bob", at: (10 - i).minutes.ago) }
    end

    assert_equal %w[ada-2 ada-3], bootstrapped_ids(scope: "ada")
    assert_equal %w[bob-3 bob-4], bootstrapped_ids(scope: "bob")
    assert_empty bootstrapped_ids
  end

  def test_quiet_tenant_receives_limit_rows_per_shared_partition_with_syncable_to
    model = syncable_model("TenantMessage") do
      sync_window limit: 2, partition_by: :state
      syncable_to { |who| who&.id ? where(owner: [nil, who.id]) : none }
    end
    InstantRecord.sync(model)
    InstantRecord.config.scope_from = ->(request) { Person.new(request.params["scope"]) }

    on_server do
      create_row(model, "ada-open-1", state: "open", owner: "ada", at: 60.minutes.ago)
      create_row(model, "ada-open-2", state: "open", owner: "ada", at: 50.minutes.ago)
      create_row(model, "ada-open-3", state: "open", owner: "ada", at: 40.minutes.ago)
      create_row(model, "ada-closed-1", state: "closed", owner: "ada", at: 70.minutes.ago)
      4.times { |i| create_row(model, "bob-open-#{i}", state: "open", owner: "bob", at: (10 - i).minutes.ago) }
    end

    assert_equal %w[ada-closed-1 ada-open-2 ada-open-3], bootstrapped_ids(scope: "ada")
    assert_equal %w[bob-open-2 bob-open-3], bootstrapped_ids(scope: "bob")
    assert_empty bootstrapped_ids
  end

  private

  def create_row(model, id, owner:, at:, state: "open")
    model.create!(id: id, title: id, owner: owner, state: state, created_at: at, updated_at: at)
  end

  def bootstrapped_ids(scope: nil)
    app = Struct.new(:config).new(Struct.new(:eager_load).new(true))
    with_rails_application(app) do
      query = scope ? "?#{Rack::Utils.build_query(scope: scope)}" : ""
      env = Rack::MockRequest.env_for("/instant_record/bootstrap#{query}")
      status, _headers, body = InstantRecord::BootstrapsController.action(:show).call(env)
      assert_equal 200, status

      json = +""
      body.each { |part| json << part }
      body.close if body.respond_to?(:close)
      JSON.parse(json).fetch("records").map { |record| record.fetch("id") }.sort
    end
  end
end
