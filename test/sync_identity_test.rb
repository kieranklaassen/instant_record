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

  def test_nothing_configured_leaves_every_model_open
    create("p", "public")
    create("a", "ada")

    refute Scope.enabled?
    refute Scope.scoped?(@model)
    assert_nil Scope.key(@ada)
    refute Scope.stale?(nil, @ada)
    assert_equal %w[a p], Scope.visible(@model, nil).pluck(:id).sort
    assert_equal InstantRecord::Change.order(:id).map(&:as_event), events(nil)
  end

  def test_each_identity_sees_its_own_records
    create("p", "public")
    create("a", "ada")
    create("b", "ben")

    with_sync_identity do
      assert_equal %w[p], Scope.visible(@model, nil).pluck(:id)
      assert_equal %w[a p], Scope.visible(@model, @ada).pluck(:id).sort
      assert_equal %w[b p], Scope.visible(@model, @ben).pluck(:id).sort
      assert_equal %w[a], Scope.writable(@model, @ada).pluck(:id)
      assert_empty Scope.writable(@model, nil).pluck(:id)
    end
  end

  def test_what_may_be_seen_may_be_written_without_a_write_declaration
    model = syncable_model("Open") { syncable_to { |who| who ? all : none } }
    InstantRecord.sync(model)
    on_server { model.create!(id: "o", title: "open") }

    with_sync_identity do
      assert_equal %w[o], Scope.writable(model, @ada).pluck(:id)
      assert_empty Scope.writable(model, nil).pluck(:id)
    end
  end

  def test_keys_differ_between_identities_and_name_no_one
    with_sync_identity do
      keys = [Scope.key(nil), Scope.key(@ada), Scope.key(@ben)]

      assert_equal 3, keys.uniq.size
      refute(keys.any? { |key| key.include?("ada") })
      assert_equal Scope.key(@ada), Scope.key(Person.new("ada"))
    end
  end

  def test_an_identity_may_name_its_own_key
    admin = Struct.new(:id, :role) { def sync_identity_key = "#{id}/#{role}" }

    with_sync_identity do
      refute_equal Scope.key(admin.new("ada", "member")), Scope.key(admin.new("ada", "admin"))
    end
  end

  def test_a_key_from_another_identity_or_none_at_all_is_stale
    with_sync_identity do
      refute Scope.stale?(Scope.key(@ada), @ada)
      assert Scope.stale?(Scope.key(@ada), @ben)
      assert Scope.stale?(Scope.key(@ada), nil)
      assert Scope.stale?(nil, @ada)
    end
  end

  def test_reset_event_names_the_scoped_types_and_the_new_key
    open_model = syncable_model("Open")
    InstantRecord.sync(@model, open_model)

    with_sync_identity do
      assert_equal({ operation: "reset", types: ["Item"], identity: Scope.key(@ben) }, Scope.reset_event(@ben))
    end
  end

  def test_stream_sends_a_visible_change_with_the_record_as_it_is_now
    create("a", "ada")
    on_server { @model.find("a").update!(title: "edited since") }

    with_sync_identity do
      sent = events(@ada)

      assert_equal %w[create update], sent.map { |event| event[:operation] }
      assert_equal ["edited since"] * 2, sent.map { |event| event[:attributes]["title"] }
      assert_equal [2, 2], sent.map { |event| event[:version] }
    end
  end

  def test_stream_sends_a_hidden_change_as_an_empty_destroy
    create("a", "ada")

    with_sync_identity do
      [@ben, nil].each do |identity|
        assert_equal [{ type: "Item", id: "a", operation: "destroy", version: 0, attributes: {} }], events(identity)
      end
    end
  end

  def test_a_record_that_leaves_an_identitys_sight_is_destroyed_there_only
    create("x", "public")
    on_server { @model.find("x").update!(state: "ada") }

    with_sync_identity do
      assert_equal %w[destroy destroy], events(@ben).map { |event| event[:operation] }
      assert_equal %w[create update], events(@ada).map { |event| event[:operation] }
      assert_equal "ada", events(@ada).last[:attributes]["state"]
    end
  end

  def test_destroys_and_unscoped_models_pass_through
    open_model = syncable_model("Open")
    InstantRecord.sync(@model, open_model)
    create("a", "ada")
    on_server { @model.find("a").destroy! }
    on_server { open_model.create!(id: "o", title: "for all") }

    with_sync_identity do
      sent = events(nil)

      assert_equal %w[destroy destroy create], sent.map { |event| event[:operation] }
      assert_equal "for all", sent.last[:attributes]["title"]
    end
  end

  def test_events_keep_their_change_log_ids
    create("a", "ada")
    create("p", "public")

    with_sync_identity do
      ids = InstantRecord::Change.order(:id).pluck(:id)

      assert_equal ids, InstantRecord::SyncScope.events_for(InstantRecord::Change.order(:id).to_a, nil).map(&:first)
    end
  end
end
