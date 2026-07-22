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
