require "test_helper"

# Which records, and which changes, one identity is sent.
class SyncIdentityTest < Minitest::Test
  Scope = InstantRecord::SyncScope

  def setup
    reset_instant_record_tables!
    @model = scoped_model
    InstantRecord.sync(@model)
    @ada = Person.new("ada")
    @ben = Person.new("ben")
    @guest = Person.new(nil)
  end

  def teardown
    InstantRecord.sync
  end

  def create(id, state)
    on_server { @model.create!(id: id, title: "#{state} row", state: state) }
  end

  def events(identity)
    Scope.events_for(InstantRecord::Change.order(:id).to_a, identity).map(&:last)
  end

  def test_a_model_that_declares_nothing_is_open_to_everyone
    open_model = syncable_model("Open")
    create("p", "public")
    create("a", "ada")

    refute Scope.scoped?(open_model)
    assert Scope.scoped?(@model)
    assert_equal %w[a p], Scope.visible(open_model, nil).pluck(:id).sort
    assert_equal %w[a p], Scope.writable(open_model, nil).pluck(:id).sort
  end

  def test_every_identity_has_a_key_even_nobody
    user = Struct.new(:id)

    assert_equal 4, [Scope.key(nil), Scope.key("a-visitor-token"), Scope.key(user.new(1)), Scope.key(user.new(2))].uniq.size
    assert_equal Scope.key(nil), Scope.key("")
    assert Scope.stale?(Scope.key(user.new(1)), nil), "signing out is a change of person"
    refute Scope.stale?(Scope.key("a-visitor-token"), "a-visitor-token")
  end

  def test_an_identity_may_name_the_models_its_key_decides
    partial = Struct.new(:id) { def sync_reset_types = ["Other"] }

    assert_equal ["Item"], Scope.reset_types(@ada)
    assert_equal ["Other"], Scope.reset_event(partial.new(1))[:types]
  end

  def test_a_column_and_a_rule_on_one_model_both_hold
    model = syncable_model("Both") do
      sync_scope :owner
      syncable_to { |_who| where(owner: %w[ada ben]) }
    end
    on_server { %w[ada ben].each { |owner| model.create!(id: owner, title: owner, owner: owner) } }

    assert_equal %w[ada], Scope.visible(model, "ada").pluck(:id)
    assert_empty Scope.visible(model, "cleo").pluck(:id)
  end

  def test_a_ruled_model_left_out_of_the_sync_list_still_keeps_its_changes_to_itself
    Object.const_set(:LeftOut, scoped_model("LeftOut"))
    on_server { LeftOut.create!(id: "a", title: "secret", state: "ada") }
    InstantRecord.sync(syncable_model("Open"))

    assert_equal [{}], events(@ben).map { |event| event[:attributes] }
  ensure
    Object.send(:remove_const, :LeftOut)
  end

  def test_each_identity_sees_its_own_records
    create("p", "public")
    create("a", "ada")
    create("b", "ben")

    assert_equal %w[p], Scope.visible(@model, nil).pluck(:id)
    assert_equal %w[a p], Scope.visible(@model, @ada).pluck(:id).sort
    assert_equal %w[b p], Scope.visible(@model, @ben).pluck(:id).sort
    assert_equal %w[a], Scope.writable(@model, @ada).pluck(:id)
    assert_empty Scope.writable(@model, nil).pluck(:id)
  end

  def test_what_may_be_seen_may_be_written_without_a_write_declaration
    model = syncable_model("Open") { syncable_to { |who| who ? all : none } }
    InstantRecord.sync(model)
    on_server { model.create!(id: "o", title: "open") }

    assert_equal %w[o], Scope.writable(model, @ada).pluck(:id)
    assert_empty Scope.writable(model, nil).pluck(:id)
  end

  def test_keys_differ_between_identities_and_name_no_one
    keys = [Scope.key(@guest), Scope.key(@ada), Scope.key(@ben)]

    assert_equal 3, keys.uniq.size
    refute(keys.any? { |key| key.include?("ada") })
    assert_equal Scope.key(@ada), Scope.key(Person.new("ada"))
  end

  def test_a_key_follows_whatever_the_identity_names
    admin = Struct.new(:id, :role) { def sync_identity_key = "#{id}/#{role}" }

    refute_equal Scope.key(admin.new("ada", "member")), Scope.key(admin.new("ada", "admin"))
  end

  def test_a_key_from_another_identity_is_stale_and_no_key_is_not
    refute Scope.stale?(Scope.key(@ada), @ada)
    assert Scope.stale?(Scope.key(@ada), @ben)
    assert Scope.stale?(Scope.key(@ada), @guest)
    refute Scope.stale?(nil, @ada)
    refute Scope.stale?("", @ada)
  end

  def test_reset_event_names_the_scoped_types_and_the_new_key
    open_model = syncable_model("Open")
    InstantRecord.sync(@model, open_model)

    assert_equal({ operation: "reset", types: ["Item"], identity: Scope.key(@ben) }, Scope.reset_event(@ben))
  end

  def test_stream_sends_a_visible_change_with_the_record_as_it_is_now
    create("a", "ada")
    on_server { @model.find("a").update!(title: "edited since") }

    sent = events(@ada)

    assert_equal %w[create update], sent.map { |event| event[:operation] }
    assert_equal ["edited since"] * 2, sent.map { |event| event[:attributes]["title"] }
    assert_equal [2, 2], sent.map { |event| event[:version] }
  end

  def test_stream_sends_a_hidden_change_as_an_empty_destroy
    create("a", "ada")

    [@ben, @guest, nil].each do |identity|
      assert_equal [{ type: "Item", id: "a", operation: "destroy", version: 0, attributes: {} }], events(identity)
    end
  end

  def test_a_record_that_leaves_an_identitys_sight_is_destroyed_there_only
    create("x", "public")
    on_server { @model.find("x").update!(state: "ada") }

    assert_equal %w[destroy destroy], events(@ben).map { |event| event[:operation] }
    assert_equal %w[create update], events(@ada).map { |event| event[:operation] }
    assert_equal "ada", events(@ada).last[:attributes]["state"]
  end

  def test_destroys_and_unscoped_models_pass_through
    open_model = syncable_model("Open")
    InstantRecord.sync(@model, open_model)
    create("a", "ada")
    on_server { @model.find("a").destroy! }
    on_server { open_model.create!(id: "o", title: "for all") }

    sent = events(nil)

    assert_equal %w[destroy destroy create], sent.map { |event| event[:operation] }
    assert_equal "for all", sent.last[:attributes]["title"]
  end

  def test_events_keep_their_change_log_ids
    create("a", "ada")
    create("p", "public")

    ids = InstantRecord::Change.order(:id).pluck(:id)

    assert_equal ids, InstantRecord::SyncScope.events_for(InstantRecord::Change.order(:id).to_a, nil).map(&:first)
  end
end
