require "test_helper"

# The edges of the server's column merge: which side a colliding column goes
# to, what counts as a collision, and what each shape of value unions to.
class ColumnMergeEdgesTest < Minitest::Test
  HLC = InstantRecord::HLC

  def setup
    reset_instant_record_tables!
    @t0 = Time.utc(2026, 11, 21, 12, 0, 0, 0)
    @previous_drift = InstantRecord.config.max_clock_drift
    InstantRecord.config.max_clock_drift = 5
    @sequence = 0
  end

  def teardown
    InstantRecord.config.max_clock_drift = @previous_drift
    InstantRecord.sync
  end

  # --- What counts as a collision -------------------------------------------

  def test_lww_goes_to_the_incoming_write_when_the_clocks_are_equal
    model, record = synced_record(state: "open")
    server_hlc = HLC.from_time(@t0 + 2, node: "clientbb")
    update(model, { "state" => "theirs" }, hlc: server_hlc)

    result = update(model, { "state" => "mine" }, hlc: server_hlc)

    assert result[:merged]
    assert_equal "mine", record.reload.state
  end

  def test_lww_compares_with_the_clock_of_the_column_rather_than_the_record
    model, record = synced_record(title: "v1", state: "open")
    update(model, { "state" => "theirs" }, hlc: client_hlc(2, "clientbb"))
    update(model, { "title" => "later" }, hlc: client_hlc(6, "clientbb"), base_version: 2)

    result = update(model, { "state" => "mine" }, hlc: client_hlc(4))

    assert result[:merged]
    assert_equal ["later", "mine"], [record.reload.title, record.state]
  end

  def test_lww_compares_with_the_last_of_several_edits_to_a_column
    model, record = synced_record(state: "open")
    update(model, { "state" => "first" }, hlc: client_hlc(2, "clientbb"))
    update(model, { "state" => "second" }, hlc: client_hlc(6, "clientcc"), base_version: 2)

    assert update(model, { "state" => "mine" }, hlc: client_hlc(4))[:skipped]
    assert_equal "second", record.reload.state
  end

  def test_a_column_the_server_changed_and_changed_back_still_collides
    model, record = synced_record(state: "open") { sync_merge :state, :server_wins }
    server_update(record, { state: "locked" }, at: 1)
    server_update(record, { state: "open" }, at: 2)

    assert update(model, { "state" => "mine" }, hlc: client_hlc(3))[:skipped]
    assert_equal "open", record.reload.state
  end

  def test_only_the_changes_after_the_base_version_count
    model, record = synced_record(title: "v1", state: "open") { sync_merge :state, :server_wins }
    server_update(record, { state: "locked" }, at: 1)
    server_update(record, { title: "v3" }, at: 2)

    result = update(model, { "state" => "mine" }, hlc: client_hlc(3), base_version: 2)

    assert result[:merged]
    assert_equal "mine", record.reload.state
  end

  def test_another_records_changes_do_not_count
    model, record = synced_record(title: "v1", state: "open") { sync_merge :state, :server_wins }
    other = HLC.with_clock(-> { @t0 }) { on_server { model.create!(id: "other", state: "open") } }
    server_update(other, { state: "locked" }, at: 1)
    server_update(record, { title: "v2" }, at: 1)
    log_change_row(version: 2, payload: record.attributes.merge("state" => "locked"), type: "Elsewhere")

    update(model, { "state" => "mine" }, hlc: client_hlc(3))

    assert_equal "mine", record.reload.state
  end

  def test_a_logged_destroy_is_not_read_as_an_edit
    model, record = synced_record(title: "v1", state: "open") { sync_merge :state, :server_wins }
    server_update(record, { title: "v2" }, at: 1)
    log_change_row(version: 2, payload: {}, operation: "destroy")

    update(model, { "state" => "mine" }, hlc: client_hlc(3))

    assert_equal "mine", record.reload.state
  end

  def test_the_last_logged_row_of_the_base_version_is_the_base
    model, record = synced_record(owner: "a,b") { sync_merge :owner, :union }
    log_change_row(version: 1, payload: wire(record).merge("owner" => "a"))
    server_update(record, { owner: "a,b,c" }, at: 2)

    update(model, { "owner" => "a" }, hlc: client_hlc(3))

    assert_equal "a,b,c", record.reload.owner, "b was not in the base, so its absence removes nothing"
  end

  def test_another_types_row_is_not_the_base
    model, record = synced_record(title: "v1", state: "open") { sync_merge :state, :server_wins }
    log_change_row(version: 1, payload: wire(record).merge("state" => "elsewhere"), type: "Elsewhere")
    server_update(record, { title: "v2" }, at: 1)

    update(model, { "state" => "mine" }, hlc: client_hlc(3))

    assert_equal "mine", record.reload.state
  end

  # A column added after the history was logged.
  def test_a_column_the_logged_payloads_lack_collides
    model, record = synced_record(title: "v1", state: "open") { sync_merge :state, :server_wins }
    server_update(record, { title: "v2" }, at: 1)
    InstantRecord::Change.where(record_id: "r-1").each do |change|
      change.update!(attributes_payload: change.attributes_payload.except("state"))
    end

    assert update(model, { "state" => "mine" }, hlc: client_hlc(3))[:skipped]
  end

  def test_changes_are_read_in_version_order
    model, record = synced_record(state: "open")
    payload = wire(record)
    record.update_columns(state: "third", server_version: 3)
    third = log_change_row(version: 3, payload: payload.merge("state" => "third"))
    second = log_change_row(version: 2, payload: payload.merge("state" => "second"))
    assert_operator third.id, :<, second.id
    HLC.set_change_hlc(third.id, client_hlc(3, "clientcc"))
    HLC.set_change_hlc(second.id, client_hlc(6, "clientbb"))
    HLC.set_record_hlc("Task", "r-1", client_hlc(6, "clientbb"))

    assert update(model, { "state" => "mine" }, hlc: client_hlc(4))[:merged]
    assert_equal "mine", record.reload.state
  end

  def test_a_change_without_a_stored_clock_is_dated_by_its_updated_at
    model, record = synced_record(state: "open")
    server_update(record, { state: "theirs" }, at: 2)
    change = forget_clock(version: 2)
    change.update!(attributes_payload: change.attributes_payload.merge("updated_at" => (@t0 + 8).iso8601(6)))

    assert update(model, { "state" => "older" }, hlc: client_hlc(7), at: 9)[:skipped]
    assert update(model, { "state" => "newer" }, hlc: client_hlc(9), at: 9)[:merged]
  end

  def test_a_change_without_a_clock_or_updated_at_is_dated_by_its_row
    model, record = synced_record(state: "open")
    server_update(record, { state: "theirs" }, at: 2)
    change = forget_clock(version: 2)
    change.update!(attributes_payload: change.attributes_payload.except("updated_at"), created_at: @t0 + 8)

    assert update(model, { "state" => "older" }, hlc: client_hlc(7), at: 9)[:skipped]
    assert update(model, { "state" => "newer" }, hlc: client_hlc(9), at: 9)[:merged]
  end

  def test_a_change_that_cannot_be_dated_yields_to_lww_and_holds_under_server_wins
    model, record = synced_record(state: "open", title: "v1") { sync_merge :title, :server_wins }
    server_update(record, { state: "theirs", title: "theirs" }, at: 2)
    change = forget_clock(version: 2)
    change.update!(attributes_payload: change.attributes_payload.merge("updated_at" => "no time"))

    result = update(model, { "state" => "mine", "title" => "mine" }, hlc: client_hlc(-5))

    assert result[:merged]
    assert_equal ["mine", "theirs"], [record.reload.state, record.title]
  end

  def test_a_base_whose_payload_is_not_a_hash_makes_every_column_collide
    model, record = synced_record(title: "v1", state: "open") { sync_merge :state, :server_wins }
    server_update(record, { title: "v2" }, at: 1)
    InstantRecord::Change.find_by!(version: 1).update!(attributes_payload: "not a hash")

    assert update(model, { "state" => "mine" }, hlc: client_hlc(3))[:skipped]
  end

  def test_a_later_payload_that_is_not_a_hash_makes_every_column_collide
    model, record = synced_record(title: "v1", state: "open") { sync_merge :state, :server_wins }
    server_update(record, { title: "v2" }, at: 1)
    InstantRecord::Change.find_by!(version: 2).update!(attributes_payload: "not a hash")

    assert update(model, { "state" => "mine" }, hlc: client_hlc(3))[:skipped]
  end

  # --- Columns changed without a change row ----------------------------------

  def test_an_unlogged_column_update_collides_at_the_records_clock
    model, record = synced_record(title: "v1", state: "open")
    update(model, { "title" => "v2" }, hlc: client_hlc(4, "clientbb"))
    record.reload.update_columns(state: "by hand")

    assert update(model, { "state" => "older" }, hlc: client_hlc(3))[:skipped]
    assert_equal "by hand", record.reload.state
    assert update(model, { "state" => "newer" }, hlc: client_hlc(5))[:merged]
    assert_equal "newer", record.reload.state
  end

  def test_an_unlogged_column_update_is_the_servers_even_after_the_clients_own_edits
    model, record = synced_record(state: "open", title: "v1") { sync_merge :state, :server_wins }
    update(model, { "state" => "mine" }, hlc: client_hlc(2))
    record.reload.update_columns(state: "by hand")

    assert update(model, { "state" => "mine again" }, hlc: client_hlc(3))[:skipped]
    assert_equal "by hand", record.reload.state
  end

  def test_unlogged_update_of_one_column_leaves_the_others_disjoint
    model, record = synced_record(state: "open", title: "v1", owner: "ada") do
      sync_merge :state, :server_wins
      sync_merge :owner, :server_wins
    end
    server_update(record, { title: "v2" }, at: 1)
    record.update_columns(state: "by hand")

    assert update(model, { "state" => "mine", "owner" => "grace" }, hlc: client_hlc(3))[:merged]
    assert_equal ["by hand", "grace"], [record.reload.state, record.owner]
  end

  # --- One client's own sequence of edits ------------------------------------

  def test_the_same_nodes_edit_must_be_strictly_newer_to_be_its_own_sequel
    model, record = synced_record(state: "open") { sync_merge :state, :server_wins }
    update(model, { "state" => "first" }, hlc: client_hlc(2))

    assert update(model, { "state" => "same" }, hlc: client_hlc(2))[:skipped]
    assert update(model, { "state" => "older" }, hlc: client_hlc(1))[:skipped]
    assert update(model, { "state" => "newer" }, hlc: client_hlc(3))[:merged]
    assert_equal "newer", record.reload.state
  end

  def test_a_column_one_client_edited_twice_is_still_its_own
    model, record = synced_record(state: "open") { sync_merge :state, :server_wins }
    update(model, { "state" => "first" }, hlc: client_hlc(1))
    update(model, { "state" => "second" }, hlc: client_hlc(2), base_version: 2)

    assert update(model, { "state" => "third" }, hlc: client_hlc(3))[:merged]
    assert_equal "third", record.reload.state
  end

  def test_a_column_another_node_also_edited_is_not_a_sequel
    [%w[clientaa clientbb], %w[clientbb clientaa]].each_with_index do |(first, second), index|
      id = "seq-#{index}"
      model, record = synced_record(id: id, state: "open") { sync_merge :state, :server_wins }
      update(model, { "state" => "first" }, hlc: client_hlc(2, first), id: id)
      update(model, { "state" => "second" }, hlc: client_hlc(3, second), base_version: 2, id: id)

      assert update(model, { "state" => "mine" }, hlc: client_hlc(4), id: id)[:skipped]
      assert_equal "second", record.reload.state
    end
  end

  def test_server_and_legacy_nodes_never_count_as_one_client
    [HLC::SERVER_NODE, HLC::LEGACY_NODE].each do |node|
      model, = synced_record(id: node, state: "open") { sync_merge :state, :server_wins }
      update(model, { "state" => "first" }, hlc: client_hlc(2, node), id: node)

      assert update(model, { "state" => "second" }, hlc: client_hlc(3, node), id: node)[:skipped], node
    end
  end

  def test_the_same_nodes_sequel_replaces_a_union_column
    model, record = synced_record(owner: "a,b") { sync_merge :owner, :union }
    update(model, { "owner" => "a,b,c" }, hlc: client_hlc(2))
    update(model, { "owner" => "z" }, hlc: client_hlc(3))

    assert_equal "z", record.reload.owner
  end

  # --- No base in the change log ---------------------------------------------

  def test_without_a_base_every_column_collides_at_the_records_clock
    [0, 1].each do |base_version|
      id = "nobase-#{base_version}"
      model, record = synced_record(id: id, title: "v1", state: "open", owner: "ada") { sync_merge :owner, :server_wins }
      update(model, { "title" => "v2" }, hlc: client_hlc(4, "clientbb"), id: id)
      lose_history(id)

      older = update(model, { "state" => "older", "owner" => "mine" }, hlc: client_hlc(3), base_version: base_version, id: id)
      assert older[:skipped], "base #{base_version}"
      assert_equal ["open", "ada"], [record.reload.state, record.owner]

      equal = update(model, { "state" => "equal", "owner" => "mine" },
        hlc: client_hlc(4, "clientcc"), base_version: base_version, id: id)
      assert equal[:merged]
      assert_equal ["equal", "ada"], [record.reload.state, record.owner]
    end
  end

  def test_without_a_base_the_node_of_the_records_clock_may_continue_its_own_edits
    model, record = synced_record(state: "open") { sync_merge :state, :server_wins }
    update(model, { "state" => "first" }, hlc: client_hlc(2))
    lose_history("r-1")

    assert update(model, { "state" => "other" }, hlc: client_hlc(3, "clientbb"))[:skipped]
    assert update(model, { "state" => "sequel" }, hlc: client_hlc(3))[:merged]
    assert_equal "sequel", record.reload.state
  end

  # Base version 0 asks for no base even when a row of that version is logged.
  def test_base_version_zero_never_looks_for_a_base
    model, record = synced_record(title: "v1", state: "open") { sync_merge :state, :server_wins }
    log_change_row(version: 0, payload: wire(record))

    assert update(model, { "state" => "mine" }, hlc: client_hlc(3), base_version: 0)[:skipped]
  end

  # Reading every column before the save is what lets Rails notice that a
  # serialized column is stored in another spelling than its coder writes.
  def test_without_a_base_the_save_rewrites_a_serialized_column_stored_in_another_spelling
    model, record = synced_record(title: "v1", owner: %w[a b]) { serialize :owner, coder: JSON }
    server_update(record, { title: "v2" }, at: 1)
    lose_history("r-1")
    connection = ActiveRecord::Base.connection
    connection.execute(%q(UPDATE items SET owner = '[ "a", "b" ]' WHERE id = 'r-1'))

    assert update(model, { "title" => "mine" }, hlc: client_hlc(3))[:merged]
    assert_equal '["a","b"]', connection.select_value("SELECT owner FROM items WHERE id = 'r-1'")
  end

  def test_a_record_without_any_clock_yields_to_lww_and_reports_no_clock_when_skipped
    with_items_table("merge_loose_items", updated_at: true) do
      model, record = synced_record(title: "v1", state: "open") do
        self.table_name = "merge_loose_items"
        sync_merge :state, :server_wins
      end
      server_update(record, { title: "v2" }, at: 1)
      lose_history("r-1")
      HLC.delete_record_hlc("Task", "r-1")
      record.update_columns(updated_at: nil)

      skipped = update(model, { "state" => "mine" }, hlc: client_hlc(-9))
      assert_equal %i[status version skipped server_attributes mutation_id], skipped.keys

      merged = update(model, { "title" => "mine" }, hlc: client_hlc(-9))
      assert merged[:merged]
      assert_equal "mine", record.reload.title
      assert_equal HLC.physical_time(merged[:hlc]), record.updated_at
    end
  end

  def test_a_model_without_updated_at_merges
    with_items_table("merge_bare_items", updated_at: false) do
      model, record = synced_record(title: "v1", state: "open") { self.table_name = "merge_bare_items" }
      server_update(record, { title: "v2" }, at: 1)

      assert update(model, { "state" => "mine" }, hlc: client_hlc(2))[:merged]
      assert_equal ["v2", "mine"], [record.reload.title, record.state]
    end
  end

  # --- Results and what is written -------------------------------------------

  def test_skipped_result_carries_the_servers_row_and_clock_and_writes_nothing
    model, record = synced_record(state: "open") { sync_merge :state, :server_wins }
    server_update(record, { state: "locked" }, at: 2)
    before = record.reload.attributes
    changes = InstantRecord::Change.count

    result = update(model, { "state" => "mine" }, hlc: client_hlc(3))

    assert_equal %i[status version skipped server_attributes hlc mutation_id], result.keys
    assert_equal ["applied", 2, true], result.values_at(:status, :version, :skipped)
    assert_equal wire(record), result[:server_attributes]
    assert_equal HLC.record_hlc("Task", "r-1"), result[:hlc]
    assert_equal before, record.reload.attributes
    assert_equal changes, InstantRecord::Change.count
  end

  def test_merged_result_and_its_change_row_carry_the_merged_record_under_one_new_clock
    model, record = synced_record(title: "v1", state: "open")
    server_update(record, { title: "v2" }, at: 2)
    record.update_columns(sync_state: "pending")

    result = update(model, { "state" => "mine" }, hlc: client_hlc(1))
    record.reload

    assert_equal %i[status version merged hlc server_attributes mutation_id], result.keys
    assert_equal ["applied", 3, true], result.values_at(:status, :version, :merged)
    assert_equal wire(record), result[:server_attributes]
    assert_equal "synced", record.sync_state
    change = InstantRecord::Change.order(:id).last
    assert_equal ["update", 3, wire(record)], [change.operation, change.version, change.attributes_payload]
    assert_equal result[:hlc], change.hlc
    assert_equal result[:hlc], HLC.record_hlc("Task", "r-1")
    assert_equal HLC::SERVER_NODE, HLC.node(result[:hlc])
    assert_equal HLC.physical_time(result[:hlc]), record.updated_at
  end

  def test_merged_clock_passes_an_incoming_clock_ahead_of_the_server
    model, record = synced_record(title: "v1", state: "open")
    server_update(record, { title: "v2" }, at: 2)

    result = update(model, { "state" => "mine" }, hlc: client_hlc(8), at: 4)

    assert_operator result[:hlc], :>, client_hlc(8)
    assert_equal @t0 + 8, record.reload.updated_at
  end

  def test_merged_clock_passes_a_record_clock_ahead_of_the_server
    model, record = synced_record(title: "v1", state: "open")
    server_update(record, { title: "v2" }, at: 2)
    HLC.set_record_hlc("Task", "r-1", client_hlc(60, "clientbb"))

    assert_operator update(model, { "state" => "mine" }, hlc: client_hlc(3))[:hlc], :>, client_hlc(60, "clientbb")
  end

  # Without Active Record's own stamp, which an unchanged updated_at would get.
  def test_merge_never_moves_updated_at_back
    model, record = synced_record(title: "v1", state: "open", created_at: @t0) { self.record_timestamps = false }
    server_update(record, { title: "v2" }, at: 2)
    record.update_columns(updated_at: @t0 + 60)

    update(model, { "state" => "mine" }, hlc: client_hlc(3))

    assert_equal @t0 + 60, record.reload.updated_at
  end

  def test_bookkeeping_columns_the_client_sent_are_not_merged
    model, record = synced_record(title: "v1", state: "open")
    server_update(record, { title: "v2" }, at: 2)
    created_at = record.reload.created_at

    update(model, { "state" => "mine", "created_at" => (@t0 - 99).iso8601(6), "server_version" => 40,
      "sync_state" => "pending" }, hlc: client_hlc(3))

    record.reload
    assert_equal [created_at, 3, "synced"], [record.created_at, record.server_version, record.sync_state]
  end

  def test_a_merge_that_takes_the_record_out_of_the_senders_reach_is_undone
    model = scoped_model("Task")
    InstantRecord.sync(model)
    record = HLC.with_clock(-> { @t0 }) { on_server { model.create!(id: "r-1", title: "v1", state: "ada") } }
    server_update(record, { title: "v2" }, at: 1)

    result = update(model, { "state" => "grace" }, hlc: client_hlc(2), identity: Person.new("ada"))

    assert_equal ["rejected", "not permitted"], result.values_at(:status, :reason)
    assert_equal ["ada", 2], [record.reload.state, record.server_version]
  end

  def test_a_merge_reads_the_base_then_the_changes_since_then_their_clocks
    model, record = synced_record(title: "v1", state: "open")
    server_update(record, { title: "v2" }, at: 1)
    server_update(record, { title: "v3" }, at: 2)

    reads = merge_reads { update(model, { "state" => "mine" }, hlc: client_hlc(3)) }
    assert_match(/"version" = .* ORDER BY .*"id" DESC LIMIT/, reads[0])
    assert_match(/version > .* ORDER BY .*"version" ASC, .*"id" ASC\z/, reads[1])
    assert_match(/instant_record_sync_metadata.* IN \(/, reads[2])
    assert_equal 3, reads.size

    lose_history("r-1")
    assert_equal 1, merge_reads { update(model, { "state" => "x" }, hlc: client_hlc(3)) }.size
    # Without a base version, the log says only whether the client created the record.
    created = merge_reads { update(model, { "state" => "x" }, hlc: client_hlc(3), base_version: 0) }
    assert_match(/"operation" = .* ORDER BY .*"id" DESC LIMIT/, created.first)
    assert_equal 1, created.size
  end

  # --- Union: comma-separated strings ----------------------------------------

  def test_union_of_csv
    assert_equal "c,d", union("a,b", "b,c", "a,d"), "each side's removal and each side's addition"
    assert_equal "a, b, c", union("a", "a, b", "a,c"), "the server's spaced separator"
    assert_equal "a, b, c", union("a", "a,b", "a, c"), "the client's spaced separator"
    assert_equal "a,b,c", union("a", " a ,,b", "a,c,"), "blanks and padding go"
    assert_equal "b", union("a", "a,b", ""), "a client that emptied the list removes what the base held"
    assert_equal "b", union("a", "a,b", nil), "nil is an empty list"
    assert_equal "c", union("a", nil, "a,c")
    assert_equal "b,c", union(nil, "b", "c"), "a nil base held nothing"
    assert_equal "b,c", union("", "b", "c")
    assert_equal "a,b,c", union("a", "a,b", "a,b,c,b"), "no duplicates"
  end

  def test_union_of_csv_without_a_base_removes_nothing
    assert_equal "a,b,c", union("a", "a,b", "c", has_base: false)
    assert_equal "a,b", union("a", "a,b", "", has_base: false)
  end

  def test_union_that_leaves_the_servers_value_is_skipped
    union("a", "a,b", "a")
    assert @result[:skipped]

    union("a", "a,b", "a,c")
    assert @result[:merged]
  end

  # --- Union: JSON arrays in strings -----------------------------------------

  def test_union_of_json_array_strings
    assert_equal '["c","d"]', union('["a","b"]', '["b","c"]', '["a","d"]')
    assert_equal '["a","b"]', union('["a"]', ' ["a"]', '["a","b"]'), "leading space"
    assert_equal '["b"]', union('["a"]', '["a","b"]', ""), "an empty client removes what the base held"
    assert_equal '["b"]', union('["a"]', '["a","b"]', nil)
    assert_equal '["b"]', union('["a"]', "", '["a","b"]'), "an empty server adds nothing back"
    assert_equal '[1,{"k":2}]', union("[1]", "[1]", '[1,{"k":2}]')
    assert_equal "[1,2,3]", union("[]", "[1,2]", "[3]")
  end

  def test_union_of_json_array_strings_without_a_usable_base
    assert_equal '["a","b","c"]', union('["a"]', '["a","b"]', '["c"]', has_base: false)
    assert_equal '["a","b","c"]', union("a", '["a","b"]', '["c"]'), "the base is not JSON"
    assert_equal '["a","b","c"]', union('{"a":1}', '["a","b"]', '["c"]'), "the base is another JSON type"
    assert_equal '["a","b","c"]', union("", '["a","b"]', '["c"]')
    assert_equal '["a","b","c"]', union(nil, '["a","b"]', '["c"]')
  end

  def test_union_of_a_json_array_string_with_anything_else_counts_the_other_side_as_empty
    assert_equal '["a","b"]', union("[]", '["a","b"]', "c")
    assert_equal '["a","b"]', union("[]", "c", '["a","b"]')
    assert_equal '["a"]', union("[]", '["a"]', '{"b":1}'), "an array is tried before an object"
    assert_equal '["a"]', union("[]", '{"b":1}', '["a"]')
    assert_equal '["a"]', union("[]", '["a"]', "5")
  end

  # Told from CSV by the spacing JSON writes.
  def test_union_knows_json_behind_leading_space_on_either_side
    assert_equal '["a","b"]', union("x", ' ["a", "b"]', "")
    assert_equal '["a","b"]', union("x", "", ' ["a", "b"]')
    assert_equal '{"a":1,"b":2}', union("x", ' {"a": 1, "b": 2}', "")
    assert_equal '{"a":1,"b":2}', union("x", "", ' {"a": 1, "b": 2}')
  end

  def test_union_of_json_strings_over_a_base_that_was_a_real_array_or_hash
    assert_equal '["b"]', union_json(["a", nil], '["a","b"]', "[null]")
    assert_equal '{"b":2}', union_json({ "a" => 1 }, '{"a":1,"b":2}', "{}")
  end

  def test_union_of_broken_json_falls_back_to_csv
    assert_equal '["a",["b"', union("", '["a"', '["b"')
    assert_equal '{"a",{"b"', union("", '{"a"', '{"b"')
    assert_equal "5,6", union("", "5", "6"), "JSON scalars are plain text"
  end

  # --- Union: JSON objects in strings ----------------------------------------

  def test_union_of_json_object_strings
    assert_equal '{"a":1,"b":2,"c":3}', union('{"a":1}', '{"a":1,"b":2}', '{"a":1,"c":3}')
    assert_equal '{"b":2}', union('{"a":1}', '{"a":1,"b":2}', "{}"), "the client removed a"
    assert_equal '{"b":2}', union('{"a":1}', '{"a":1,"b":2}', ""), "an empty client removed a"
    assert_equal '{"b":2}', union('{"a":1}', '{"a":1,"b":2}', nil)
    assert_equal '{"a":1,"b":2}', union("{}", "", '{"a":1,"b":2}')
    assert_equal '{"a":1,"b":2}', union("{}", ' {"a":1}', '{"b":2}'), "leading space"
    assert_equal '{"a":1}', union("{}", '{"a":1}', "text")
    assert_equal '{"a":1}', union("{}", "text", '{"a":1}')
  end

  def test_union_of_json_object_strings_without_a_usable_base
    ["text", "[]", "", nil].each do |base|
      assert_equal '{"a":1,"b":2}', union(base, '{"a":1}', '{"a":9,"b":2}', client_at: 1), base.inspect
      assert_equal '{"a":9,"b":2}', union(base, '{"a":1}', '{"a":9,"b":2}', client_at: 3), base.inspect
    end
  end

  # --- Union: hashes ---------------------------------------------------------

  def test_union_of_hashes_gives_a_key_both_sides_changed_to_the_later_write
    base = { "a" => 1 }
    assert_equal({ "a" => 2 }, union_json(base, { "a" => 2 }, { "a" => 3 }, client_at: 1))
    assert_equal({ "a" => 3 }, union_json(base, { "a" => 2 }, { "a" => 3 }, client_at: 3))
    assert_equal({ "a" => 2 }, union_json(base, { "a" => 2 }, {}, client_at: 1), "an older removal loses")
    assert_equal({}, union_json(base, { "a" => 2 }, {}, client_at: 3), "a later removal wins")
    assert_equal({ "x" => 0 }, union_json(base, { "x" => 0 }, { "a" => 3 }, client_at: 1), "the server's removal holds")
    assert_equal({ "x" => 0, "a" => 3 }, union_json(base, { "x" => 0 }, { "a" => 3 }, client_at: 3))
  end

  def test_union_of_hashes_gives_a_key_both_sides_added_to_the_later_write
    assert_equal({ "a" => 1, "n" => 2 }, union_json({ "a" => 1 }, { "a" => 1, "n" => 2 }, { "a" => 1, "n" => 3 }, client_at: 1))
    assert_equal({ "a" => 1, "n" => 3 }, union_json({ "a" => 1 }, { "a" => 1, "n" => 2 }, { "a" => 1, "n" => 3 }, client_at: 3))
  end

  def test_union_of_hashes_keeps_what_the_client_left_alone_however_late_it_writes
    base = { "a" => 1, "b" => 1 }
    assert_equal({ "a" => 2, "b" => 1, "c" => 3 }, union_json(base, { "a" => 2, "b" => 1 }, base.merge("c" => 3), client_at: 3))
    assert_equal({ "b" => 1, "c" => 3 }, union_json(base, { "b" => 1 }, base.merge("c" => 3), client_at: 3))
  end

  def test_union_of_hashes_takes_the_clients_lone_change_however_early_it_writes
    base = { "a" => 1, "b" => 1 }
    server = base.merge("s" => 1)
    assert_equal({ "a" => 5, "b" => 1, "s" => 1 }, union_json(base, server, { "a" => 5, "b" => 1 }, client_at: 1))
    assert_equal({ "b" => 1, "s" => 1 }, union_json(base, server, { "b" => 1 }, client_at: 1))
  end

  def test_union_of_hashes_tells_a_nil_value_from_a_missing_key
    assert_equal({ "s" => 1, "n" => nil }, union_json({}, { "s" => 1 }, { "n" => nil }, client_at: 1))
    assert_equal({ "s" => 1 }, union_json({ "n" => nil }, { "n" => nil, "s" => 1 }, {}, client_at: 1))
    assert_equal({ "s" => 1 }, union_json({ "n" => nil }, { "s" => 1 }, { "n" => 2 }, client_at: 1),
      "the server's removal of a nil key is a change")
  end

  def test_union_of_hashes_without_a_base
    assert_equal({ "a" => 1, "s" => 1, "c" => 3 },
      union_json({}, { "a" => 1, "s" => 1 }, { "a" => 2, "c" => 3 }, client_at: 1, has_base: false))
    assert_equal({ "a" => 2, "s" => 1, "c" => 3 },
      union_json({}, { "a" => 1, "s" => 1 }, { "a" => 2, "c" => 3 }, client_at: 3, has_base: false))
    assert_equal({ "a" => 1, "c" => 3 }, union_json([1], { "a" => 1 }, { "c" => 3 }), "the base is another type")
  end

  def test_union_of_hashes_lets_the_incoming_write_win_at_an_equal_clock_or_over_an_undated_change
    [false, true].each do |undated|
      id = "tie-#{undated}"
      model, record = synced_record(id: id, owner: { "a" => 1 }) do
        serialize :owner, coder: JSON
        sync_merge :owner, :union
      end
      update(model, { "owner" => { "a" => 2 } }, hlc: client_hlc(2, "clientbb"), id: id)
      if undated
        change = forget_clock(version: 2, id: id)
        change.update!(attributes_payload: change.attributes_payload.merge("updated_at" => "no time"))
      end

      update(model, { "owner" => { "a" => 3 } }, hlc: client_hlc(undated ? -5 : 2, "clientbb"), id: id)
      assert_equal({ "a" => 3 }, record.reload.owner, id)
    end
  end

  # --- Union: arrays and mixed types -----------------------------------------

  def test_union_of_arrays
    assert_equal %w[c d], union_json(%w[a b], %w[b c], %w[a d])
    assert_equal %w[b], union_json(%w[a], %w[a b], [])
    assert_equal %w[a b c], union_json(%w[a], %w[a b], %w[c], has_base: false)
    assert_equal %w[a b c], union_json("a", %w[a b], %w[c]), "a base of another type is no base"
    assert_equal [1, 2, "1"], union_json([], [1, 1, 2], ["1"]), "no duplicates, no coercion"
  end

  def test_union_of_an_array_with_anything_else_wraps_the_other_side
    assert_equal %w[a b], union_json([], ["a"], "b")
    assert_equal %w[b a], union_json([], "b", ["a"])
    assert_equal ["a"], union_json([], nil, ["a"])
    assert_equal ["b"], union_json(["a"], %w[a b], nil), "nil removes what the base held"
    assert_equal ["a", ["k", 1]], union_json([], ["a"], { "k" => 1 }), "an array is tried before a hash"
  end

  def test_union_of_a_hash_with_anything_else_counts_the_other_side_as_empty
    assert_equal({ "a" => 1 }, union_json({}, { "a" => 1 }, "text"))
    assert_equal({ "a" => 1 }, union_json({}, "text", { "a" => 1 }))
    assert_equal({ "b" => 2 }, union_json({ "a" => 1 }, { "a" => 1, "b" => 2 }, nil))
  end

  private

  def client_hlc(seconds, node = "clientaa")
    HLC.from_time(@t0 + seconds, node: node)
  end

  def wire(record)
    InstantRecord.wire_attributes(record.attributes)
  end

  # A table other than `items`, gone again with the transaction it is made in.
  def with_items_table(name, updated_at:)
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.create_table(name, id: :string) do |t|
        t.string :title
        t.string :state
        t.integer :server_version, null: false, default: 0
        t.string :sync_state, null: false, default: "synced"
        t.datetime :updated_at if updated_at
      end
      yield
      raise ActiveRecord::Rollback
    end
  end

  # Each record starts the server's own clock over, so that a test may tell
  # several stories that all begin at @t0.
  def synced_record(id: "r-1", **attributes, &body)
    InstantRecord::SyncMetadata.delete(HLC::KEY_LAST)
    model = syncable_model("Task", &body)
    InstantRecord.sync(model)
    record = HLC.with_clock(-> { @t0 }) do
      on_server { model.create!(id: id, **attributes, **stamp(model, 0)) }
    end
    [model, record]
  end

  def server_update(record, attributes, at:)
    HLC.with_clock(-> { @t0 + at }) { on_server { record.update!(**attributes, **stamp(record.class, at)) } }
  end

  # Active Record would stamp the real time, which is after every test's @t0.
  def stamp(model, seconds)
    model.column_names.include?("updated_at") ? { updated_at: @t0 + seconds } : {}
  end

  def update(model, changes, hlc:, base_version: 1, id: "r-1", at: 4, identity: nil)
    mutation = {
      id: "m-#{@sequence += 1}", record_type: model.name, record_id: id, operation: "update",
      base_version: base_version, hlc: hlc, changes: changes
    }
    HLC.with_clock(-> { @t0 + at }) { on_server { InstantRecord::MutationApplier.apply(mutation, identity) } }
  end

  def log_change_row(version:, payload:, operation: "update", type: "Task", **rest)
    InstantRecord::Change.create!(record_type: type, record_id: "r-1", operation: operation,
      version: version, attributes_payload: payload, **rest)
  end

  # The history is there, under another record: the same as a pruned log.
  def lose_history(id)
    InstantRecord::Change.where(record_id: id).update_all(record_id: "pruned-#{id}")
  end

  def forget_clock(version:, id: "r-1")
    InstantRecord::Change.find_by!(record_id: id, version: version).tap do |change|
      InstantRecord::SyncMetadata.delete("#{HLC::CHANGE_PREFIX}#{change.id}")
    end
  end

  # What a union column holds after the server went from `base` to `server` at
  # second 2 and a client, from the same base, wrote `client` at `client_at`.
  def union(base, server, client, client_at: 1, has_base: true, json: false)
    id = "u-#{@sequence += 1}"
    model, record = synced_record(id: id, title: "v1", owner: base) do
      serialize :owner, coder: JSON if json
      sync_merge :owner, :union
    end
    server_update(record, { title: "v2", owner: server }, at: 2)
    lose_history(id) unless has_base
    @result = update(model, { "owner" => client }, hlc: client_hlc(client_at), id: id)
    assert_equal "applied", @result[:status]
    record.reload.owner
  end

  def union_json(base, server, client, **options)
    union(base, server, client, json: true, **options)
  end

  # Reads of the change log, and batched reads of its clocks.
  def merge_reads
    reads = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql]
      reads << sql if sql.match?(/\ASELECT .*(FROM "instant_record_changes"|"key" IN \()/)
    end
    yield
    reads
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
