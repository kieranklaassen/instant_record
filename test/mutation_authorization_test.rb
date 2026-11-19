require "test_helper"

# Which client writes the server takes from which identity.
class MutationAuthorizationTest < Minitest::Test
  def setup
    reset_instant_record_tables!
    @model = scoped_model
    InstantRecord.sync(@model)
    @ada = Person.new("ada")
    @ben = Person.new("ben")
    @sequence = 0
  end

  def teardown
    InstantRecord.sync
  end

  def seed(id, state)
    on_server { @model.create!(id: id, title: "#{state} row", state: state) }
    InstantRecord::Change.delete_all
  end

  def apply(identity, operation, id, type: "Item", **changes)
    mutation = { id: "m-#{@sequence += 1}", record_type: type, record_id: id, operation: operation, changes: changes }
    with_sync_identity { on_server { InstantRecord::MutationApplier.apply(mutation, identity) } }
  end

  def reply(result) = result.except(:mutation_id)

  def test_a_create_the_identity_may_write_is_applied
    result = apply(@ada, "create", "new", "title" => "mine", "state" => "ada")

    assert_equal "applied", result[:status]
    assert_equal "mine", @model.find("new").title
    assert_equal 1, InstantRecord::Change.count
  end

  def test_a_create_for_someone_else_is_rejected_and_leaves_nothing
    result = apply(@ada, "create", "new", "title" => "forged", "state" => "ben")

    assert_equal({ status: "rejected", reason: "not permitted", server_attributes: nil }, reply(result))
    refute @model.exists?(id: "new")
    assert_equal 0, InstantRecord::Change.count
  end

  def test_a_signed_out_identity_cannot_write_a_scoped_model
    seed("p", "public")

    assert_equal "not permitted", apply(nil, "create", "new", "title" => "anon", "state" => "public")[:reason]
    assert_equal "not permitted", apply(nil, "update", "p", "title" => "defaced")[:reason]
    assert_equal "not permitted", apply(nil, "destroy", "p")[:reason]
    assert_equal "public row", @model.find("p").title
    assert_equal 0, InstantRecord::Change.count
  end

  def test_a_record_seen_but_not_writable_is_rejected_with_the_servers_row
    seed("p", "public")

    update = apply(@ada, "update", "p", "title" => "defaced")
    destroy = apply(@ada, "destroy", "p")

    assert_equal %w[rejected rejected], [update[:status], destroy[:status]]
    assert_equal "public row", update[:server_attributes]["title"]
    assert_equal "public row", destroy[:server_attributes]["title"]
    assert_equal "public row", @model.find("p").title
  end

  def test_update_of_a_hidden_record_answers_as_a_missing_one
    seed("b", "ben")

    hidden = apply(@ada, "update", "b", "title" => "taken")
    missing = apply(@ada, "update", "nowhere", "title" => "taken")

    assert_equal({ status: "rejected", reason: "record not found" }, reply(hidden))
    assert_equal reply(missing), reply(hidden)
    assert_equal "ben row", @model.find("b").title
  end

  def test_destroy_of_a_hidden_record_answers_as_a_missing_one_and_logs_nothing
    seed("b", "ben")

    hidden = apply(@ada, "destroy", "b")
    logged = InstantRecord::Change.count
    missing = apply(@ada, "destroy", "nowhere")

    assert_equal reply(missing), reply(hidden)
    assert @model.exists?(id: "b")
    assert_equal 0, logged
  end

  def test_a_create_reusing_a_hidden_id_reveals_nothing
    seed("b", "ben")
    forbidden = reply(apply(@ada, "create", "elsewhere", "title" => "forged", "state" => "ben"))

    valid = apply(@ada, "create", "b", "title" => "mine", "state" => "ada")
    unknown_column = apply(@ada, "create", "b", "title" => "mine", "state" => "ada", "no_such_column" => 1)

    assert_equal forbidden, reply(valid)
    assert_equal forbidden, reply(unknown_column)
    assert_equal "ben row", @model.find("b").title
  end

  def test_an_invalid_create_reusing_a_hidden_id_reveals_nothing
    model = syncable_model("Item") do
      validates :title, presence: true
      syncable_to { |who| who ? where(state: ["public", who.id]) : where(state: "public") }
      writable_by { |who| who ? where(state: who.id) : none }
    end
    InstantRecord.sync(model)
    seed("b", "ben")

    result = apply(@ada, "create", "b", "state" => "ada")

    assert_equal({ status: "rejected", reason: "not permitted", server_attributes: nil }, reply(result))
  end

  def test_an_update_that_moves_a_record_out_of_the_writers_reach_is_rolled_back
    seed("a", "ada")

    result = apply(@ada, "update", "a", "state" => "ben")

    assert_equal "not permitted", result[:reason]
    assert_equal "ada", result[:server_attributes]["state"]
    assert_equal "ada", @model.find("a").state
    assert_equal 0, InstantRecord::Change.count
  end

  def test_an_owner_updates_and_destroys_their_own_record
    seed("a", "ada")

    assert_equal "applied", apply(@ada, "update", "a", "title" => "edited")[:status]
    assert_equal "edited", @model.find("a").title
    assert_equal "applied", apply(@ada, "destroy", "a")[:status]
    refute @model.exists?(id: "a")
    assert_equal %w[update destroy], InstantRecord::Change.order(:id).pluck(:operation)
  end

  def test_without_a_write_declaration_what_is_seen_may_be_written
    model = syncable_model("Item") { syncable_to { |who| who ? where(state: ["public", who.id]) : none } }
    InstantRecord.sync(model)
    seed("p", "public")

    assert_equal "applied", apply(@ada, "update", "p", "title" => "edited")[:status]
    assert_equal "rejected", apply(nil, "update", "p", "title" => "anon")[:status]
  end

  def test_a_replayed_mutation_returns_its_first_result
    mutation = { id: "replayed", record_type: "Item", record_id: "new", operation: "create",
      changes: { "title" => "mine", "state" => "ada" } }

    first, second = with_sync_identity do
      on_server { 2.times.map { InstantRecord::MutationApplier.apply(mutation, @ada) } }
    end

    assert_equal first, second
    assert_equal 1, @model.count
  end

  def test_an_unscoped_model_takes_writes_from_anyone
    open_model = syncable_model("Open")
    InstantRecord.sync(@model, open_model)

    result = apply(nil, "create", "o", "title" => "for all", type: "Open")

    assert_equal "applied", result[:status]
  end

  def test_nothing_configured_takes_writes_to_a_declared_model_from_anyone
    mutation = { id: "open", record_type: "Item", record_id: "new", operation: "create",
      changes: { "title" => "anon", "state" => "ben" } }

    result = on_server { InstantRecord::MutationApplier.apply(mutation) }

    assert_equal "applied", result[:status]
  end
end
