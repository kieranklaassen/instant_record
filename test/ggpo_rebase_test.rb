require "test_helper"

class GgpoRebaseTest < Minitest::Test
  def setup
    @model = syncable_model("Note")
    InstantRecord.sync(@model)
    reset_instant_record_tables!
  end

  def teardown
    InstantRecord.sync
  end

  def seed_synced_row(id:, title: "server title", state: "open", owner: "alice", version: 1, updated_at: Time.utc(2026, 11, 21, 12, 0, 0))
    in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => id, "operation" => "create", "version" => version,
        "attributes" => {
          "id" => id, "title" => title, "state" => state, "owner" => owner,
          "created_at" => updated_at.iso8601(6), "updated_at" => updated_at.iso8601(6)
        }
      )
    end
    @model.find(id)
  end

  def test_confirmed_snapshots_exist_strictly_for_dirty_rows
    note = seed_synced_row(id: "clean-1")
    assert_equal 0, InstantRecord::Client::Rebaser.confirmed_snapshot_count,
      "clean rows must carry zero confirmed snapshots"

    in_browser { note.update!(title: "dirty edit 1") }
    assert_equal 1, InstantRecord::Client::Rebaser.confirmed_snapshot_count
    snapshot = InstantRecord::Client::Rebaser.confirmed_snapshot("Note", "clean-1")
    assert_equal true, snapshot["exists"]
    assert_equal 1, snapshot["version"]
    assert_equal "server title", snapshot["attributes"]["title"]

    # A second edit on the same dirty row must NOT overwrite the confirmed baseline.
    in_browser { note.update!(state: "closed") }
    assert_equal 1, InstantRecord::Client::Rebaser.confirmed_snapshot_count
    snapshot = InstantRecord::Client::Rebaser.confirmed_snapshot("Note", "clean-1")
    assert_equal "server title", snapshot["attributes"]["title"]
    assert_equal "open", snapshot["attributes"]["state"]

    # Acking the first mutation advances the confirmed snapshot while keeping row dirty.
    m1, m2 = InstantRecord::OutboxMutation.ordered.to_a
    in_browser do
      InstantRecord::Client.apply_results([{ "mutation_id" => m1.id, "status" => "applied", "version" => 2 }])
    end

    assert_equal 1, InstantRecord::Client::Rebaser.confirmed_snapshot_count
    note.reload
    assert_equal "pending", note.sync_state, "row still has unacked m2, must stay pending"
    assert_equal 2, note.server_version
    assert_equal "dirty edit 1", note.title
    assert_equal "closed", note.state

    # Acking the last mutation deletes the confirmed snapshot and marks row synced.
    in_browser do
      InstantRecord::Client.apply_results([{ "mutation_id" => m2.id, "status" => "applied", "version" => 3 }])
    end

    assert_equal 0, InstantRecord::Client::Rebaser.confirmed_snapshot_count,
      "confirmed snapshot must be deleted as soon as the row becomes clean"
    note.reload
    assert_equal "synced", note.sync_state
    assert_equal 3, note.server_version
    assert_equal "dirty edit 1", note.title
    assert_equal "closed", note.state
  end

  def test_rolled_back_local_transaction_rolls_back_confirmed_snapshot
    seed_synced_row(id: "tx-1")
    assert_equal 0, InstantRecord::Client::Rebaser.confirmed_snapshot_count

    in_browser do
      assert_raises(RuntimeError) do
        ActiveRecord::Base.transaction do
          @model.find("tx-1").update!(title: "rolled back")
          raise "abort"
        end
      end
    end

    assert_equal 0, InstantRecord::OutboxMutation.count
    assert_equal 0, InstantRecord::Client::Rebaser.confirmed_snapshot_count
  end

  def test_ack_with_a_clamped_hlc_lets_a_later_server_change_through
    note = seed_synced_row(id: "fast-1")
    now = Time.utc(2026, 11, 21, 12, 5, 0)

    in_browser do
      InstantRecord::HLC.with_clock(-> { now + 120 }) { note.update!(state: "closed") }
      mutation = InstantRecord::OutboxMutation.sole
      clamped = InstantRecord::HLC.clamp(mutation.hlc, now: now)
      assert_operator clamped, :<, mutation.hlc

      InstantRecord::Client.apply_results([
        { "mutation_id" => mutation.id, "status" => "applied", "version" => 2, "hlc" => clamped }
      ])
      assert_equal clamped, InstantRecord::HLC.row_hlc("Note", "fast-1")

      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => "fast-1", "operation" => "update", "version" => 3,
        "hlc" => InstantRecord::HLC.from_time(now + 1, node: InstantRecord::HLC::SERVER_NODE),
        "attributes" => note.attributes.merge("state" => "open", "updated_at" => (now + 1).iso8601(6))
      )
    end

    assert_equal "open", note.reload.state
    assert_equal 3, note.server_version
  end

  # The clamp must not undo a newer server change that arrived before the ack.
  def test_ack_keeps_the_row_hlc_of_a_newer_server_change
    note = seed_synced_row(id: "late-ack-1")
    now = Time.utc(2026, 11, 21, 12, 5, 0)

    in_browser do
      InstantRecord::HLC.with_clock(-> { now }) { note.update!(state: "closed") }
      mutation = InstantRecord::OutboxMutation.sole
      newer = InstantRecord::HLC.from_time(now + 1, node: InstantRecord::HLC::SERVER_NODE)
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => "late-ack-1", "operation" => "update", "version" => 3, "hlc" => newer,
        "attributes" => note.attributes.merge("state" => "open", "updated_at" => (now + 1).iso8601(6))
      )
      InstantRecord::Client.apply_results([
        { "mutation_id" => mutation.id, "status" => "applied", "version" => 2, "hlc" => mutation.hlc }
      ])

      assert_equal newer, InstantRecord::HLC.row_hlc("Note", "late-ack-1")
    end
  end

  def test_clamped_ack_keeps_the_hlc_of_a_newer_server_change_against_an_older_page
    note = seed_synced_row(id: "fast-2")
    now = Time.utc(2026, 11, 21, 12, 5, 0)

    in_browser do
      InstantRecord::HLC.with_clock(-> { now + 120 }) { note.update!(state: "closed") }
      mutation = InstantRecord::OutboxMutation.sole
      newer = InstantRecord::HLC.from_time(now + 2, node: InstantRecord::HLC::SERVER_NODE)
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => "fast-2", "operation" => "update", "version" => 4, "hlc" => newer,
        "attributes" => note.attributes.merge("state" => "open", "title" => "new", "updated_at" => (now + 2).iso8601(6))
      )
      InstantRecord::Client.apply_results([
        { "mutation_id" => mutation.id, "status" => "applied", "version" => 2,
          "hlc" => InstantRecord::HLC.clamp(mutation.hlc, now: now) }
      ])
      assert_equal newer, InstantRecord::HLC.row_hlc("Note", "fast-2")

      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => "fast-2", "operation" => "update", "version" => 3,
        "hlc" => InstantRecord::HLC.from_time(now + 1, node: InstantRecord::HLC::SERVER_NODE),
        "attributes" => note.attributes.merge("title" => "middle", "updated_at" => (now + 1).iso8601(6))
      )
    end

    assert_equal "new", note.reload.title
    assert_equal "closed", note.state
  end

  # A row an earlier ack left with this client's future clock hands it to the
  # snapshot of the next write. That clock never came from the server.
  def test_clamped_ack_ignores_this_clients_own_future_hlc_in_the_snapshot
    note = seed_synced_row(id: "fast-3")
    now = Time.utc(2026, 11, 21, 12, 5, 0)

    in_browser do
      future = InstantRecord::HLC.from_time(now + 120, node: InstantRecord::HLC.node_id)
      InstantRecord::HLC.set_row_hlc("Note", "fast-3", future)
      InstantRecord::HLC.with_clock(-> { now + 60 }) { note.update!(state: "closed") }
      assert_equal future, InstantRecord::Client::Rebaser.confirmed_snapshot("Note", "fast-3")["hlc"]
      mutation = InstantRecord::OutboxMutation.sole
      clamped = InstantRecord::HLC.clamp(mutation.hlc, now: now)
      InstantRecord::Client.apply_results([
        { "mutation_id" => mutation.id, "status" => "applied", "version" => 2, "hlc" => clamped }
      ])

      assert_equal clamped, InstantRecord::HLC.row_hlc("Note", "fast-3")
    end
  end

  def test_clamped_acks_of_queued_writes_leave_the_last_clamped_hlc
    note = seed_synced_row(id: "fast-4")
    now = Time.utc(2026, 11, 21, 12, 5, 0)

    in_browser do
      InstantRecord::HLC.with_clock(-> { now + 120 }) do
        note.update!(state: "closed")
        note.update!(title: "second")
      end
      clamps = InstantRecord::OutboxMutation.ordered.to_a.map do |mutation|
        clamped = InstantRecord::HLC.clamp(mutation.hlc, now: now)
        InstantRecord::Client.apply_results([
          { "mutation_id" => mutation.id, "status" => "applied", "version" => 2, "hlc" => clamped }
        ])
        clamped
      end

      assert_equal clamps.last, InstantRecord::HLC.row_hlc("Note", "fast-4")
    end
  end

  def test_skipped_ack_rebases_remaining_unacked_local_edit_instead_of_clobbering
    t0 = Time.utc(2026, 11, 21, 12, 0, 0)
    note = seed_synced_row(id: "rebase-1", title: "v0", state: "open", version: 1, updated_at: t0)

    # M1 edits title (will lose LWW on server); M2 edits state while M1 is in flight.
    in_browser do
      note.update!(title: "my losing title", updated_at: t0 + 1)
      note.update!(state: "closed", updated_at: t0 + 2)
    end

    m1, m2 = InstantRecord::OutboxMutation.ordered.to_a

    # Server skipped M1 because a peer won `title` with a newer timestamp.
    in_browser do
      InstantRecord::Client.apply_results([{
        "mutation_id" => m1.id,
        "status" => "applied",
        "skipped" => true,
        "version" => 2,
        "server_attributes" => {
          "id" => "rebase-1",
          "title" => "peer winning title",
          "state" => "open",
          "owner" => "alice",
          "updated_at" => (t0 + 5).iso8601(6)
        }
      }])
    end

    note.reload
    assert_equal "peer winning title", note.title, "server truth on title must apply"
    assert_equal "closed", note.state, "unacked local edit M2 on state must be rebased, not overwritten"
    assert_equal "pending", note.sync_state
    assert_equal 2, note.server_version
    assert_equal [m2.id], InstantRecord::OutboxMutation.pluck(:id)
    assert_equal 1, InstantRecord::Client::Rebaser.confirmed_snapshot_count
  end

  def test_rejected_ack_rolls_back_rejected_edit_and_replays_remaining_unacked_edit
    t0 = Time.utc(2026, 11, 21, 12, 0, 0)
    note = seed_synced_row(id: "rej-1", title: "v0", state: "open", version: 1, updated_at: t0)

    in_browser do
      note.update!(title: "forbidden title", updated_at: t0 + 1)
      note.update!(state: "closed", updated_at: t0 + 2)
    end

    m1, m2 = InstantRecord::OutboxMutation.ordered.to_a

    in_browser do
      InstantRecord::Client.apply_results([{
        "mutation_id" => m1.id,
        "status" => "rejected",
        "reason" => "title not allowed",
        "version" => 1,
        "server_attributes" => {
          "id" => "rej-1",
          "title" => "v0",
          "state" => "open",
          "owner" => "alice",
          "updated_at" => t0.iso8601(6)
        }
      }])
    end

    note.reload
    assert_equal "v0", note.title, "rejected edit must roll back to server state"
    assert_equal "closed", note.state, "newer unacked edit M2 must replay cleanly"
    assert_equal "pending", note.sync_state
    assert_equal [m2.id], InstantRecord::OutboxMutation.pluck(:id)
  end

  def test_incoming_server_delta_rewinds_dirty_row_and_replays_disjoint_local_edit
    t0 = Time.utc(2026, 11, 21, 12, 0, 0)
    note = seed_synced_row(id: "delta-1", title: "v0", state: "open", owner: "alice", version: 1, updated_at: t0)

    in_browser { note.update!(state: "closed", updated_at: t0 + 1) }

    # Server updates `title` with a strictly newer timestamp while keeping `state: "open"`.
    applied = in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => "delta-1", "operation" => "update", "version" => 2,
        "attributes" => {
          "id" => "delta-1", "title" => "server renamed", "state" => "open", "owner" => "alice",
          "updated_at" => (t0 + 10).iso8601(6)
        }
      )
    end

    assert applied
    note.reload
    assert_equal "server renamed", note.title
    assert_equal "closed", note.state
    assert_equal 2, note.server_version
    assert_equal "pending", note.sync_state
  end

  def test_multiple_server_deltas_do_not_resurrect_superseded_local_column_edit
    t0 = Time.utc(2026, 11, 21, 12, 0, 0)
    note = seed_synced_row(id: "multi-1", title: "v0", state: "open", owner: "alice", version: 1, updated_at: t0)

    in_browser { note.update!(state: "closed", updated_at: t0 + 1) }

    # Delta 1 changes title only -> local state="closed" survives.
    in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => "multi-1", "operation" => "update", "version" => 2,
        "attributes" => { "id" => "multi-1", "title" => "v1", "state" => "open", "owner" => "alice", "updated_at" => (t0 + 5).iso8601(6) }
      )
    end
    assert_equal "closed", note.reload.state

    # Delta 2 changes state to "archived" at a newer timestamp -> server wins on state.
    in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => "multi-1", "operation" => "update", "version" => 3,
        "attributes" => { "id" => "multi-1", "title" => "v1", "state" => "archived", "owner" => "alice", "updated_at" => (t0 + 10).iso8601(6) }
      )
    end
    assert_equal "archived", note.reload.state

    # Delta 3 changes title again while keeping state="archived" -> must NOT resurrect "closed".
    in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => "multi-1", "operation" => "update", "version" => 4,
        "attributes" => { "id" => "multi-1", "title" => "v2", "state" => "archived", "owner" => "alice", "updated_at" => (t0 + 15).iso8601(6) }
      )
    end
    note.reload
    assert_equal "v2", note.title
    assert_equal "archived", note.state
  end

  def test_acking_first_mutation_does_not_resurrect_superseded_second_mutation_on_another_column
    t0 = Time.utc(2026, 11, 21, 12, 0, 0)
    note = seed_synced_row(id: "ack-preserves-1", title: "v0", state: "open", version: 1, updated_at: t0)

    in_browser do
      note.update!(title: "local title", updated_at: t0 + 1)
      note.update!(state: "local state", updated_at: t0 + 2)
    end
    m1, _m2 = InstantRecord::OutboxMutation.ordered.to_a

    # Before M1 acks, a strictly newer server delta changes `state` to "server state".
    in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => "ack-preserves-1", "operation" => "update", "version" => 2,
        "attributes" => {
          "id" => "ack-preserves-1", "title" => "v0", "state" => "server state", "owner" => "alice",
          "updated_at" => (t0 + 10).iso8601(6)
        }
      )
    end
    assert_equal "server state", note.reload.state

    # Now M1 (title) is acked; confirmed updated_at and server's newer `state` must NOT be lost.
    in_browser do
      InstantRecord::Client.apply_results([{ "mutation_id" => m1.id, "status" => "applied", "version" => 3 }])
    end

    note.reload
    assert_equal "local title", note.title
    assert_equal "server state", note.state, "newer server state must not be overwritten by older unacked M2"
    assert_equal "pending", note.sync_state
  end

  def test_custom_deterministic_mutator_replays_over_incoming_server_truth
    # Model whose `title` holds a comma-separated tag list and `owner` is a server field.
    # Custom mutator deterministically appends each local tag delta onto server truth.
    tagged = syncable_model("Note") do
      on_replay_mutation do |record, mutation|
        if mutation.operation == "update" && mutation.changes_payload.key?("title")
          added_tag = mutation.changes_payload["title"].to_s.split(",").last
          existing_tags = record.title.to_s.split(",").reject(&:empty?)
          existing_tags << added_tag unless existing_tags.include?(added_tag)
          record.title = existing_tags.join(",")
          true
        else
          :default
        end
      end
    end
    InstantRecord.sync(tagged)

    t0 = Time.utc(2026, 11, 21, 12, 0, 0)
    in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => "tags-1", "operation" => "create", "version" => 1,
        "attributes" => { "id" => "tags-1", "title" => "a", "state" => "open", "updated_at" => t0.iso8601(6) }
      )
    end

    note = tagged.find("tags-1")
    in_browser do
      note.update!(title: "a,local1", updated_at: t0 + 1)
      note.update!(title: "a,local1,local2", updated_at: t0 + 2)
    end

    # Server added "remote" concurrently.
    in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => "tags-1", "operation" => "update", "version" => 2,
        "attributes" => { "id" => "tags-1", "title" => "a,remote", "state" => "open", "updated_at" => (t0 + 10).iso8601(6) }
      )
    end

    assert_equal "a,remote,local1,local2", note.reload.title
    assert_equal "pending", note.sync_state
  end

  def test_rejected_local_destroy_restores_row_from_server_state
    t0 = Time.utc(2026, 11, 21, 12, 0, 0)
    note = seed_synced_row(id: "del-1", title: "keep me", version: 2, updated_at: t0)

    in_browser { note.destroy! }
    refute @model.exists?("del-1")
    assert_equal 1, InstantRecord::Client::Rebaser.confirmed_snapshot_count

    mutation_id = InstantRecord::OutboxMutation.sole.id
    in_browser do
      InstantRecord::Client.apply_results([{
        "mutation_id" => mutation_id, "status" => "rejected", "reason" => "not permitted",
        "version" => 2,
        "server_attributes" => { "id" => "del-1", "title" => "keep me", "state" => "open", "updated_at" => t0.iso8601(6) }
      }])
    end

    restored = @model.find("del-1")
    assert_equal "keep me", restored.title
    assert_equal "synced", restored.sync_state
    assert_equal 0, InstantRecord::Client::Rebaser.confirmed_snapshot_count
  end

  def test_rapid_interleaved_edits_acks_and_server_deltas_converge_deterministically
    t0 = Time.utc(2026, 11, 21, 12, 0, 0)
    note = seed_synced_row(id: "rapid-1", title: "start", state: "open", owner: "alice", version: 1, updated_at: t0)

    # Queue 10 rapid local edits alternating title & state while server concurrently updates owner.
    in_browser do
      5.times do |i|
        note.reload.update!(title: "title-#{i}", updated_at: t0 + (i * 2) + 1)
        note.reload.update!(state: "state-#{i}", updated_at: t0 + (i * 2) + 2)
      end
    end

    mutations = InstantRecord::OutboxMutation.ordered.to_a
    assert_equal 10, mutations.size
    assert_equal 1, InstantRecord::Client::Rebaser.confirmed_snapshot_count

    # Interleave: ack first 3, deliver concurrent server owner update, reject 4th, ack rest.
    in_browser do
      InstantRecord::Client.apply_results(
        mutations[0, 3].each_with_index.map { |m, idx| { "mutation_id" => m.id, "status" => "applied", "version" => idx + 2 } }
      )
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => "rapid-1", "operation" => "update", "version" => 5,
        "attributes" => {
          "id" => "rapid-1", "title" => "title-1", "state" => "state-0", "owner" => "bob",
          "updated_at" => (t0 + 20).iso8601(6)
        }
      )
      InstantRecord::Client.apply_results([
        {
          "mutation_id" => mutations[3].id, "status" => "rejected", "reason" => "stale",
          "version" => 5,
          "server_attributes" => {
            "id" => "rapid-1", "title" => "title-1", "state" => "state-0", "owner" => "bob",
            "updated_at" => (t0 + 20).iso8601(6)
          }
        }
      ])
    end

    note.reload
    assert_equal "bob", note.owner, "concurrent server owner edit must survive"
    assert_equal "title-4", note.title, "latest unacked title edit must survive"
    assert_equal "state-4", note.state, "latest unacked state edit must survive"
    assert_equal "pending", note.sync_state
    assert_equal 6, InstantRecord::OutboxMutation.count

    # Drain remaining 6 mutations.
    in_browser do
      InstantRecord::Client.apply_results(
        mutations[4..].each_with_index.map { |m, idx| { "mutation_id" => m.id, "status" => "applied", "version" => idx + 6 } }
      )
    end

    note.reload
    assert_equal "bob", note.owner
    assert_equal "title-4", note.title
    assert_equal "state-4", note.state
    assert_equal "synced", note.sync_state
    assert_equal 11, note.server_version
    assert_equal 0, InstantRecord::OutboxMutation.count
    assert_equal 0, InstantRecord::Client::Rebaser.confirmed_snapshot_count
  end

  def test_reset_clears_confirmed_snapshots_only_for_reset_types
    ActiveRecord::Schema.define do
      create_table :other_notes, id: :string, force: true do |t|
        t.string :title
        t.integer :server_version, null: false, default: 0
        t.string :sync_state, null: false, default: "synced"
        t.timestamps
      end
    end
    other = syncable_model("OtherNote") { self.table_name = "other_notes" }
    InstantRecord.sync(@model, other)

    in_browser do
      @model.create!(id: "secret-1", title: "scoped")
      other.create!(id: "public-1", title: "shared")
    end
    assert_equal 2, InstantRecord::Client::Rebaser.confirmed_snapshot_count

    in_browser { InstantRecord::Client.reset("types" => ["Note"]) }

    assert_equal 1, InstantRecord::Client::Rebaser.confirmed_snapshot_count
    assert_nil InstantRecord::Client::Rebaser.confirmed_snapshot("Note", "secret-1")
    assert InstantRecord::Client::Rebaser.confirmed_snapshot("OtherNote", "public-1")
  end
end
