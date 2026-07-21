require "test_helper"

ActiveRecord::Schema.define do
  create_table :notes, id: :string, force: true do |t|
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

  create_table :instant_record_sync_metadata, id: false, force: true do |t|
    t.string :key, null: false, primary_key: true
    t.string :value
    t.timestamps
  end
end

class ClientTest < Minitest::Test
  def setup
    InstantRecord.singleton_class.class_eval do
      alias_method :original_browser?, :browser?
      define_method(:browser?) { true }
    end
    @model = Class.new(ActiveRecord::Base) do
      self.table_name = "notes"
      def self.name = "Note"
      include InstantRecord::Syncable
    end
    InstantRecord.sync(@model)
    @model.delete_all
    InstantRecord::OutboxMutation.delete_all
    InstantRecord::SyncMetadata.delete_all
  end

  def teardown
    InstantRecord.sync
    InstantRecord.singleton_class.class_eval do
      remove_method :browser?
      alias_method :browser?, :original_browser?
      remove_method :original_browser?
    end
  end

  def test_pending_mutations_json_is_ordered_and_complete
    note = @model.create!(title: "one")
    note.update!(title: "two")

    mutations = JSON.parse(InstantRecord.pending_mutations_json)
    assert_equal %w[create update], mutations.map { |m| m["operation"] }
    assert_equal note.id, mutations.first["record_id"]
    assert_equal 2, InstantRecord.pending_count
  end

  def test_applied_result_clears_outbox_and_marks_record_synced
    note = @model.create!(title: "one")
    mutation_id = InstantRecord::OutboxMutation.sole.id

    InstantRecord.apply_results([{ mutation_id: mutation_id, status: "applied", version: 1 }].to_json)

    assert_equal 0, InstantRecord.pending_count
    note.reload
    assert_equal "synced", note.sync_state
    assert_equal 1, note.server_version
  end

  def test_rejected_update_reconciles_to_server_attributes
    note = @model.create!(title: "server title")
    InstantRecord::OutboxMutation.delete_all
    note.update!(title: "local rejected title")
    mutation_id = InstantRecord::OutboxMutation.sole.id

    InstantRecord.apply_results([{
      mutation_id: mutation_id, status: "rejected", reason: "not allowed",
      server_attributes: { "id" => note.id, "title" => "server title", "updated_at" => 1.hour.from_now.iso8601 },
      version: 5
    }].to_json)

    note.reload
    assert_equal "server title", note.title
    assert_equal "synced", note.sync_state
    assert_equal 5, note.server_version
    assert_equal 0, InstantRecord.pending_count
  end

  def test_rejected_create_removes_local_record
    note = @model.create!(title: "never accepted")
    mutation_id = InstantRecord::OutboxMutation.sole.id

    InstantRecord.apply_results([{ mutation_id: mutation_id, status: "rejected", reason: "nope" }].to_json)

    refute @model.exists?(note.id)
    assert_equal 0, InstantRecord.pending_count
  end

  def test_rejection_with_pending_later_mutation_keeps_it_queued
    note = @model.create!(title: "one")
    note.update!(title: "two")
    create_mutation_id = InstantRecord::OutboxMutation.ordered.first.id

    InstantRecord.apply_results([{
      mutation_id: create_mutation_id, status: "rejected", reason: "nope",
      server_attributes: { "id" => note.id, "title" => "server", "updated_at" => Time.current.iso8601 }
    }].to_json)

    assert_equal 1, InstantRecord.pending_count
    assert_equal "update", InstantRecord::OutboxMutation.sole.operation
  end

  def test_apply_change_upserts_and_advances_cursor
    InstantRecord.apply_change({
      type: "Note", id: "abc-123", operation: "create", version: 1, cursor: 42,
      attributes: { "id" => "abc-123", "title" => "from server", "updated_at" => Time.current.iso8601 }
    }.to_json)

    note = @model.find("abc-123")
    assert_equal "from server", note.title
    assert_equal "synced", note.sync_state
    assert_equal 42, InstantRecord.cursor
    assert_equal 0, InstantRecord.pending_count, "applying remote changes must not enqueue mutations"
  end

  def test_apply_change_respects_local_newer_write
    note = @model.create!(title: "local newer")

    InstantRecord.apply_change({
      type: "Note", id: note.id, operation: "update", version: 2, cursor: 43,
      attributes: { "id" => note.id, "title" => "stale remote", "updated_at" => (note.updated_at - 1.hour).iso8601 }
    }.to_json)

    assert_equal "local newer", note.reload.title
  end

  def test_apply_change_destroy_removes_record
    note = @model.create!(title: "goner")
    InstantRecord::OutboxMutation.delete_all

    InstantRecord.apply_change({
      type: "Note", id: note.id, operation: "destroy", version: 0, cursor: 44, attributes: {}
    }.to_json)

    refute @model.exists?(note.id)
    assert_equal 0, InstantRecord.pending_count
  end

  def test_cursor_persists
    InstantRecord.cursor = 99
    assert_equal 99, InstantRecord.cursor
  end
end
