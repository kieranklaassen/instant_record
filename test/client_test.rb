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

  # The server's row is OLDER than the optimistic local row, because a rejected
  # update is precisely one the server never applied. That is the ordinary case,
  # and it used to defeat this reconciliation: last-write-wins dropped the
  # server's older row, the outbox mutation was destroyed anyway, and the record
  # kept the refused value at `pending` forever. Only a server stamp fabricated
  # into the future made it look like it worked.
  def test_rejected_update_reconciles_to_server_attributes
    note = in_browser { @model.create!(title: "server title") }
    server_stamp = note.updated_at
    InstantRecord::OutboxMutation.delete_all
    in_browser { note.update!(title: "local rejected title") }
    mutation_id = InstantRecord::OutboxMutation.sole.id

    assert_operator server_stamp, :<, note.reload.updated_at,
      "the server's row has to be older than the local write it refused for this to test anything"

    in_browser do
      InstantRecord::Client.apply_results([{
        mutation_id: mutation_id, status: "rejected", reason: "not allowed",
        server_attributes: { "id" => note.id, "title" => "server title", "updated_at" => server_stamp.iso8601(6) },
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

  # A skipped result is the server saying last-write-wins threw the write away.
  # It is resolved — nothing retries it — but it did not land, and reporting it
  # as synced put a green badge on a value the server never accepted.
  def test_a_skipped_write_is_reconciled_to_the_value_that_won_not_marked_synced
    note = in_browser { @model.create!(title: "my line") }
    InstantRecord::OutboxMutation.delete_all
    in_browser { note.update!(title: "my losing line") }
    mutation_id = InstantRecord::OutboxMutation.sole.id

    in_browser do
      InstantRecord::Client.apply_results([{
        "mutation_id" => mutation_id, "status" => "applied", "version" => 7, "skipped" => true,
        "server_attributes" => { "id" => note.id, "title" => "the line that won",
                                 "updated_at" => (note.updated_at + 1).utc.iso8601(6) }
      }])
    end

    note.reload
    assert_equal "the line that won", note.title,
      "a row cannot be synced against a value the server threw away"
    assert_equal 7, note.server_version
    assert_equal 0, InstantRecord.pending_count, "a skipped write is resolved, never retried"
  end

  # Schema skew, client behind the server: the change carries a column this
  # runtime has not migrated yet. Assigning it raised, which killed the whole
  # apply; the columns this client does have still have to converge.
  def test_a_change_carrying_an_unmigrated_column_applies_the_rest
    in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => "behind-1", "operation" => "create", "version" => 3,
        "attributes" => { "id" => "behind-1", "title" => "from a newer server",
                          "word_count" => 4, "updated_at" => Time.now.utc.iso8601(6) }
      )
    end

    note = @model.find("behind-1")
    assert_equal "from a newer server", note.title
    assert_equal 3, note.server_version
  end

  # The tie-break, stated on purpose rather than falling out of rounding: a
  # remote value has to be strictly newer to replace a local one. Ties are
  # settled once, on the server, which accepts an equal-stamped client mutation.
  def test_an_equal_stamped_remote_value_leaves_the_local_row_alone
    note = in_browser { @model.create!(title: "mine") }

    applied = in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => note.id, "operation" => "update", "version" => 5,
        "attributes" => { "id" => note.id, "title" => "theirs",
                          "updated_at" => note.updated_at.utc.iso8601(6) }
      )
    end

    refute applied
    assert_equal "mine", note.reload.title
  end

  # Our own write comes back down the stream with the stamp we sent. Nothing
  # about the row moved, so it must not be re-saved — a save announces a change
  # to every tab and fires the host app's after_save callbacks. This used to hold
  # only by accident: the change log rounded the stamp down, which made every
  # echo look older than the row it came from. Here the ack has not arrived yet,
  # so the echo differs in the gem's own bookkeeping columns and the accident
  # would no longer cover it.
  def test_an_echo_of_our_own_write_is_dropped_even_before_the_ack_lands
    note = in_browser { @model.create!(title: "my own write") }
    assert_equal "pending", note.sync_state

    applied = in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => note.id, "operation" => "create", "version" => 1,
        "attributes" => InstantRecord.wire_attributes(note.attributes)
      )
    end

    refute applied, "re-applying our own row would announce a change that never happened"
  end

  # The losing side of a last-write-wins comparison is assigned nowhere and
  # callbacks never see it, so a model that wants to keep it needs a seam.
  def test_a_discarded_remote_value_reaches_the_model_that_asked_for_it
    discarded = []
    model = syncable_model("Note") { on_discarded_change { |attributes| discarded << attributes } }
    InstantRecord.sync(model)
    note = in_browser { model.create!(title: "local newer") }

    in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => note.id, "operation" => "update", "version" => 2,
        "attributes" => { "id" => note.id, "title" => "stale remote",
                          "updated_at" => (note.updated_at - 3600).utc.iso8601(6) }
      )
    end

    assert_equal ["stale remote"], discarded.map { |attributes| attributes["title"] }
    assert_equal "local newer", note.reload.title
  end

  def test_the_echo_of_our_own_write_is_not_reported_as_a_discarded_value
    discarded = []
    model = syncable_model("Note") { on_discarded_change { |attributes| discarded << attributes } }
    InstantRecord.sync(model)
    note = in_browser { model.create!(title: "mine") }

    in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => note.id, "operation" => "create", "version" => 1,
        "attributes" => InstantRecord.wire_attributes(note.attributes)
      )
    end

    assert_empty discarded, "our own row is not a value the server lost"
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
