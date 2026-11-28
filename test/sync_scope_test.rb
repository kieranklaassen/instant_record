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

  def test_events_for_returns_distinct_mutable_hashes_for_duplicate_changes_of_same_record
    ruled = scoped_model("DupItem")
    InstantRecord.sync(ruled)
    ada = Person.new("ada")

    on_server do
      row = ruled.create!(id: "d-1", title: "v1", state: "ada")
      row.update!(title: "v2")
      row.update!(title: "v3")
    end

    changes = InstantRecord::Change.order(:id).to_a
    events = InstantRecord::SyncScope.events_for(changes, ada)

    assert_equal %w[create update update], events.map { |_, ev| ev[:operation] }
    assert_equal 3, events.map { |_, ev| ev.object_id }.uniq.size
    expected_keys = InstantRecord.record_payload(ruled.find("d-1")).merge(operation: "create").keys

    events.each_with_index do |(_, ev), idx|
      refute ev.frozen?
      assert_equal expected_keys, ev.keys
      assert_equal "v3", ev[:attributes]["title"]
      assert_equal 3, ev[:version]
      ev[:server_time] = "t-#{idx}"
    end
    assert_equal %w[t-0 t-1 t-2], events.map { |_, ev| ev[:server_time] }
  end

  def test_events_for_handles_mixed_ruled_plain_destroy_revoked_and_hlc_stamps
    ruled = scoped_model("MixedRuled")
    plain = syncable_model("MixedPlain")
    InstantRecord.sync(ruled, plain)
    ada = Person.new("ada")

    on_server do
      vis = ruled.create!(id: "r-vis", title: "visible", state: "ada")
      vis.update!(title: "visible-2")
      ruled.create!(id: "r-hid", title: "secret", state: "bob")
      revoked = ruled.create!(id: "r-rev", title: "was-public", state: "public")
      revoked.update!(state: "bob")
      gone = ruled.create!(id: "r-gone", title: "deleted", state: "ada")
      gone.destroy!

      p1 = plain.create!(id: "p-1", title: "open-1")
      p1.update!(title: "open-2")
      p2 = plain.create!(id: "p-2", title: "open-gone")
      p2.destroy!
    end

    changes = InstantRecord::Change.order(:id).to_a
    # Clear one change stamp and one record stamp to verify absent :hlc parity.
    plain_create = changes.find { |c| c.record_type == "MixedPlain" && c.operation == "create" && c.record_id == "p-1" }
    InstantRecord::SyncMetadata.delete("#{InstantRecord::HLC::CHANGE_PREFIX}#{plain_create.id}")
    InstantRecord::HLC.delete_record_hlc("MixedRuled", "r-vis")

    events = InstantRecord::SyncScope.events_for(changes, ada)
    assert_equal changes.map(&:id), events.map(&:first)

    expected = changes.map do |change|
      if change.operation == "destroy" || change.record_type == "MixedPlain"
        [change.id, change.as_event]
      else
        record = InstantRecord::SyncScope.visible(ruled, ada).find_by(id: change.record_id)
        ev =
          if record
            InstantRecord.record_payload(record).merge(operation: change.operation)
          else
            { type: change.record_type, id: change.record_id, operation: "destroy", version: 0, attributes: {} }
          end
        [change.id, ev]
      end
    end

    assert_equal expected, events
    assert_equal expected.to_json, events.to_json
    events.zip(expected).each do |(_, actual_ev), (_, expected_ev)|
      assert_equal expected_ev.keys, actual_ev.keys
    end

    plain_ev = events.find { |id, _| id == plain_create.id }.last
    refute plain_ev.key?(:hlc)
    vis_ev = events.find { |_, ev| ev[:type] == "MixedRuled" && ev[:id] == "r-vis" }.last
    refute vis_ev.key?(:hlc)
  end

  def test_events_for_handles_empty_batches_and_active_record_relations
    ruled = scoped_model("RelRuled")
    plain = syncable_model("RelPlain")
    InstantRecord.sync(ruled, plain)
    ada = Person.new("ada")

    assert_equal [], InstantRecord::SyncScope.events_for([], ada)
    assert_equal [], InstantRecord::SyncScope.events_for(InstantRecord::Change.none, ada)

    on_server do
      ruled.create!(id: "rr-1", title: "mine", state: "ada")
      plain.create!(id: "rp-1", title: "open")
    end

    relation = InstantRecord::Change.order(:id)
    refute relation.loaded?
    from_relation = InstantRecord::SyncScope.events_for(relation, ada)
    from_array = InstantRecord::SyncScope.events_for(InstantRecord::Change.order(:id).to_a, ada)

    assert_equal from_array, from_relation
    assert_equal 2, from_relation.size
  end

  def test_events_for_combines_syncable_to_sync_scope_sync_partition_and_custom_models
    combined = syncable_model("CombinedItem") do
      sync_scope :owner
      sync_partition :state
      syncable_to { |_who| where(title: "allowed") }
    end
    custom = syncable_model("CustomRuled") do
      syncable_to { |who| where(owner: who).select(:id, :title, :owner, :server_version) }

      def attributes
        super.merge("extra" => "custom")
      end
    end
    InstantRecord.sync(combined, custom)

    on_server do
      combined.create!(id: "c-ok", owner: "ada", state: "acme", title: "allowed")
      combined.create!(id: "c-wrong-owner", owner: "bob", state: "acme", title: "allowed")
      combined.create!(id: "c-wrong-part", owner: "ada", state: "beta", title: "allowed")
      combined.create!(id: "c-wrong-rule", owner: "ada", state: "acme", title: "denied")
      custom.create!(id: "x-vis", owner: "ada", title: "custom-vis")
      custom.create!(id: "x-hid", owner: "bob", title: "custom-hid")
    end

    changes = InstantRecord::Change.order(:id).to_a

    # Partition "state:acme" for identity "ada"
    by_id = InstantRecord::SyncScope.events_for(changes, "ada", partition: "state:acme").to_h { |_, ev| [ev[:id], ev] }
    assert_equal "create", by_id["c-ok"][:operation]
    assert_equal "allowed", by_id["c-ok"][:attributes]["title"]
    %w[c-wrong-owner c-wrong-part c-wrong-rule x-hid].each do |hidden_id|
      assert_equal "destroy", by_id[hidden_id][:operation], hidden_id
      assert_equal 0, by_id[hidden_id][:version], hidden_id
      assert_equal({}, by_id[hidden_id][:attributes], hidden_id)
    end
    assert_equal "create", by_id["x-vis"][:operation]
    assert_equal "custom", by_id["x-vis"][:attributes]["extra"]

    # Nil partition hides all partitioned CombinedItem records
    no_part = InstantRecord::SyncScope.events_for(changes, "ada", partition: nil).to_h { |_, ev| [ev[:id], ev] }
    assert_equal "destroy", no_part["c-ok"][:operation]
    assert_equal "create", no_part["x-vis"][:operation]
  end
end
