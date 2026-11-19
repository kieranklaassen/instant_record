require "test_helper"

# sync_scope keeps a model's rows to the client they belong to: what the
# server sends (rows, changes) and what it accepts (mutations).
class SyncScopeTest < Minitest::Test
  def setup
    @model = syncable_model("Memo") { sync_scope :owner }
    InstantRecord.sync(@model)
    reset_instant_record_tables!
  end

  def teardown
    InstantRecord.sync
  end

  def apply(scope, operation, id, changes = {})
    InstantRecord::MutationApplier.apply(
      { id: SecureRandom.uuid, record_type: "Memo", record_id: id, operation: operation, changes: changes }, scope
    )
  end

  def test_a_client_is_sent_its_own_rows_and_the_rows_of_no_one
    on_server do
      @model.create!(id: "mine", title: "mine", owner: "ada")
      @model.create!(id: "theirs", title: "theirs", owner: "bob")
      @model.create!(id: "everyones", title: "everyone's")
    end

    assert_equal %w[everyones mine], @model.instant_record_visible_to("ada").pluck(:id).sort
    assert_equal %w[everyones], @model.instant_record_visible_to(nil).pluck(:id)
    assert_equal %w[everyones], @model.instant_record_visible_to("").pluck(:id)
  end

  def test_a_model_without_a_scope_is_sent_whole
    open = syncable_model("Open")
    on_server { open.create!(id: "a", title: "a", owner: "bob") }

    assert_equal %w[a], open.instant_record_visible_to("ada").pluck(:id)
  end

  def test_server_writes_are_logged_under_the_rows_scope
    on_server do
      memo = @model.create!(id: "mine", title: "mine", owner: "ada")
      memo.update!(title: "still mine")
      memo.destroy!
      @model.create!(id: "everyones", title: "everyone's")
    end

    assert_equal ["ada", "ada", "ada", nil], InstantRecord::Change.order(:id).pluck(:scope)
    assert_equal 4, InstantRecord::Change.poll(0, scope: "ada").size
    assert_equal %w[everyones], InstantRecord::Change.poll(0, scope: "bob").map(&:record_id)
    assert_equal %w[everyones], InstantRecord::Change.poll(0).map(&:record_id)
  end

  def test_a_create_is_stamped_with_the_senders_scope_whatever_it_claims
    result = apply("ada", "create", "m-1", "title" => "hello", "owner" => "bob")

    assert_equal "applied", result[:status]
    assert_equal "ada", @model.find("m-1").owner
    assert_equal "ada", InstantRecord::Change.last.scope
  end

  def test_a_scoped_model_takes_no_write_without_a_scope
    result = apply(nil, "create", "m-1", "title" => "hello")

    assert_equal "rejected", result[:status]
    assert_equal 0, @model.count
  end

  def test_another_scopes_row_cannot_be_changed_removed_or_taken_over
    on_server do
      @model.create!(id: "theirs", title: "theirs", owner: "bob")
      @model.create!(id: "everyones", title: "everyone's")
    end

    assert_equal "rejected", apply("ada", "update", "theirs", "title" => "mine now")[:status]
    assert_equal "rejected", apply("ada", "destroy", "theirs")[:status]
    assert_equal "rejected", apply("ada", "create", "theirs", "title" => "again")[:status]
    assert_equal "rejected", apply("ada", "update", "everyones", "title" => "mine now")[:status]
    assert_equal ["theirs", "everyone's"], @model.order(:created_at).pluck(:title)
  end

  def test_an_update_cannot_move_a_row_to_another_scope
    apply("ada", "create", "m-1", "title" => "hello")

    result = apply("ada", "update", "m-1", "title" => "moved", "owner" => "bob")

    assert_equal "applied", result[:status]
    assert_equal ["moved", "ada"], @model.find("m-1").values_at(:title, :owner)
  end

  def test_a_destroy_is_heard_only_by_its_scope
    apply("ada", "create", "m-1", "title" => "hello")
    apply("ada", "destroy", "m-1")

    assert_equal %w[create destroy], InstantRecord::Change.poll(0, scope: "ada").map(&:operation)
    assert_empty InstantRecord::Change.poll(0, scope: "bob")
  end
end
