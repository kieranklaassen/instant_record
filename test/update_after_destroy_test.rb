require "test_helper"
require "tmpdir"

# A client's update that waited on another connection's destroy finds no row.
# Here the row goes behind an object that was loaded before.
class UpdateAfterDestroyTest < Minitest::Test
  HLC = InstantRecord::HLC
  NOT_FOUND = { status: "rejected", reason: "record not found" }.freeze

  class OtherDatabase < ActiveRecord::Base
    self.abstract_class = true
  end

  def setup
    reset_instant_record_tables!
    InstantRecord::SyncActions.reset_registry!
  end

  def teardown
    InstantRecord.sync
    InstantRecord::SyncActions.reset_registry!
  end

  def test_an_update_of_a_removed_row_is_answered_as_one_of_a_missing_record
    removed(synced)
    state = server_state

    assert_equal NOT_FOUND, reply(update(title: "new"))
    assert_equal state, server_state
  end

  def test_an_update_without_a_clock_of_its_own_leaves_the_server_clock_alone
    removed(synced)
    state = server_state

    assert_equal NOT_FOUND, reply(update(title: "new", hlc: nil, base_version: nil))
    assert_equal state, server_state
  end

  def test_a_merge_into_a_removed_row_is_answered_as_an_update_of_a_missing_record
    removed(synced, edits: 1)
    state = server_state

    assert_equal NOT_FOUND, reply(update(state: "closed"))
    assert_equal state, server_state
  end

  def test_the_answer_is_kept_for_a_replay
    removed(synced)
    first = update(title: "new", id: "m-replayed")

    assert_equal first, update(title: "new", id: "m-replayed")
    assert_equal 1, InstantRecord::AppliedMutation.where(mutation_id: "m-replayed").count
  end

  def test_what_the_models_callbacks_wrote_is_undone
    model = synced { after_update { self.class.create!(id: "written", title: "by a callback") } }
    removed(model)

    assert_equal NOT_FOUND, reply(update(title: "new"))
    refute model.exists?(id: "written")
  end

  # The row goes after the sender was found permitted.
  def test_a_removed_row_is_not_found_rather_than_not_permitted
    model = scoped_model
    model.before_update { self.class.delete(id) if title == "new" }
    InstantRecord.sync(model)
    on_server { model.create!(id: "i", title: "v1", state: "ada") }

    assert_equal NOT_FOUND, reply(update(title: "new", identity: Person.new("ada")))
    assert_equal %w[create], logged
  end

  def test_an_update_of_a_row_that_is_there_is_logged
    model = synced
    on_server { model.create!(id: "i", title: "v1", state: "open") }

    result = update(title: "new")

    assert_equal "applied", result[:status]
    assert_equal 2, result[:version]
    assert_equal %w[create update], logged
    assert_equal result[:hlc], HLC.record_hlc("Item", "i")
  end

  # Its save commits by itself there, not with the applier's transaction.
  def test_an_update_of_a_model_in_another_database_is_logged
    Dir.mktmpdir do |dir|
      OtherDatabase.establish_connection(adapter: "sqlite3", database: File.join(dir, "other.sqlite3"))
      OtherDatabase.lease_connection.create_table(:items, id: :string) do |t|
        t.string :title
        t.string :state
        t.integer :server_version, null: false, default: 0
        t.string :sync_state, null: false, default: "synced"
        t.timestamps
      end
      model = Class.new(OtherDatabase) do
        self.table_name = "items"
        define_singleton_method(:name) { "Item" }
        include InstantRecord::Syncable
      end
      InstantRecord.sync(model)
      on_server { model.create!(id: "i", title: "v1", state: "open") }

      assert_equal "applied", update(title: "v2")[:status]
      merged = update(state: "closed")
      assert_equal ["applied", true], merged.values_at(:status, :merged)
      assert_equal %w[create update update], logged
      assert_equal ["v2", "closed", 3], model.find("i").values_at(:title, :state, :server_version)
    ensure
      OtherDatabase.remove_connection
    end
  end

  def test_a_sync_action_updating_a_removed_row_is_answered_as_one_finding_no_record
    item = nil
    model = synced do
      sync_action(:rename) { item.update!(title: "new") }
      sync_action(:look) { |args| find(args["id"]) }
    end
    item = on_server { model.create!(id: "i", title: "v1") }
    on_server { model.find("i").destroy! }
    state = server_state

    missing = act("look", { "id" => "i" })
    assert_match(/\ACouldn't find Item/, missing[:reason])
    assert_equal missing.except(:mutation_id), act("rename").except(:mutation_id)
    assert_equal state, server_state
  end

  def test_a_sync_action_updating_a_removed_row_undoes_its_other_writes
    item = nil
    model = synced do
      sync_action(:rename) do
        create!(id: "other", title: "by the action")
        item.update!(title: "new")
      end
    end
    item = on_server { model.create!(id: "i", title: "v1") }
    on_server { model.find("i").destroy! }

    assert_equal "rejected", act("rename")[:status]
    refute model.exists?(id: "other")
    assert_equal %w[create destroy], logged
  end

  def test_a_sync_action_may_rescue_the_record_not_being_found
    item = nil
    model = synced do
      sync_action(:rename) do
        item.update!(title: "new")
      rescue ActiveRecord::RecordNotFound => e
        create!(id: "other", title: [e.model, e.primary_key, e.id].join(" "))
      end
    end
    item = on_server { model.create!(id: "i", title: "v1") }
    on_server { model.find("i").destroy! }

    result = act("rename")

    assert_equal "applied", result[:status]
    assert_equal "Item id i", model.find("other").title
    assert_equal ["other"], result[:records].map { |record| record["id"] }
    assert_equal %w[create destroy create], logged
  end

  def test_a_removed_row_is_not_found_rather_than_not_permitted_in_a_sync_action
    model = scoped_model
    model.sync_action(:rename) { find("i").update!(title: "new") }
    model.before_update { self.class.delete(id) if title == "new" }
    InstantRecord.sync(model)
    on_server { model.create!(id: "i", title: "v1", state: "ada") }

    assert_match(/\ACouldn't find Item/, act("rename", identity: Person.new("ada"))[:reason])
    assert_equal %w[create], logged
  end

  private

  def synced(&body)
    syncable_model(&body).tap { |model| InstantRecord.sync(model) }
  end

  # Edited `edits` times after the version the client knows, then destroyed
  # once the applier has loaded it.
  def removed(model, edits: 0)
    item = on_server do
      model.create!(id: "i", title: "v1", state: "open")
      edits.times { |edit| model.find("i").update!(title: "edit #{edit}") }
      model.find("i")
    end
    on_server { model.find("i").destroy! }
    model.define_singleton_method(:find_by) { |*conditions, **columns| columns[:id] == "i" ? item : super(*conditions, **columns) }
    item
  end

  def update(id: SecureRandom.uuid, record_id: "i", identity: nil, base_version: 1, hlc: HLC.from_time(Time.now.utc + 1, node: "clientaa"), **columns)
    mutation = { id: id, record_type: "Item", record_id: record_id, operation: "update",
      base_version: base_version, hlc: hlc, changes: columns.stringify_keys }.compact
    on_server { InstantRecord::MutationApplier.apply(mutation, identity) }
  end

  def act(action, args = {}, identity: nil)
    mutation = { id: SecureRandom.uuid, operation: "mutator", mutator: "Item.#{action}", args: args }
    on_server { InstantRecord::MutationApplier.apply(mutation, identity) }
  end

  def reply(result) = result.except(:mutation_id)

  def logged = InstantRecord::Change.order(:id).pluck(:operation)

  def server_state
    [InstantRecord::Change.order(:id).map(&:attributes), InstantRecord::SyncMetadata.order(:key).pluck(:key, :value)]
  end
end
