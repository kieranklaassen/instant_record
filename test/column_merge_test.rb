require "test_helper"

class ColumnMergeTest < Minitest::Test
  HLC = InstantRecord::HLC

  def setup
    reset_instant_record_tables!
    @t0 = Time.utc(2026, 11, 21, 12, 0, 0, 0)
    @previous_drift = InstantRecord.config.max_clock_drift
    InstantRecord.config.max_clock_drift = 5
  end

  def teardown
    InstantRecord.config.max_clock_drift = @previous_drift
    InstantRecord.sync
  end

  def apply_mutation(mutation, at:)
    HLC.with_clock(-> { at }) do
      on_server { InstantRecord::MutationApplier.apply(mutation) }
    end
  end

  def test_disjoint_concurrent_column_edits_merge_cleanly_even_when_second_hlc_is_older
    model = syncable_model("Task")
    InstantRecord.sync(model)

    record = HLC.with_clock(-> { @t0 }) do
      on_server { model.create!(id: "t-1", title: "Draft", state: "open", owner: "ada") }
    end
    assert_equal 1, record.server_version

    # Client A edits `title` at t0 + 10s (newer HLC) and syncs first -> v2.
    res_a = apply_mutation({
      id: "m-a", record_type: "Task", record_id: "t-1", operation: "update",
      base_version: 1, hlc: HLC.from_time(@t0 + 10, node: "clientaa"),
      changes: { "title" => "Final", "updated_at" => (@t0 + 10).iso8601(6) }
    }, at: @t0 + 10)
    assert_equal "applied", res_a[:status]
    assert_equal 2, res_a[:version]

    # Client B edits `state` at t0 + 5s (OLDER HLC than Client A!) from base_version: 1 -> must merge!
    res_b = apply_mutation({
      id: "m-b", record_type: "Task", record_id: "t-1", operation: "update",
      base_version: 1, hlc: HLC.from_time(@t0 + 5, node: "clientbb"),
      changes: { "state" => "closed", "updated_at" => (@t0 + 5).iso8601(6) }
    }, at: @t0 + 11)

    assert_equal "applied", res_b[:status]
    assert res_b[:merged], "disjoint concurrent column edits should report merged: true"
    refute res_b[:skipped]
    assert_equal 3, res_b[:version]
    assert_equal "Final", res_b[:server_attributes]["title"]
    assert_equal "closed", res_b[:server_attributes]["state"]
    assert_operator res_b[:hlc], :>, res_a[:hlc], "merged HLC must supersede both prior writes"

    record.reload
    assert_equal "Final", record.title
    assert_equal "closed", record.state
    assert_equal "ada", record.owner
    assert_equal 3, record.server_version
  end

  def test_same_column_collision_defaults_to_hlc_lww
    model = syncable_model("Task")
    InstantRecord.sync(model)

    record = HLC.with_clock(-> { @t0 }) do
      on_server { model.create!(id: "t-lww", title: "v1", state: "open") }
    end

    # Client A edits `title` at t0 + 10s -> v2.
    apply_mutation({
      id: "m-1", record_type: "Task", record_id: "t-lww", operation: "update",
      base_version: 1, hlc: HLC.from_time(@t0 + 10, node: "clientaa"),
      changes: { "title" => "Client A" }
    }, at: @t0 + 10)

    # Client B edits `title` at t0 + 5s (older) -> skipped.
    losing = apply_mutation({
      id: "m-2", record_type: "Task", record_id: "t-lww", operation: "update",
      base_version: 1, hlc: HLC.from_time(@t0 + 5, node: "clientbb"),
      changes: { "title" => "Client B older" }
    }, at: @t0 + 11)

    assert losing[:skipped]
    assert_equal 2, losing[:version]
    assert_equal "Client A", losing[:server_attributes]["title"]
    assert_equal "Client A", record.reload.title

    # Client C edits `title` at t0 + 12s (newer) from base_version: 1 -> wins!
    winning = apply_mutation({
      id: "m-3", record_type: "Task", record_id: "t-lww", operation: "update",
      base_version: 1, hlc: HLC.from_time(@t0 + 12, node: "clientcc"),
      changes: { "title" => "Client C newer" }
    }, at: @t0 + 12)

    refute winning[:skipped]
    assert winning[:merged]
    assert_equal 3, winning[:version]
    assert_equal "Client C newer", record.reload.title
  end

  def test_partial_merge_keeps_disjoint_column_while_dropping_losing_colliding_column
    model = syncable_model("Task")
    InstantRecord.sync(model)

    record = HLC.with_clock(-> { @t0 }) do
      on_server { model.create!(id: "t-partial", title: "v1", state: "open") }
    end

    # Server / Client A updates `title` at t0 + 10s -> v2.
    apply_mutation({
      id: "m-a", record_type: "Task", record_id: "t-partial", operation: "update",
      base_version: 1, hlc: HLC.from_time(@t0 + 10, node: "clientaa"),
      changes: { "title" => "Server Winner" }
    }, at: @t0 + 10)

    # Client B updates BOTH `title` (collides & loses at t0 + 5s) AND `state` (disjoint & wins!).
    res = apply_mutation({
      id: "m-b", record_type: "Task", record_id: "t-partial", operation: "update",
      base_version: 1, hlc: HLC.from_time(@t0 + 5, node: "clientbb"),
      changes: { "title" => "Client Loser", "state" => "done" }
    }, at: @t0 + 11)

    assert res[:merged]
    refute res[:skipped]
    assert_equal 3, res[:version]
    assert_equal "Server Winner", record.reload.title
    assert_equal "done", record.state
    assert_equal "Server Winner", res[:server_attributes]["title"]
    assert_equal "done", res[:server_attributes]["state"]
  end

  def test_server_wins_policy_keeps_server_value_on_collision_even_when_client_hlc_is_newer
    model = syncable_model("PolicyTask") do
      sync_merge :state, :server_wins
    end
    InstantRecord.sync(model)

    record = HLC.with_clock(-> { @t0 }) do
      on_server { model.create!(id: "t-sw", title: "v1", state: "open") }
    end

    # Server changes `state` to "locked" at t0 + 2s -> v2.
    HLC.with_clock(-> { @t0 + 2 }) do
      on_server { record.update!(state: "locked") }
    end

    # Client edits `state` (collides -> :server_wins drops it even though HLC is newer!)
    # AND `title` (disjoint -> merges cleanly!).
    res = apply_mutation({
      id: "m-sw-1", record_type: "PolicyTask", record_id: "t-sw", operation: "update",
      base_version: 1, hlc: HLC.from_time(@t0 + 5, node: "clientaa"),
      changes: { "state" => "reopened", "title" => "updated title" }
    }, at: @t0 + 5)

    assert res[:merged]
    assert_equal "locked", record.reload.state, ":server_wins must keep server value on same-column collision"
    assert_equal "updated title", record.title, "disjoint column must still merge"

    # When NO concurrent server edit touched `state`, client CAN update a :server_wins column!
    clean = apply_mutation({
      id: "m-sw-2", record_type: "PolicyTask", record_id: "t-sw", operation: "update",
      base_version: record.server_version, hlc: HLC.from_time(@t0 + 8, node: "clientaa"),
      changes: { "state" => "archived" }
    }, at: @t0 + 8)

    refute clean[:skipped]
    assert_equal "archived", record.reload.state
  end

  def test_same_client_sequential_offline_edits_on_server_wins_column_do_not_conflict_with_self
    model = syncable_model("PolicyTask") do
      sync_merge :state, :server_wins
    end
    InstantRecord.sync(model)

    record = HLC.with_clock(-> { @t0 }) do
      on_server { model.create!(id: "t-seq", title: "v1", state: "open") }
    end

    # Same client node queues two offline edits from base_version: 1.
    r1 = apply_mutation({
      id: "seq-1", record_type: "PolicyTask", record_id: "t-seq", operation: "update",
      base_version: 1, hlc: HLC.from_time(@t0 + 2, node: "clientaa"),
      changes: { "state" => "in_progress" }
    }, at: @t0 + 4)
    r2 = apply_mutation({
      id: "seq-2", record_type: "PolicyTask", record_id: "t-seq", operation: "update",
      base_version: 1, hlc: HLC.from_time(@t0 + 3, node: "clientaa"),
      changes: { "state" => "done" }
    }, at: @t0 + 4)

    refute r1[:skipped]
    refute r2[:skipped]
    assert_equal "done", record.reload.state
  end

  def test_union_policy_merges_csv_strings_with_3_way_adds_and_deletions
    model = syncable_model("TaggedTask") do
      sync_merge :owner, :union
    end
    InstantRecord.sync(model)

    record = HLC.with_clock(-> { @t0 }) do
      on_server { model.create!(id: "t-csv", title: "tags", owner: "bug, triage") }
    end

    # Server removes "triage" and adds "urgent" -> v2 ("bug, urgent").
    HLC.with_clock(-> { @t0 + 2 }) do
      on_server { record.update!(owner: "bug, urgent") }
    end

    # Client (from v1: "bug, triage") adds "frontend" -> "bug, triage, frontend".
    res = apply_mutation({
      id: "m-csv", record_type: "TaggedTask", record_id: "t-csv", operation: "update",
      base_version: 1, hlc: HLC.from_time(@t0 + 1, node: "clientaa"),
      changes: { "owner" => "bug, triage, frontend" }
    }, at: @t0 + 3)

    assert res[:merged]
    assert_equal "bug, urgent, frontend", record.reload.owner
  end

  def test_union_policy_merges_json_array_strings
    model = syncable_model("JsonTask") do
      sync_merge :owner, :union
    end
    InstantRecord.sync(model)

    record = HLC.with_clock(-> { @t0 }) do
      on_server { model.create!(id: "t-json", title: "json tags", owner: '["a","b"]') }
    end

    HLC.with_clock(-> { @t0 + 2 }) do
      on_server { record.update!(owner: '["a","b","c"]') }
    end

    res = apply_mutation({
      id: "m-json", record_type: "JsonTask", record_id: "t-json", operation: "update",
      base_version: 1, hlc: HLC.from_time(@t0 + 1, node: "clientaa"),
      changes: { "owner" => '["a","b","d"]' }
    }, at: @t0 + 3)

    assert res[:merged]
    assert_equal %w[a b c d], JSON.parse(record.reload.owner)
  end

  def test_union_policy_merges_serialized_ruby_arrays_and_hashes
    array_model = syncable_model("ArrayTask") do
      serialize :owner, coder: JSON
      sync_merge :owner, :union
    end
    hash_model = syncable_model("HashTask") do
      serialize :owner, coder: JSON
      sync_merge :owner, :union
    end
    InstantRecord.sync(array_model, hash_model)

    # Serialized Array
    a_rec = HLC.with_clock(-> { @t0 }) do
      on_server { array_model.create!(id: "arr-1", title: "a", owner: ["x"]) }
    end
    HLC.with_clock(-> { @t0 + 1 }) { on_server { a_rec.update!(owner: %w[x y]) } }
    res_a = apply_mutation({
      id: "m-arr", record_type: "ArrayTask", record_id: "arr-1", operation: "update",
      base_version: 1, hlc: HLC.from_time(@t0 + 1, node: "clientaa"),
      changes: { "owner" => %w[x z] }
    }, at: @t0 + 2)
    assert res_a[:merged]
    assert_equal %w[x y z], a_rec.reload.owner

    # Serialized Hash
    h_rec = HLC.with_clock(-> { @t0 }) do
      on_server { hash_model.create!(id: "hash-1", title: "h", owner: { "a" => 1 }) }
    end
    HLC.with_clock(-> { @t0 + 1 }) { on_server { h_rec.update!(owner: { "a" => 1, "b" => 2 }) } }
    res_h = apply_mutation({
      id: "m-hash", record_type: "HashTask", record_id: "hash-1", operation: "update",
      base_version: 1, hlc: HLC.from_time(@t0 + 2, node: "clientaa"),
      changes: { "owner" => { "a" => 1, "c" => 3 } }
    }, at: @t0 + 2)
    assert res_h[:merged]
    assert_equal({ "a" => 1, "b" => 2, "c" => 3 }, h_rec.reload.owner)
  end

  def test_union_policy_falls_back_to_two_way_union_when_base_change_is_pruned
    model = syncable_model("PrunedTask") do
      sync_merge :owner, :union
    end
    InstantRecord.sync(model)

    record = HLC.with_clock(-> { @t0 }) do
      on_server { model.create!(id: "t-pruned", title: "p", owner: "alpha") }
    end
    HLC.with_clock(-> { @t0 + 1 }) { on_server { record.update!(owner: "alpha,beta") } }
    InstantRecord::Change.delete_all # simulate pruned change history

    res = apply_mutation({
      id: "m-pruned", record_type: "PrunedTask", record_id: "t-pruned", operation: "update",
      base_version: 1, hlc: HLC.from_time(@t0 + 1, node: "clientaa"),
      changes: { "owner" => "alpha,gamma" }
    }, at: @t0 + 2)

    assert res[:merged]
    assert_equal "alpha,beta,gamma", record.reload.owner
  end

  def test_sync_merge_validates_policy_and_inherits_to_subclasses
    assert_raises(ArgumentError) do
      syncable_model("BadPolicy") { sync_merge :title, :bogus }
    end

    parent = syncable_model("ParentTask") do
      sync_merge :state, :server_wins
      sync_merge :owner, :union
    end
    child = Class.new(parent) do
      sync_merge :state, :lww
    end

    assert_equal :server_wins, parent.instant_record_merge_policy(:state)
    assert_equal :union, parent.instant_record_merge_policy(:owner)
    assert_equal :lww, parent.instant_record_merge_policy(:title)

    assert_equal :lww, child.instant_record_merge_policy(:state)
    assert_equal :union, child.instant_record_merge_policy(:owner)
  end

  def test_unknown_column_is_still_rejected_on_merged_update
    model = syncable_model("Task")
    InstantRecord.sync(model)

    HLC.with_clock(-> { @t0 }) do
      on_server { model.create!(id: "t-skew", title: "v1", state: "open") }
    end
    HLC.with_clock(-> { @t0 + 1 }) do
      on_server { model.find("t-skew").update!(title: "v2") }
    end

    res = apply_mutation({
      id: "m-skew", record_type: "Task", record_id: "t-skew", operation: "update",
      base_version: 1, hlc: HLC.from_time(@t0 + 2, node: "clientaa"),
      changes: { "state" => "done", "future_col" => 42 }
    }, at: @t0 + 2)

    assert_equal "rejected", res[:status]
    assert_match(/future_col/, res[:reason])
  end

  def test_client_reconciles_authoritatively_when_server_returns_merged_result
    model = syncable_model("Task") do
      sync_merge :owner, :union
    end
    InstantRecord.sync(model)

    record = HLC.with_clock(-> { @t0 }) do
      on_server { model.create!(id: "t-e2e", title: "Draft", state: "open", owner: "a") }
    end
    # Simulate server receiving a concurrent edit to `title` and `owner` -> v2.
    HLC.with_clock(-> { @t0 + 5 }) do
      on_server { record.update!(title: "Server Title", owner: "a,b") }
    end

    # Simulate browser holding v1 locally in its own DB while editing `state` and `owner` offline.
    record.update_columns(title: "Draft", state: "open", owner: "a", server_version: 1)
    in_browser do
      HLC.with_clock(-> { @t0 + 3 }) do
        record.update!(state: "done", owner: "a,c")
      end
    end

    mutation = InstantRecord::OutboxMutation.sole.as_mutation
    assert_equal 1, mutation[:base_version]

    # Restore the server's v2 row before applying the mutation (server and browser have separate DBs).
    record.update_columns(title: "Server Title", state: "open", owner: "a,b", server_version: 2)

    # Server applies mutation -> 3-way merge produces v3.
    server_result = apply_mutation(mutation, at: @t0 + 6)
    assert server_result[:merged]
    assert_equal 3, server_result[:version]

    # Restore browser's optimistic pre-ack row, then apply the server result.
    record.update_columns(title: "Draft", state: "done", owner: "a,c", server_version: 1, sync_state: "pending")
    in_browser do
      InstantRecord::Client.apply_results([server_result])
    end

    record.reload
    assert_equal "Server Title", record.title
    assert_equal "done", record.state
    assert_equal "a,b,c", record.owner
    assert_equal 3, record.server_version
    assert_equal "synced", record.sync_state
    assert_equal server_result[:hlc], HLC.row_hlc("Task", "t-e2e")
    assert_equal 0, InstantRecord::OutboxMutation.count
  end
end
