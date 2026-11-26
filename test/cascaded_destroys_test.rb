require "test_helper"
require "instant_record/testing"

# What the server logs for the records a client's destroy takes along.
class CascadedDestroysTest < Minitest::Test
  TABLES = %i[cascade_folders cascade_pages cascade_remarks].freeze

  # Each test's tables and rows live in a transaction that is rolled back.
  def setup
    reset_instant_record_tables!
    @connection = ActiveRecord::Base.lease_connection
    @connection.begin_transaction(joinable: false)
    TABLES.each do |table|
      @connection.create_table(table, id: :string) do |t|
        t.string :title
        t.string :folder_id
        t.string :page_id
        t.string :owner
        t.integer :server_version, null: false, default: 0
        t.string :sync_state, null: false, default: "synced"
        t.timestamps
      end
    end
    @sequence = 0
    @since = 0
  end

  def teardown
    InstantRecord.sync
    @connection.rollback_transaction
    TABLES.each { |table| @connection.schema_cache.clear_data_source_cache!(table.to_s) }
  end

  # Fresh classes per test, so one test's associations are not another's. Each
  # resolves an association's class_name among the three.
  def models(folder: nil, page: nil, remark: nil)
    built = {}
    bodies = { folder: folder, page: page, remark: remark }
    bodies.each_key do |key|
      built[key] = Class.new(ActiveRecord::Base) do
        self.table_name = "cascade_#{key}s"
        define_singleton_method(:name) { key.to_s.capitalize }
        include InstantRecord::Syncable
        define_singleton_method(:compute_type) { |type| built.fetch(type.downcase.to_sym) }
      end
    end
    bodies.each { |key, body| built[key].class_eval(&body) if body }
    @folder, @page, @remark = built.values_at(:folder, :page, :remark)
    InstantRecord.sync(@folder, @page, @remark)
  end

  def cascade
    models(
      folder: proc { has_many :pages, class_name: "Page", foreign_key: :folder_id, dependent: :destroy },
      page: proc { has_many :remarks, class_name: "Remark", foreign_key: :page_id, dependent: :destroy }
    )
  end

  def seed
    on_server { yield }
    @since = InstantRecord::Change.maximum(:id) || 0
  end

  def apply(operation, model, id, changes = {}, identity: nil, partition: nil, mutation_id: "m-#{@sequence += 1}", **rest)
    mutation = { id: mutation_id, record_type: model.name, record_id: id, operation: operation, changes: changes, **rest }
    on_server { InstantRecord::MutationApplier.apply(mutation, identity, partition) }
  end

  def changes = InstantRecord::Change.where("id > ?", @since).order(:id).to_a
  def logged = changes.map { |change| [change.operation, change.record_type, change.record_id] }

  def test_a_destroyed_records_children_are_logged_at_every_depth_children_first
    cascade
    seed do
      @folder.create!(id: "f")
      @page.create!(id: "p1", folder_id: "f")
      @page.create!(id: "p2", folder_id: "f")
      @remark.create!(id: "r", page_id: "p1")
      @page.create!(id: "other")
    end

    assert_equal "applied", apply("destroy", @folder, "f")[:status]

    assert_equal [%w[destroy Remark r], %w[destroy Page p1], %w[destroy Page p2], %w[destroy Folder f]], logged
    assert(changes.all? { |change| change.version.zero? && change.attributes_payload == {} })
    assert_equal ["other"], @page.pluck(:id)
  end

  def test_the_order_is_the_one_a_server_side_destroy_logs
    cascade
    build = lambda do
      @folder.create!(id: "f")
      @page.create!(id: "p", folder_id: "f")
      @remark.create!(id: "r", page_id: "p")
    end
    seed(&build)
    on_server { @folder.find("f").destroy! }
    from_server = logged

    seed(&build)
    apply("destroy", @folder, "f")

    assert_equal from_server, logged
  end

  def test_every_logged_destroy_has_a_clock_and_takes_its_records_clock_away
    cascade
    seed do
      @folder.create!(id: "f")
      @page.create!(id: "p", folder_id: "f")
    end
    assert InstantRecord::HLC.record_hlc("Page", "p")
    sent = on_server { InstantRecord::HLC.from_time(Time.now, node: "abcdef12") }

    apply("destroy", @folder, "f", hlc: sent)

    child, target = changes
    assert_equal InstantRecord::HLC::SERVER_NODE, InstantRecord::HLC.node(child.hlc)
    assert_equal sent, target.hlc
    assert_nil InstantRecord::HLC.record_hlc("Page", "p")
    assert_nil InstantRecord::HLC.record_hlc("Folder", "f")
  end

  def test_the_target_is_logged_once_in_every_operation
    cascade

    apply("create", @folder, "f", { "title" => "a" })
    apply("update", @folder, "f", { "title" => "b" }, base_version: 1)
    apply("update", @folder, "f", { "owner" => "o" }, base_version: 1)
    apply("destroy", @folder, "f")

    assert_equal %w[create update update destroy].map { |operation| [operation, "Folder", "f"] }, logged
    assert_equal [1, 2, 3, 0], changes.map(&:version)
  end

  # The id is assigned in before_create, so it is not known when the write starts.
  def test_a_create_without_an_id_is_logged_once
    cascade

    result = apply("create", @folder, nil, { "title" => "a" })

    assert_equal "applied", result[:status]
    assert_equal [["create", "Folder", @folder.sole.id]], logged
    assert_equal 1, @folder.sole.server_version
  end

  # A callback that loads the row again holds another object for the same record.
  def test_a_second_copy_of_the_target_is_not_logged
    models(folder: proc { after_update { self.class.find(id).update!(owner: "again") unless owner == "again" || self.class.find(id).owner == "again" } })
    seed { @folder.create!(id: "f") }

    apply("update", @folder, "f", { "title" => "b" })

    assert_equal "again", @folder.find("f").owner
    assert_equal [%w[update Folder f]], logged
    assert_equal 2, @folder.find("f").server_version
  end

  def test_a_child_of_another_type_with_the_targets_id_is_logged
    cascade
    seed do
      @folder.create!(id: "same")
      @page.create!(id: "same", folder_id: "same")
    end

    apply("destroy", @folder, "same")

    assert_equal [%w[destroy Page same], %w[destroy Folder same]], logged
  end

  def test_a_scoped_child_is_logged_for_its_own_owner
    cascade
    @page.sync_scope :owner
    seed do
      @folder.create!(id: "f", owner: "ada")
      @page.create!(id: "ada", folder_id: "f", owner: "ada")
      @page.create!(id: "ben", folder_id: "f", owner: "ben")
      @page.create!(id: "all", folder_id: "f")
    end

    apply("destroy", @folder, "f", identity: "ada")

    assert_equal({ "ada" => "ada", "ben" => "ben", "all" => nil, "f" => nil }, changes.to_h { |change| [change.record_id, change.scope] })
  end

  def test_a_partitioned_child_is_logged_in_its_own_partition
    cascade
    [@folder, @page].each { |model| model.sync_partition :owner }
    seed do
      @folder.create!(id: "f", owner: "north")
      @page.create!(id: "n", folder_id: "f", owner: "north")
      @page.create!(id: "s", folder_id: "f", owner: "south")
    end

    assert_equal "applied", apply("destroy", @folder, "f", partition: "north")[:status]

    assert_equal({ "n" => "owner:north", "s" => "owner:south", "f" => "owner:north" },
      changes.to_h { |change| [change.record_id, change.partition] })
  end

  # A destroy of a `syncable_to` record carries no contents to anyone.
  def test_a_syncable_to_child_reaches_every_client_as_an_empty_destroy
    cascade
    @page.syncable_to { |who| where(owner: who) }
    seed do
      @folder.create!(id: "f")
      @page.create!(id: "p", folder_id: "f", owner: "ben", title: "secret")
    end

    apply("destroy", @folder, "f", identity: "ada")

    assert_equal [%w[destroy Page p], %w[destroy Folder f]], logged
    %w[ada ben].each do |who|
      event = on_server { InstantRecord::SyncScope.events_for(changes, who) }.first.last
      assert_equal ["Page", "p", "destroy", {}], event.values_at(:type, :id, :operation, :attributes)
    end
  end

  def test_a_destroy_that_fails_logs_nothing
    cascade
    @folder.before_destroy { raise ActiveRecord::RecordInvalid.new(self) }
    seed do
      @folder.create!(id: "f")
      @page.create!(id: "p", folder_id: "f")
    end
    before = InstantRecord::HLC.last

    assert_equal "rejected", apply("destroy", @folder, "f")[:status]

    assert_empty logged
    assert @page.exists?(id: "p")
    assert InstantRecord::HLC.record_hlc("Page", "p")
    assert_equal before, InstantRecord::HLC.last
  end

  def test_a_replayed_mutation_logs_nothing_more
    cascade
    seed do
      @folder.create!(id: "f")
      @page.create!(id: "p", folder_id: "f")
    end

    2.times { assert_equal "applied", apply("destroy", @folder, "f", mutation_id: "once")[:status] }

    assert_equal [%w[destroy Page p], %w[destroy Folder f]], logged
  end

  def test_a_hidden_targets_children_stay
    cascade
    @folder.syncable_to { |who| where(owner: who) }
    seed do
      @folder.create!(id: "f", owner: "ben")
      @page.create!(id: "p", folder_id: "f")
    end

    apply("destroy", @folder, "f", identity: "ada")

    assert_empty logged
    assert @page.exists?(id: "p")
  end

  def test_a_self_referential_cascade_logs_each_record_once
    models(folder: proc { has_many :folders, class_name: "Folder", foreign_key: :folder_id, dependent: :destroy })
    seed do
      @folder.create!(id: "a")
      @folder.create!(id: "b", folder_id: "a")
      @folder.create!(id: "c", folder_id: "b")
    end

    apply("destroy", @folder, "a")

    assert_equal [%w[destroy Folder c], %w[destroy Folder b], %w[destroy Folder a]], logged
  end

  # Folder -> remarks (the join) -> pages. Rails destroys the join rows and
  # leaves the records on the far side.
  def test_a_has_many_through_cascade_logs_the_join_rows_once
    models(
      folder: proc {
        has_many :remarks, class_name: "Remark", foreign_key: :folder_id
        has_many :pages, through: :remarks, source: :page, class_name: "Page", dependent: :destroy
      },
      remark: proc { belongs_to :page, class_name: "Page", foreign_key: :page_id, optional: true }
    )
    seed do
      @folder.create!(id: "f")
      @page.create!(id: "p")
      @remark.create!(id: "r", folder_id: "f", page_id: "p")
    end

    apply("destroy", @folder, "f")

    assert_equal [%w[destroy Remark r], %w[destroy Folder f]], logged
    assert @page.exists?(id: "p")
  end

  # Two associations reach the same remark.
  def test_a_record_reached_by_two_cascades_is_logged_once
    models(
      folder: proc {
        has_many :pages, class_name: "Page", foreign_key: :folder_id, dependent: :destroy
        has_many :remarks, class_name: "Remark", foreign_key: :folder_id, dependent: :destroy
      },
      page: proc { has_many :remarks, class_name: "Remark", foreign_key: :page_id, dependent: :destroy }
    )
    seed do
      @folder.create!(id: "f")
      @page.create!(id: "p", folder_id: "f")
      @remark.create!(id: "r", folder_id: "f", page_id: "p")
    end

    apply("destroy", @folder, "f")

    assert_equal [%w[destroy Remark r], %w[destroy Page p], %w[destroy Folder f]], logged
  end

  # The child is destroyed and takes its folder along.
  def test_a_cascade_up_a_belongs_to_is_logged
    models(page: proc { belongs_to :folder, class_name: "Folder", foreign_key: :folder_id, optional: true, dependent: :destroy })
    seed do
      @folder.create!(id: "f")
      @page.create!(id: "p", folder_id: "f")
    end

    apply("destroy", @page, "p")

    assert_equal [%w[destroy Folder f], %w[destroy Page p]], logged
  end

  # An id the server no longer has is still logged, so the browser lets go of it.
  def test_destroying_a_record_already_gone_logs_the_target_alone
    cascade

    apply("destroy", @folder, "gone")

    assert_equal [%w[destroy Folder gone]], logged
  end

  def test_the_server_frame_logs_a_cascade_once
    cascade
    @folder.define_singleton_method(:clear) { |args| find(args["id"]).destroy! }
    @folder.sync_action :clear
    seed do
      @folder.create!(id: "f")
      @page.create!(id: "p", folder_id: "f")
      @remark.create!(id: "r", page_id: "p")
    end

    result = on_server do
      InstantRecord::MutationApplier.apply({ id: "mut", operation: "mutator", mutator: "Folder.clear", args: { "id" => "f" } })
    end

    assert_equal "applied", result[:status], result.inspect
    assert_equal [%w[destroy Remark r], %w[destroy Page p], %w[destroy Folder f]], logged
  end

  def test_the_block_form_without_a_record_suppresses_every_record
    cascade
    seed do
      @folder.create!(id: "f")
      @page.create!(id: "p", folder_id: "f")
    end

    on_server do
      InstantRecord.applying_client_mutation do
        assert InstantRecord.applying_client_mutation?
        @folder.find("f").destroy!
        @folder.create!(id: "g")
      end
    end

    assert_empty logged
    refute InstantRecord.applying_client_mutation?
  end

  def test_a_record_seeded_by_the_testing_server_is_logged_once
    page_model = nil
    models(folder: proc { after_create { page_model.create!(id: "made") } })
    page_model = @page
    server = Object.new.extend(InstantRecord::Testing::AuthoritativeServer::SharedOperations)

    on_server { server.seed_boundary_record(model_name: "Folder", id: "f") }

    assert_equal [%w[create Folder f]], logged
  end

  # A write a callback makes is not logged with the server's present clock: it
  # would outrank an edit of that column the sender queued after this mutation.
  def test_a_later_queued_edit_of_a_column_a_callback_wrote_is_kept
    page_model = nil
    models(folder: proc { after_update { page_model.find("p").update!(title: title) } })
    page_model = @page
    seed do
      @folder.create!(id: "f", title: "a")
      @page.create!(id: "p", folder_id: "f", title: "a")
    end
    first, second = on_server { [0.01, 0.02].map { |later| InstantRecord::HLC.from_time(Time.now + later, node: "abcdef12") } }
    sleep 0.1

    apply("update", @folder, "f", { "title" => "b" }, base_version: 1, hlc: first)
    apply("update", @page, "p", { "title" => "mine" }, base_version: 1, hlc: second)

    assert_equal "mine", @page.find("p").title
  end

  def test_a_cascaded_destroy_a_callback_undoes_is_not_logged
    page_model = nil
    models(folder: proc {
      before_destroy do
        page_model.transaction(requires_new: true) do
          page_model.find("kept").destroy!
          raise ActiveRecord::Rollback
        end
        page_model.find("gone").destroy!
      end
    })
    page_model = @page
    seed do
      @folder.create!(id: "f")
      %w[kept gone].each { |id| @page.create!(id: id) }
    end

    apply("destroy", @folder, "f")

    assert_equal [%w[destroy Page gone], %w[destroy Folder f]], logged
    assert @page.exists?(id: "kept")
  end

  # Its callbacks run and its row stays, hidden from everyone.
  def test_a_child_that_is_softly_destroyed_is_logged
    cascade
    @page.class_eval do
      default_scope { where(owner: nil) }
      define_method(:destroy_row) { self.class.unscoped.where(id: id).update_all(owner: "deleted") }
      private :destroy_row
    end
    seed do
      @folder.create!(id: "f")
      @page.create!(id: "p", folder_id: "f")
    end

    apply("destroy", @folder, "f")

    assert_equal [%w[destroy Page p], %w[destroy Folder f]], logged
    assert @page.unscoped.exists?(id: "p")
  end

  # Saved before, so Rails leaves its destroyed? flag set on the rollback.
  def test_an_undone_destroy_of_a_record_saved_earlier_is_not_logged
    page_model = nil
    models(folder: proc {
      before_destroy do
        pages = %w[one two].map { |key| page_model.find(key).tap { |page| page.update!(title: "closing") } }
        page_model.transaction(requires_new: true) do
          pages.first.destroy!
          page_model.transaction(requires_new: true) { pages.last.destroy! }
          raise ActiveRecord::Rollback
        end
      end
    })
    page_model = @page
    seed do
      @folder.create!(id: "f")
      %w[one two].each { |id| @page.create!(id: id) }
    end

    apply("destroy", @folder, "f")

    assert_equal [%w[destroy Folder f]], logged
    assert_equal 2, @page.count
  end

  def test_a_destroyed_id_a_callback_creates_again_is_not_logged
    page_model = nil
    models(folder: proc {
      before_destroy do
        page_model.find("k").destroy!
        page_model.create!(id: "k", title: "new")
      end
    })
    page_model = @page
    seed do
      @folder.create!(id: "f")
      @page.create!(id: "k")
    end

    apply("destroy", @folder, "f")

    assert_equal [%w[destroy Folder f]], logged
    assert_equal "new", @page.find("k").title
  end

  def test_a_create_that_is_undone_leaves_the_destroy_logged
    page_model = nil
    models(folder: proc {
      before_destroy do
        page_model.find("k").destroy!
        page_model.transaction(requires_new: true) do
          page_model.create!(id: "k", title: "new")
          raise ActiveRecord::Rollback
        end
      end
    })
    page_model = @page
    seed do
      @folder.create!(id: "f")
      @page.create!(id: "k")
    end

    apply("destroy", @folder, "f")

    assert_equal [%w[destroy Page k], %w[destroy Folder f]], logged
    refute @page.exists?(id: "k")
  end

  def test_a_destroy_and_create_undone_together_log_nothing
    [false, true].each do |nested|
      page_model = nil
      models(folder: proc {
        before_destroy do
          page_model.transaction(requires_new: true) do
            page_model.find("k").destroy!
            page_model.transaction(requires_new: nested) { page_model.create!(id: "k", title: "new") }
            raise ActiveRecord::Rollback
          end
        end
      })
      page_model = @page
      seed do
        @folder.create!(id: "f")
        @page.create!(id: "k", title: "old") unless @page.exists?(id: "k")
      end

      apply("destroy", @folder, "f")

      assert_equal [%w[destroy Folder f]], logged
      assert_equal "old", @page.find("k").title
      assert InstantRecord::HLC.record_hlc("Page", "k")
    end
  end

  def test_a_row_created_again_and_then_destroyed_is_logged_once
    page_model = nil
    models(folder: proc {
      before_destroy do
        page_model.find("k").destroy!
        page_model.create!(id: "k").destroy!
      end
    })
    page_model = @page
    seed do
      @folder.create!(id: "f")
      @page.create!(id: "k")
    end

    apply("destroy", @folder, "f")

    assert_equal [%w[destroy Page k], %w[destroy Folder f]], logged
  end

  # Another object already destroyed the row, and this one cannot say whose it was.
  def test_a_second_partial_copy_of_a_destroyed_child_does_not_raise
    page_model = nil
    models(folder: proc {
      before_destroy do
        partial = page_model.select(:id, :folder_id).find("k")
        page_model.find("k").destroy!
        partial.destroy
      end
    })
    @page.sync_scope :owner
    page_model = @page
    seed do
      @folder.create!(id: "f")
      @page.create!(id: "k", owner: "ben")
    end

    assert_equal "applied", apply("destroy", @folder, "f")[:status]
    assert_equal [["Page", "ben"], ["Folder", nil]], changes.map { |change| [change.record_type, change.scope] }
  end

  def test_a_child_loaded_without_its_scope_is_logged_for_its_owner
    models(folder: proc { has_many :pages, -> { select(:id, :folder_id) }, class_name: "Page", foreign_key: :folder_id, dependent: :destroy })
    @page.sync_scope :owner
    seed do
      @folder.create!(id: "f")
      @page.create!(id: "p", folder_id: "f", owner: "ben")
    end

    assert_equal "applied", apply("destroy", @folder, "f", identity: "ada")[:status]

    assert_equal [["Page", "ben"], ["Folder", nil]], changes.map { |change| [change.record_type, change.scope] }
  end

  def test_a_child_loaded_without_its_partition_is_logged_in_it
    models(folder: proc { has_many :pages, -> { select(:id, :folder_id) }, class_name: "Page", foreign_key: :folder_id, dependent: :destroy })
    @page.sync_partition :owner
    seed do
      @folder.create!(id: "f")
      @page.create!(id: "p", folder_id: "f", owner: "south")
    end

    assert_equal "applied", apply("destroy", @folder, "f")[:status]

    assert_equal ["owner:south", nil], changes.map(&:partition)
  end

  def test_destroying_an_unsaved_record_in_a_callback_changes_nothing
    page_model = nil
    models(folder: proc { before_destroy { [nil, "k"].each { |key| page_model.new(id: key, title: "x").destroy } } })
    page_model = @page
    seed do
      @folder.create!(id: "f")
      @page.create!(id: "k")
    end

    assert_equal "applied", apply("destroy", @folder, "f")[:status]
    assert_equal [%w[destroy Folder f]], logged
    assert @page.exists?(id: "k")
  end

  def test_the_children_are_logged_after_every_row_is_gone
    cascade
    seed do
      @folder.create!(id: "f")
      2.times { |i| @page.create!(id: "p#{i}", folder_id: "f") }
    end

    statements = []
    callback = ->(*, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      apply("destroy", @folder, "f", hlc: InstantRecord::HLC.from_time(Time.now, node: "abcdef12"))
    end

    last_removal = statements.rindex { |sql| sql.match?(/\ADELETE.*cascade_/m) }
    first_log = statements.index { |sql| sql.match?(/\AINSERT INTO "instant_record_(changes|sync_metadata)"/) }
    assert_operator last_removal, :<, first_log
  end

  def test_collecting_ends_with_the_destroy_even_when_it_fails
    cascade
    @folder.before_destroy { raise ActiveRecord::RecordInvalid.new(self) }
    seed { @folder.create!(id: "f") }

    apply("destroy", @folder, "f")

    assert_nil ActiveSupport::IsolatedExecutionState[:instant_record_cascaded_destroys]
  end
end
