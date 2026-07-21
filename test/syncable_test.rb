require "test_helper"

ActiveRecord::Schema.define do
  create_table :todos, id: :string, force: true do |t|
    t.string :title
    t.integer :server_version, null: false, default: 0
    t.string :sync_state, null: false, default: "synced"
    t.timestamps
  end

  create_table :instant_record_outbox, id: :string, force: true do |t|
    t.string :record_type, null: false
    t.string :record_id, null: false
    t.string :operation, null: false
    t.text :changes_payload
    t.integer :base_version, null: false, default: 0
    t.timestamps
  end
end

class Todo < ActiveRecord::Base
  include InstantRecord::Syncable
end

class SyncableTest < Minitest::Test
  def setup
    # Tests run under CRuby; force the browser write path so outbox behavior
    # is exercised without ruby.wasm.
    InstantRecord.singleton_class.class_eval do
      alias_method :original_browser?, :browser?
      define_method(:browser?) { true }
    end
    # Re-include so browser-only callbacks are registered for this run.
    @model = Class.new(ActiveRecord::Base) do
      self.table_name = "todos"
      def self.name = "Todo"
      include InstantRecord::Syncable
    end
    Todo.delete_all
    InstantRecord::OutboxMutation.delete_all
  end

  def teardown
    InstantRecord.singleton_class.class_eval do
      remove_method :browser?
      alias_method :browser?, :original_browser?
      remove_method :original_browser?
    end
  end

  def test_create_assigns_uuid_and_records_outbox_mutation_atomically
    todo = @model.create!(title: "hello")

    assert_match(/\A[0-9a-f-]{36}\z/, todo.id)
    assert_equal "pending", todo.sync_state

    mutation = InstantRecord::OutboxMutation.sole
    assert_equal "create", mutation.operation
    assert_equal "Todo", mutation.record_type
    assert_equal todo.id, mutation.record_id
    assert_equal "hello", mutation.changes_payload["title"]
  end

  def test_update_records_changed_attributes_and_base_version
    todo = @model.create!(title: "hello")
    todo.update_column(:server_version, 3)
    InstantRecord::OutboxMutation.delete_all

    todo.update!(title: "world")

    mutation = InstantRecord::OutboxMutation.sole
    assert_equal "update", mutation.operation
    assert_equal 3, mutation.base_version
    assert_equal "world", mutation.changes_payload["title"]
    refute_includes mutation.changes_payload.keys, "sync_state"
  end

  def test_destroy_records_destroy_mutation
    todo = @model.create!(title: "hello")
    InstantRecord::OutboxMutation.delete_all

    todo.destroy!

    mutation = InstantRecord::OutboxMutation.sole
    assert_equal "destroy", mutation.operation
    assert_equal todo.id, mutation.record_id
  end

  def test_rolled_back_transaction_leaves_no_record_and_no_mutation
    assert_raises(RuntimeError) do
      ActiveRecord::Base.transaction do
        @model.create!(title: "doomed")
        raise "boom"
      end
    end

    assert_equal 0, @model.count
    assert_equal 0, InstantRecord::OutboxMutation.count
  end

  def test_two_writes_produce_two_ordered_mutations
    todo = @model.create!(title: "first")
    todo.update!(title: "second")

    operations = InstantRecord::OutboxMutation.ordered.pluck(:operation)
    assert_equal %w[create update], operations
  end

  def test_server_runtime_records_no_outbox_mutations
    InstantRecord.singleton_class.send(:define_method, :browser?) { false }
    server_model = Class.new(ActiveRecord::Base) do
      self.table_name = "todos"
      def self.name = "Todo"
      include InstantRecord::Syncable
    end

    server_model.create!(title: "server side")
    assert_equal 0, InstantRecord::OutboxMutation.count
  end
end
