require "test_helper"

class SyncableTest < Minitest::Test
  def setup
    @model = syncable_model("Todo")
    reset_instant_record_tables!
  end

  def test_create_assigns_uuid_and_records_outbox_mutation_atomically
    todo = in_browser { @model.create!(title: "hello") }

    assert_match(/\A[0-9a-f-]{36}\z/, todo.id)
    assert_equal "pending", todo.sync_state

    mutation = InstantRecord::OutboxMutation.sole
    assert_equal "create", mutation.operation
    assert_equal "Todo", mutation.record_type
    assert_equal todo.id, mutation.record_id
    assert_equal "hello", mutation.changes_payload["title"]
  end

  def test_update_records_changed_attributes_and_base_version
    in_browser do
      todo = @model.create!(title: "hello")
      todo.update_column(:server_version, 3)
      InstantRecord::OutboxMutation.delete_all

      todo.update!(title: "world")
    end

    mutation = InstantRecord::OutboxMutation.sole
    assert_equal "update", mutation.operation
    assert_equal 3, mutation.base_version
    assert_equal "world", mutation.changes_payload["title"]
    refute_includes mutation.changes_payload.keys, "sync_state"
  end

  def test_destroy_records_destroy_mutation
    in_browser do
      todo = @model.create!(title: "hello")
      InstantRecord::OutboxMutation.delete_all

      todo.destroy!

      mutation = InstantRecord::OutboxMutation.sole
      assert_equal "destroy", mutation.operation
      assert_equal todo.id, mutation.record_id
    end
  end

  def test_rolled_back_transaction_leaves_no_record_and_no_mutation
    in_browser do
      assert_raises(RuntimeError) do
        ActiveRecord::Base.transaction do
          @model.create!(title: "doomed")
          raise "boom"
        end
      end
    end

    assert_equal 0, @model.count
    assert_equal 0, InstantRecord::OutboxMutation.count
  end

  def test_two_writes_produce_two_ordered_mutations
    in_browser do
      todo = @model.create!(title: "first")
      todo.update!(title: "second")
    end

    operations = InstantRecord::OutboxMutation.ordered.pluck(:operation)
    assert_equal %w[create update], operations
  end

  def test_server_runtime_records_no_outbox_mutations
    on_server { @model.create!(title: "server side") }

    assert_equal 0, InstantRecord::OutboxMutation.count
    assert_equal "synced", @model.sole.sync_state
  end

  def test_server_create_logs_change_with_version_one
    todo = on_server { @model.create!(title: "from server") }

    assert_equal 1, todo.server_version
    change = InstantRecord::Change.sole
    assert_equal "create", change.operation
    assert_equal "Todo", change.record_type
    assert_equal todo.id, change.record_id
    assert_equal 1, change.version
    assert_equal "from server", change.attributes_payload["title"]
    refute_includes change.attributes_payload.keys, "sync_state"
  end

  def test_server_update_bumps_version_and_logs_change
    todo = on_server { @model.create!(title: "v1") }
    InstantRecord::Change.delete_all

    on_server { todo.update!(title: "v2") }

    assert_equal 2, todo.server_version
    change = InstantRecord::Change.sole
    assert_equal "update", change.operation
    assert_equal 2, change.version
    assert_equal "v2", change.attributes_payload["title"]
  end

  def test_server_destroy_logs_destroy_change
    todo = on_server { @model.create!(title: "doomed") }
    InstantRecord::Change.delete_all

    on_server { todo.destroy! }

    change = InstantRecord::Change.sole
    assert_equal "destroy", change.operation
    assert_equal todo.id, change.record_id
    assert_equal({}, change.attributes_payload)
  end

  def test_browser_writes_log_no_changes
    in_browser { @model.create!(title: "local only") }

    assert_equal 0, InstantRecord::Change.count
  end

  def test_duplicate_id_create_mutation_is_rejected_not_retried_forever
    InstantRecord.sync(@model)
    existing = on_server { @model.create!(title: "already here") }

    result = on_server do
      InstantRecord::MutationApplier.apply(
        id: SecureRandom.uuid,
        record_type: "Todo",
        record_id: existing.id,
        operation: "create",
        changes: { "title" => "replayed duplicate" }
      )
    end

    assert_equal "rejected", result[:status]
    assert_equal "id already exists", result[:reason]
    assert_equal "already here", result[:server_attributes]["title"]
  ensure
    InstantRecord.sync
  end

  def test_applying_client_mutation_logs_exactly_one_change
    InstantRecord.sync(@model)
    result = on_server do
      InstantRecord::MutationApplier.apply(
        id: SecureRandom.uuid,
        record_type: "Todo",
        record_id: SecureRandom.uuid,
        operation: "create",
        changes: { "title" => "from client" }
      )
    end

    assert_equal "applied", result[:status]
    assert_equal 1, InstantRecord::Change.count
    assert_equal 1, @model.sole.server_version
  ensure
    InstantRecord.sync
  end

  def test_server_only_block_is_skipped_in_browser_runtime
    model = in_browser do
      syncable_model("Todo") do
        server_only { validates :title, exclusion: { in: ["reject me"] } }
      end
    end

    assert in_browser { model.new(title: "reject me").valid? }
  end

  def test_server_only_block_applies_in_server_runtime
    model = on_server do
      syncable_model("Todo") do
        server_only { validates :title, exclusion: { in: ["reject me"] } }
      end
    end

    refute model.new(title: "reject me").valid?
  end

  def test_browser_only_block_applies_in_browser_runtime
    model = in_browser do
      syncable_model("Todo") do
        browser_only { def local_hint = "browser" }
      end
    end

    assert_equal "browser", model.new.local_hint

    server_model = on_server do
      syncable_model("Todo") do
        browser_only { def local_hint = "browser" }
      end
    end

    refute server_model.new.respond_to?(:local_hint)
  end
end
