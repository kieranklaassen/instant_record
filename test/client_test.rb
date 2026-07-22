require "test_helper"

class ClientTest < Minitest::Test
  def setup
    @model = syncable_model("Note")
    InstantRecord.sync(@model)
    reset_instant_record_tables!
  end

  def teardown
    InstantRecord.sync
  end

  def test_pending_mutations_are_ordered_and_complete
    note = in_browser do
      @model.create!(title: "one").tap { |n| n.update!(title: "two") }
    end

    mutations = InstantRecord::Client.pending_mutations
    assert_equal %w[create update], mutations.map { |m| m[:operation] }
    assert_equal note.id, mutations.first[:record_id]
    assert_equal 2, InstantRecord.pending_count
  end

  def test_applied_result_clears_outbox_and_marks_record_synced
    note = in_browser { @model.create!(title: "one") }
    mutation_id = InstantRecord::OutboxMutation.sole.id

    in_browser do
      InstantRecord::Client.apply_results([{ "mutation_id" => mutation_id, "status" => "applied", "version" => 1 }])
    end

    assert_equal 0, InstantRecord.pending_count
    note.reload
    assert_equal "synced", note.sync_state
    assert_equal 1, note.server_version
  end

  def test_rejected_update_reconciles_to_server_attributes
    note = in_browser { @model.create!(title: "server title") }
    InstantRecord::OutboxMutation.delete_all
    in_browser { note.update!(title: "local rejected title") }
    mutation_id = InstantRecord::OutboxMutation.sole.id

    in_browser do
      InstantRecord::Client.apply_results([{
        mutation_id: mutation_id, status: "rejected", reason: "not allowed",
        server_attributes: { "id" => note.id, "title" => "server title", "updated_at" => (Time.current + 3600).iso8601 },
        version: 5
      }])
    end

    note.reload
    assert_equal "server title", note.title
    assert_equal "synced", note.sync_state
    assert_equal 5, note.server_version
    assert_equal 0, InstantRecord.pending_count
  end

  def test_rejected_create_removes_local_record
    note = in_browser { @model.create!(title: "never accepted") }
    mutation_id = InstantRecord::OutboxMutation.sole.id

    in_browser do
      InstantRecord::Client.apply_results([{ "mutation_id" => mutation_id, "status" => "rejected", "reason" => "nope" }])
    end

    refute @model.exists?(note.id)
    assert_equal 0, InstantRecord.pending_count
  end

  def test_rejection_with_pending_later_mutation_keeps_it_queued
    note = in_browser do
      @model.create!(title: "one").tap { |n| n.update!(title: "two") }
    end
    create_mutation_id = InstantRecord::OutboxMutation.ordered.first.id

    in_browser do
      InstantRecord::Client.apply_results([{
        "mutation_id" => create_mutation_id, "status" => "rejected", "reason" => "nope",
        "server_attributes" => { "id" => note.id, "title" => "server", "updated_at" => Time.current.iso8601 }
      }])
    end

    assert_equal 1, InstantRecord.pending_count
    assert_equal "update", InstantRecord::OutboxMutation.sole.operation
  end

  def test_apply_change_upserts_without_enqueueing
    in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => "abc-123", "operation" => "create", "version" => 1,
        "attributes" => { "id" => "abc-123", "title" => "from server", "updated_at" => Time.current.iso8601 }
      )
    end

    note = @model.find("abc-123")
    assert_equal "from server", note.title
    assert_equal "synced", note.sync_state
    assert_equal 0, InstantRecord.pending_count, "applying remote changes must not enqueue mutations"
  end

  def test_apply_change_respects_local_newer_write
    note = in_browser { @model.create!(title: "local newer") }

    in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => note.id, "operation" => "update", "version" => 2,
        "attributes" => { "id" => note.id, "title" => "stale remote", "updated_at" => (note.updated_at - 3600).iso8601 }
      )
    end

    assert_equal "local newer", note.reload.title
  end

  def test_apply_change_destroy_removes_record
    note = in_browser { @model.create!(title: "goner") }
    InstantRecord::OutboxMutation.delete_all

    in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => note.id, "operation" => "destroy", "version" => 0, "attributes" => {}
      )
    end

    refute @model.exists?(note.id)
    assert_equal 0, InstantRecord.pending_count
  end

  def test_cursor_persists
    InstantRecord::Client.cursor = 99
    assert_equal 99, InstantRecord.cursor
  end
end
