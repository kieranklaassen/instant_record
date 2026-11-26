require "test_helper"

# One client's queue of edits made while offline: they share a base version and
# carry rising clocks of one node, and reach the server in order.
class QueuedEditsTest < Minitest::Test
  HLC = InstantRecord::HLC
  POLICIES = %i[lww union server_wins].freeze

  def setup
    reset_instant_record_tables!
    @t0 = Time.utc(2026, 11, 21, 12, 0, 0)
    @sequence = 0
  end

  def teardown
    InstantRecord.sync
  end

  def test_every_queued_edit_of_a_column_is_kept
    POLICIES.each do |policy|
      synced_record(policy)
      results = (1..7).map { |n| edit({ "title" => "edit#{n}" }, at: n) }

      assert_equal "edit7", @record.reload.title, policy
      assert_empty results.select { |result| result[:skipped] }, policy
      assert_rising
    end
  end

  def test_edits_of_other_columns_in_between_are_kept
    POLICIES.each do |policy|
      synced_record(policy)
      (1..4).each do |n|
        edit({ "title" => "edit#{n}" }, at: 2 * n)
        edit({ "state" => "state#{n}" }, at: 2 * n + 1)
      end

      assert_equal %w[edit4 state4], [@record.reload.title, @record.state], policy
      assert_rising
    end
  end

  # The row's clock is past the queue's when the first of it arrives.
  def test_the_queue_is_kept_after_a_later_edit_of_another_column
    POLICIES.each do |policy|
      synced_record(policy)
      edit({ "owner" => "theirs" }, at: 15, node: "clientbb")
      results = (1..5).map { |n| edit({ "title" => "edit#{n}" }, at: n) }

      assert_equal %w[edit5 theirs], [@record.reload.title, @record.owner], policy
      assert_empty results.select { |result| result[:skipped] }, policy
      assert_rising
    end
  end

  def test_the_queue_is_kept_around_edits_of_another_column
    POLICIES.each do |policy|
      synced_record(policy)
      edit({ "title" => "edit1" }, at: 1)
      edit({ "title" => "edit2" }, at: 2)
      server_update(owner: "server")
      edit({ "title" => "edit3" }, at: 3)
      edit({ "owner" => "theirs" }, at: 25, node: "clientbb", base_version: 4)
      edit({ "title" => "edit4" }, at: 4)
      edit({ "title" => "edit5", "state" => "mine" }, at: 5)
      edit({ "state" => "mine too" }, at: 6)

      assert_equal ["edit5", "theirs", "mine too"], [@record.reload.title, @record.owner, @record.state], policy
      assert_rising
    end
  end

  def test_two_clients_queues_on_different_columns_interleave
    POLICIES.each do |policy|
      synced_record(policy)
      (1..4).each do |n|
        edit({ "title" => "edit#{n}" }, at: n)
        edit({ "state" => "state#{n}" }, at: n, node: "clientbb")
      end

      assert_equal %w[edit4 state4], [@record.reload.title, @record.state], policy
      assert_rising
    end
  end

  # A record created offline has no base version.
  def test_the_queue_of_a_record_created_offline_is_kept
    POLICIES.each do |policy|
      define_model(policy)
      apply("create", { "title" => "created" }, at: 1, base_version: 0)
      (2..5).each { |n| edit({ "title" => "edit#{n}" }, at: 2 * n, base_version: 0) }
      edit({ "state" => "mine" }, at: 12, base_version: 0)
      edit({ "title" => "last" }, at: 13, base_version: 0)

      @record = @model.find(@id)
      assert_equal %w[last mine], [@record.title, @record.state], policy
      assert_rising
    end
  end

  def test_others_edits_of_other_columns_leave_the_queue_of_a_record_created_offline
    POLICIES.each do |policy|
      [true, false].each do |by_client|
        created_record(policy)
        edit({ "title" => "edit1" }, at: 2, base_version: 0)
        if by_client
          edit({ "owner" => "theirs" }, at: 15, node: "clientbb", base_version: 2)
        else
          server_update(owner: "theirs")
        end
        (3..5).each { |n| edit({ "title" => "edit#{n}" }, at: n, base_version: 0) }

        assert_equal %w[edit5 theirs], [@record.reload.title, @record.owner], policy
        assert_rising
      end
    end
  end

  def test_a_known_base_counts_rather_than_the_create
    created_record(:server_wins)
    edit({ "title" => "theirs" }, at: 5, node: "clientbb")
    server_update(owner: "server")
    (30..33).each { |n| edit({ "title" => "edit#{n}" }, at: n, base_version: 2) }

    assert_equal "edit33", @record.reload.title
  end

  def test_others_edits_of_the_column_end_the_queue_of_a_record_created_offline
    { lww: "theirs", server_wins: "theirs", union: "theirs,edit3" }.each do |policy, title|
      created_record(policy)
      edit({ "title" => "edit2" }, at: 2, base_version: 0)
      server_update(title: "theirs")
      edit({ "title" => "edit3" }, at: 3, base_version: 0)

      assert_equal title, @record.reload.title, policy
    end
  end

  def test_a_change_made_by_hand_stays_the_servers_in_a_record_created_offline
    created_record(:server_wins)
    edit({ "title" => "edit1" }, at: 2, base_version: 0)
    @record.reload.update_columns(state: "by hand")
    edit({ "title" => "edit2" }, at: 3, base_version: 0)
    @record.reload.update_columns(title: "by hand")
    @model.sync_merge :state, :server_wins

    assert edit({ "state" => "mine", "title" => "edit3" }, at: 4, base_version: 0)[:skipped]
    assert_equal ["by hand", "by hand"], [@record.reload.title, @record.state]
  end

  # The create of a record that is gone says nothing of the one now under its id.
  def test_a_record_the_server_made_again_is_not_the_clients_creation
    created_record(:server_wins)
    apply("destroy", {}, at: 2)
    synced = HLC.with_clock(-> { @t0 + 20 }) { on_server { @model.create!(id: @id, title: "again") } }

    assert edit({ "title" => "mine" }, at: 30, base_version: 0)[:skipped]
    assert_equal "again", synced.reload.title
  end

  def test_the_queue_is_kept_when_the_log_has_lost_its_base
    POLICIES.each do |policy|
      synced_record(policy)
      edit({ "title" => "edit1" }, at: 1)
      InstantRecord::Change.where(record_id: @id).update_all(record_id: "pruned")
      (2..5).each { |n| edit({ "title" => "edit#{n}" }, at: n) }

      assert_equal "edit5", @record.reload.title, policy
    end
  end

  def test_without_a_base_a_merge_vouches_only_for_its_own_columns
    synced_record(:server_wins)
    edit({ "title" => "edit1" }, at: 1)
    InstantRecord::Change.where(record_id: @id).update_all(record_id: "pruned")
    edit({ "title" => "edit2" }, at: 2)
    @record.reload.update_columns(state: "by hand")
    @model.sync_merge :state, :server_wins

    assert edit({ "state" => "mine" }, at: 3)[:skipped]
  end

  def test_an_edit_that_is_not_newer_than_the_last_kept_one_is_not_a_sequel
    synced_record(:server_wins)
    (1..3).each { |n| edit({ "title" => "edit#{n}" }, at: n) }

    assert edit({ "title" => "same" }, at: 3)[:skipped]
    assert edit({ "title" => "older" }, at: 2)[:skipped]
    assert_equal "edit3", @record.reload.title
  end

  def test_a_run_that_ends_in_an_undated_change_is_not_continued
    synced_record(:server_wins)
    (1..2).each { |n| edit({ "title" => "edit#{n}" }, at: n) }
    change = InstantRecord::Change.where(record_id: @id).order(:id).last
    InstantRecord::SyncMetadata.delete("#{HLC::CHANGE_PREFIX}#{change.id}")
    change.update!(attributes_payload: change.attributes_payload.merge("updated_at" => "no time"))

    assert edit({ "title" => "edit3" }, at: 3)[:skipped]
  end

  # --- Edits of the same column by somebody else ------------------------------

  def test_another_writers_edit_before_the_queue_is_resolved_by_policy
    { lww: "theirs", server_wins: "theirs", union: "theirs,edit1,edit2,edit3" }.each do |policy, title|
      [true, false].each do |by_client|
        synced_record(policy)
        by_client ? edit({ "title" => "theirs" }, at: 15, node: "clientbb") : server_update(title: "theirs")
        (1..3).each { |n| edit({ "title" => "edit#{n}" }, at: n) }

        assert_equal title, @record.reload.title, policy
      end
    end
  end

  def test_another_writers_edit_between_is_resolved_by_policy
    { lww: "theirs", server_wins: "theirs", union: "theirs,edit3,edit4" }.each do |policy, title|
      [true, false].each do |by_client|
        synced_record(policy)
        (1..2).each { |n| edit({ "title" => "edit#{n}" }, at: n) }
        if by_client
          edit({ "title" => "theirs" }, at: 25, node: "clientbb", base_version: 3)
        else
          server_update(title: "theirs")
        end
        (3..4).each { |n| edit({ "title" => "edit#{n}" }, at: n) }

        assert_equal title, @record.reload.title, policy
      end
    end
  end

  # Newer than theirs, so that only whose edit it was can tell it from a sequel.
  def test_edits_newer_than_another_writers_are_no_sequel_of_it
    [true, false].each do |between|
      synced_record(:server_wins)
      (1..2).each { |n| edit({ "title" => "edit#{n}" }, at: n) } if between
      edit({ "title" => "theirs" }, at: 25, node: "clientbb", base_version: between ? 3 : 1)
      results = (30..32).map { |n| edit({ "title" => "edit#{n}" }, at: n) }

      assert results.all? { |result| result[:skipped] }
      assert_equal "theirs", @record.reload.title
    end
  end

  def test_a_merge_does_not_vouch_for_the_column_it_had_to_contest
    synced_record(:lww)
    edit({ "title" => "theirs" }, at: 5, node: "clientbb")
    edit({ "title" => "edit1", "state" => "mine" }, at: 6)

    assert edit({ "title" => "edit2", "state" => "mine too" }, at: 7, base_version: 2)[:merged]
    assert_equal ["edit1", "mine too"], [@record.reload.title, @record.state]
  end

  # A merge dates what it took by the server's clock, whatever clock it is logged under.
  def test_another_clients_edit_after_the_queue_is_resolved_by_policy
    { lww: "edit3", server_wins: "edit3", union: "edit3,theirs" }.each do |policy, title|
      synced_record(policy)
      (1..3).each { |n| edit({ "title" => "edit#{n}" }, at: n) }
      edit({ "title" => "theirs" }, at: 10, node: "clientbb")
      assert_equal title, @record.reload.title, "#{policy}: made before the merge"
    end

    { lww: "theirs", server_wins: "edit3" }.each do |policy, title|
      synced_record(policy)
      (1..3).each { |n| edit({ "title" => "edit#{n}" }, at: n) }
      edit({ "title" => "theirs" }, at: 40, node: "clientbb")
      assert_equal title, @record.reload.title, "#{policy}: made after the merge"
    end
  end

  def test_without_a_base_another_clients_edit_is_dated_against_the_merge_too
    synced_record(:lww)
    (1..3).each { |n| edit({ "title" => "edit#{n}" }, at: n) }

    assert edit({ "title" => "theirs" }, at: 10, node: "clientbb", base_version: 0)[:skipped]
    assert_equal "edit3", @record.reload.title
  end

  def test_an_edit_without_a_base_version_is_dated_against_the_merge_too
    synced_record(:lww)
    (1..3).each { |n| edit({ "title" => "edit#{n}" }, at: n) }

    assert edit({ "title" => "theirs" }, at: 10, node: "clientbb", base_version: nil)[:skipped]
    assert edit({ "updated_at" => (@t0 + 10).iso8601(6) }, at: 10, node: "clientbb")[:skipped]
    refute edit({ "title" => "edit4" }, at: 4, base_version: nil)[:skipped]
    assert_equal "edit4", @record.reload.title
  end

  def test_a_change_made_by_hand_stays_the_servers_through_the_queue
    synced_record(:server_wins)
    edit({ "title" => "edit1" }, at: 1)
    edit({ "state" => "mine" }, at: 2)
    @record.reload.update_columns(title: "by hand")
    edit({ "state" => "mine too" }, at: 3)

    assert edit({ "title" => "edit2" }, at: 4)[:skipped]
    assert_equal ["by hand", "mine too"], [@record.reload.title, @record.state]
  end

  # --- Merges that keep the server's clock -------------------------------------

  def test_a_contested_edit_is_logged_under_the_servers_clock
    synced_record(:lww)
    edit({ "title" => "theirs" }, at: 15, node: "clientbb")
    edit({ "state" => "mine" }, at: 20, base_version: 2)
    result = edit({ "title" => "mine" }, at: 21)

    assert_equal ["mine", HLC::SERVER_NODE], [@record.reload.title, HLC.node(result[:hlc])]
  end

  def test_an_edit_that_arrives_after_a_later_one_is_logged_under_the_servers_clock
    synced_record(:lww)
    edit({ "state" => "later" }, at: 5)
    result = edit({ "title" => "earlier" }, at: 2)

    assert_equal ["earlier", HLC::SERVER_NODE], [@record.reload.title, HLC.node(result[:hlc])]
    assert_rising
  end

  def test_the_legacy_node_is_no_client_with_a_run_of_its_own
    synced_record(:lww)
    edit({ "state" => "first" }, at: 1, node: HLC::LEGACY_NODE)

    assert_equal HLC::SERVER_NODE, HLC.node(edit({ "title" => "second" }, at: 2, node: HLC::LEGACY_NODE)[:hlc])
  end

  # --- The clients ------------------------------------------------------------

  def test_another_client_follows_every_queued_edit
    [false, true].each do |concurrent|
      synced_record(:lww)
      edit({ "owner" => "theirs" }, at: 15, node: "clientbb") if concurrent
      (1..5).each { |n| edit({ "title" => "edit#{n}" }, at: n) }
      events = change_events

      as_client do
        titles = events.map { |event| InstantRecord::Client.apply_change(event); @model.find(@id).title }
        assert_equal %w[base] + (concurrent ? %w[base] : []) + (1..5).map { |n| "edit#{n}" }, titles
      end
    end
  end

  def test_the_senders_outbox_drains_to_its_newest_edit
    [1, 100].each do |batch|
      [false, true].each do |concurrent|
        synced_record(:lww)
        created = change_events
        mutations = nil
        browser = as_client do
          created.each { |event| InstantRecord::Client.apply_change(event) }
          (1..5).each { |n| HLC.with_clock(-> { @t0 + n }) { @model.find(@id).update!(title: "edit#{n}") } }
          mutations = InstantRecord::OutboxMutation.ordered.map(&:as_mutation)
        end
        assert_equal [1], mutations.map { |mutation| mutation[:base_version] }.uniq

        edit({ "owner" => "theirs" }, at: 15, node: "clientbb") if concurrent
        mutations.each_slice(batch) do |slice|
          cursor = InstantRecord::Change.maximum(:id)
          results = slice.map { |mutation| server_apply(mutation, at: 20) }
          events = InstantRecord::Change.after(cursor).map { |change| change.as_event.deep_stringify_keys }

          browser = as_client(browser) do
            events.each { |event| InstantRecord::Client.apply_change(event) }
            # What others did to the row is nothing the sender can date its own edits by.
            assert_equal "edit5", @model.find(@id).title unless concurrent
            InstantRecord::Client.apply_results(results)
            assert_equal "edit5", @model.find(@id).title unless concurrent
          end
        end

        as_client(browser) do
          row = @model.find(@id)
          assert_equal ["edit5", "synced", concurrent ? "theirs" : nil], [row.title, row.sync_state, row.owner]
          assert_equal 0, InstantRecord::OutboxMutation.count
          assert_equal 0, InstantRecord::SyncNotice.count
        end
        assert_equal "edit5", @record.reload.title
      end
    end
  end

  private

  def define_model(policy)
    reset_instant_record_tables!
    @id = "r-#{@sequence += 1}"
    @model = syncable_model("Task") { sync_merge :title, policy }
    InstantRecord.sync(@model)
  end

  def synced_record(policy)
    define_model(policy)
    @record = HLC.with_clock(-> { @t0 }) do
      on_server { @model.create!(id: @id, title: "base", created_at: @t0, updated_at: @t0) }
    end
  end

  def created_record(policy)
    define_model(policy)
    apply("create", { "title" => "created" }, at: 1, base_version: 0)
    @record = @model.find(@id)
  end

  def server_update(attributes)
    HLC.with_clock(-> { @t0 + 20 }) { on_server { @record.reload.update!(attributes) } }
  end

  def edit(changes, at:, node: "clientaa", base_version: 1)
    apply("update", changes, at: at, node: node, base_version: base_version)
  end

  # Everything reaches the server at second 20 or, when made later, as it is made.
  def apply(operation, changes, at:, node: "clientaa", base_version: 1)
    server_apply({
      id: "m-#{@sequence += 1}", record_type: "Task", record_id: @id, operation: operation,
      base_version: base_version, changes: changes, hlc: HLC.from_time(@t0 + at, node: node)
    }, at: [at, 20].max)
  end

  def server_apply(mutation, at:)
    HLC.with_clock(-> { @t0 + at }) { on_server { InstantRecord::MutationApplier.apply(mutation) } }
  end

  def change_events
    InstantRecord::Change.where(record_id: @id).order(:id).map { |change| change.as_event.deep_stringify_keys }
  end

  def assert_rising
    clocks = InstantRecord::Change.where(record_id: @id).order(:id).map(&:hlc)
    assert_equal clocks.uniq.sort, clocks
    assert_equal clocks.last, HLC.record_hlc("Task", @id)
  end

  # Runs the block as a browser with a database of its own: the server's rows
  # are put aside and back, and the browser's are returned for its next turn.
  def as_client(state = nil)
    tables = [@model, InstantRecord::OutboxMutation, InstantRecord::SyncMetadata, InstantRecord::SyncNotice]
    server = tables.map { |table| dump(table) }
    load_tables(tables, state || tables.map { [] })
    HLC.with_clock(-> { @t0 }) { in_browser { yield } }
    tables.map { |table| dump(table) }
  ensure
    load_tables(tables, server)
  end

  def dump(table)
    ActiveRecord::Base.connection.select_all("SELECT * FROM #{table.table_name}").to_a
  end

  def load_tables(tables, rows)
    tables.zip(rows) do |table, dumped|
      ActiveRecord::Base.connection.truncate(table.table_name)
      dumped.each { |row| ActiveRecord::Base.connection.insert_fixture(row, table.table_name) }
    end
  end
end
