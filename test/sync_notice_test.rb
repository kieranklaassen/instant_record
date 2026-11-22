require "test_helper"
require "instant_record/compiler/browser_migrations"
require "tmpdir"

class SyncNoticeTest < Minitest::Test
  def setup
    @model = syncable_model("Note")
    InstantRecord.sync(@model)
    @notices = []
    @notifier = Class.new do
      attr_reader :payloads
      def initialize = @payloads = []
      def records_changed = @payloads << InstantRecord::Client.changes_notice
    end.new
    InstantRecord::Client.notifier = @notifier
    reset_instant_record_tables!
    InstantRecord::Client.forget_database
  end

  def teardown
    InstantRecord.sync
    InstantRecord::Client.notifier = nil
    InstantRecord::Client.forget_database
  end

  def test_rejected_create_quarantines_attempted_changes_and_reason_before_destroying_outbox
    note = in_browser { @model.create!(title: "reject me", state: "open") }
    mutation_id = InstantRecord::OutboxMutation.sole.id

    in_browser do
      InstantRecord::Client.apply_results([{
        "mutation_id" => mutation_id,
        "status" => "rejected",
        "reason" => "Title is not allowed by the server"
      }])
    end

    refute @model.exists?(note.id)
    assert_equal 0, InstantRecord::OutboxMutation.count

    notice = InstantRecord::SyncNotice.active.sole
    assert_equal "rejected", notice.kind
    assert_equal mutation_id, notice.mutation_id
    assert_equal "Note", notice.record_type
    assert_equal note.id, notice.record_id
    assert_equal "create", notice.operation
    assert_equal "Title is not allowed by the server", notice.reason
    assert_equal "reject me", notice.attempted_changes["title"]
    assert_equal "open", notice.attempted_changes["state"]
    assert_equal({}, notice.server_attributes)
  end

  def test_rejected_update_quarantines_attempted_changes_and_winning_server_attributes
    note = in_browser { @model.create!(title: "original", state: "open") }
    server_stamp = note.updated_at
    InstantRecord::OutboxMutation.delete_all

    in_browser { note.update!(title: "forbidden edit") }
    mutation_id = InstantRecord::OutboxMutation.sole.id

    in_browser do
      InstantRecord::Client.apply_results([{
        "mutation_id" => mutation_id,
        "status" => "rejected",
        "reason" => "not permitted",
        "version" => 4,
        "server_attributes" => {
          "id" => note.id,
          "title" => "original",
          "state" => "open",
          "updated_at" => server_stamp.utc.iso8601(6)
        }
      }])
    end

    assert_equal "original", note.reload.title
    notice = InstantRecord::SyncNotice.active.sole
    assert_equal "rejected", notice.kind
    assert_equal "update", notice.operation
    assert_equal "not permitted", notice.reason
    assert_equal 4, notice.server_version
    assert_equal "forbidden edit", notice.attempted_changes["title"]
    assert_equal "original", notice.server_attributes["title"]
    assert_equal [{ "field" => "title", "local" => "forbidden edit", "server" => "original" }], notice.field_diffs
  end

  def test_lww_skipped_update_quarantines_conflict_notice
    note = in_browser { @model.create!(title: "v1", state: "open") }
    InstantRecord::OutboxMutation.delete_all

    in_browser { note.update!(title: "offline losing write") }
    mutation_id = InstantRecord::OutboxMutation.sole.id

    in_browser do
      InstantRecord::Client.apply_results([{
        "mutation_id" => mutation_id,
        "status" => "applied",
        "skipped" => true,
        "version" => 7,
        "server_attributes" => {
          "id" => note.id,
          "title" => "newer server winner",
          "state" => "open",
          "updated_at" => (note.updated_at + 10).utc.iso8601(6)
        }
      }])
    end

    assert_equal "newer server winner", note.reload.title
    assert_equal 0, InstantRecord::OutboxMutation.count

    notice = InstantRecord::SyncNotice.active.sole
    assert notice.conflict?
    assert_equal "update", notice.operation
    assert_equal "Overwritten by a newer server change", notice.reason
    assert_equal "offline losing write", notice.attempted_changes["title"]
    assert_equal "newer server winner", notice.server_attributes["title"]
    assert_equal 7, notice.server_version
  end

  def test_inbound_lww_overwrite_quarantines_pending_row_only_when_no_outbox_row_remains
    note = in_browser { @model.create!(title: "local pending", state: "open") }
    # Still has an outbox row: inbound overwrite should NOT double-record because
    # draining the outbox row will record the skipped conflict with mutation_id.
    in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => note.id, "operation" => "update", "version" => 2,
        "attributes" => {
          "id" => note.id, "title" => "server newer", "state" => "open",
          "updated_at" => (note.updated_at + 5).utc.iso8601(6)
        }
      )
    end
    assert_equal 0, InstantRecord::SyncNotice.count

    # Without an outbox row, overwriting a pending local row quarantines the lost local state.
    InstantRecord::OutboxMutation.delete_all
    note.update_columns(title: "unsent local draft", sync_state: "pending", updated_at: Time.now.utc)
    in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => note.id, "operation" => "update", "version" => 3,
        "attributes" => {
          "id" => note.id, "title" => "server wins again", "state" => "open",
          "updated_at" => (note.updated_at + 10).utc.iso8601(6)
        }
      )
    end

    notice = InstantRecord::SyncNotice.active.sole
    assert notice.conflict?
    assert_equal "unsent local draft", notice.attempted_changes["title"]
    assert_equal "server wins again", notice.server_attributes["title"]
  end

  def test_changes_notice_carries_sync_notice_lines_and_clears_after_notify
    events = []
    sub = ActiveSupport::Notifications.subscribe("notice.instant_record") { |*, payload| events << payload }
    note = in_browser { @model.create!(title: "reject me") }
    mutation_id = InstantRecord::OutboxMutation.sole.id

    in_browser do
      InstantRecord::Client.apply_results([{
        "mutation_id" => mutation_id, "status" => "rejected", "reason" => "nope"
      }])
      InstantRecord::Client.notify_changed
    end

    lines = @notifier.payloads.sole.split("\n")
    assert_equal "records_changed", lines.first
    assert lines.last.start_with?("sync_notice:")
    parsed = JSON.parse(lines.last.delete_prefix("sync_notice:"))
    assert_equal "rejected", parsed["kind"]
    assert_equal "nope", parsed["reason"]
    assert_equal "Note", parsed["record_type"]
    assert_equal "records_changed", InstantRecord::Client.changes_notice, "recorded notices clear after notify_changed"
    assert_equal 1, events.size
    assert_equal "nope", events.first[:reason]
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  def test_retry_reapplies_rejected_create_with_overrides_and_dismisses_notice
    note = in_browser { @model.create!(title: "reject me", state: "open") }
    mutation_id = InstantRecord::OutboxMutation.sole.id

    in_browser do
      InstantRecord::Client.apply_results([{
        "mutation_id" => mutation_id, "status" => "rejected", "reason" => "Title is not allowed"
      }])
    end

    notice = InstantRecord::SyncNotice.active.sole
    retried = in_browser { notice.retry!("title" => "allowed title") }

    assert_equal note.id, retried.id
    assert_equal "allowed title", retried.title
    assert_equal "open", retried.state
    assert_equal "pending", retried.sync_state
    assert_equal 1, InstantRecord::OutboxMutation.count
    refute_equal mutation_id, InstantRecord::OutboxMutation.sole.id
    assert_equal 0, InstantRecord::SyncNotice.active.count
    assert_equal 1, InstantRecord::SyncNotice.count, "dismissed notice stays in ledger non-destructively"
    refute notice.reload.active?
  end

  def test_retry_reapplies_conflict_update_with_fresh_mutation
    note = in_browser { @model.create!(title: "initial", state: "open") }
    InstantRecord::OutboxMutation.delete_all
    in_browser { note.update!(title: "my version") }
    mutation_id = InstantRecord::OutboxMutation.sole.id

    in_browser do
      InstantRecord::Client.apply_results([{
        "mutation_id" => mutation_id, "status" => "applied", "skipped" => true, "version" => 2,
        "server_attributes" => { "id" => note.id, "title" => "their version", "state" => "open",
                                 "updated_at" => (note.updated_at + 5).utc.iso8601(6) }
      }])
    end

    notice = InstantRecord::SyncNotice.active.sole
    in_browser { notice.retry! }

    assert_equal "my version", note.reload.title
    assert_equal "pending", note.sync_state
    assert_equal 1, InstantRecord::OutboxMutation.count
    assert_equal "update", InstantRecord::OutboxMutation.sole.operation
    assert_equal 0, InstantRecord::SyncNotice.active.count

    # Retried mutation carries a timestamp strictly newer than the server winner
    # (even when the server's winning clock was ahead), so MutationApplier accepts it.
    server_applied = on_server do
      InstantRecord::MutationApplier.apply(InstantRecord::OutboxMutation.sole.as_mutation)
    end
    assert_equal "applied", server_applied[:status]
    refute server_applied[:skipped], "retried conflict must beat the old server timestamp"
  end

  def test_fork_creates_new_record_preserving_server_winner_and_base_columns
    note = in_browser { @model.create!(title: "server title", state: "archived", owner: "ada") }
    InstantRecord::OutboxMutation.delete_all
    in_browser { note.update!(title: "my offline title") }
    mutation_id = InstantRecord::OutboxMutation.sole.id

    in_browser do
      InstantRecord::Client.apply_results([{
        "mutation_id" => mutation_id, "status" => "applied", "skipped" => true, "version" => 5,
        "server_attributes" => {
          "id" => note.id, "title" => "server winner", "state" => "archived", "owner" => "ada",
          "updated_at" => (note.updated_at + 5).utc.iso8601(6)
        }
      }])
    end

    notice = InstantRecord::SyncNotice.active.sole
    forked = in_browser { notice.fork! }

    refute_equal note.id, forked.id
    assert_equal "my offline title", forked.title
    assert_equal "archived", forked.state, "fork keeps unchanged server base attributes"
    assert_equal "ada", forked.owner
    assert_equal "pending", forked.sync_state
    assert_equal "server winner", note.reload.title, "winning server record stays untouched"
    assert_equal 1, InstantRecord::OutboxMutation.count
    assert_equal "create", InstantRecord::OutboxMutation.sole.operation
    assert_equal forked.id, InstantRecord::OutboxMutation.sole.record_id
    assert_equal 0, InstantRecord::SyncNotice.active.count
  end

  def test_dismiss_and_resolve_api
    notice = InstantRecord::SyncNotice.record!(
      kind: "rejected", record_type: "Note", record_id: "n-1",
      operation: "create", reason: "nope", attempted_changes: { "title" => "draft" }
    )

    result = InstantRecord.resolve_sync_notice(notice.id, action: "dismiss")
    assert_equal true, result["ok"]
    assert_equal [], result["notices"]
    refute notice.reload.active?

    assert_raises(ArgumentError) { InstantRecord.resolve_sync_notice("missing", action: "dismiss") }
    assert_raises(ArgumentError) { InstantRecord.resolve_sync_notice(notice.id, action: "explode") }
  end

  def test_identity_reset_clears_notices_only_for_reset_types
    InstantRecord::SyncNotice.record!(
      kind: "rejected", record_type: "Secret", record_id: "s-1",
      operation: "create", reason: "not permitted", attempted_changes: { "title" => "private" }
    )
    InstantRecord::SyncNotice.record!(
      kind: "conflict", record_type: "Note", record_id: "n-1",
      operation: "update", reason: "stale", attempted_changes: { "title" => "public" }
    )

    InstantRecord::Client.reset("operation" => "reset", "types" => ["Secret"])

    assert_equal ["Note"], InstantRecord::SyncNotice.pluck(:record_type)
  end

  def test_sync_notices_migration_compiles_for_browser_sqlite
    migration = File.expand_path("../db/migrate/20261121000001_create_instant_record_sync_notices.rb", __dir__)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "db/migrate"))
      FileUtils.cp(migration, File.join(dir, "db/migrate", File.basename(migration)))
      File.write(File.join(dir, "db/schema.rb"), "ActiveRecord::Schema[8.1].define(version: 2026_11_21_000001) do\nend\n")

      plan = InstantRecord::Compiler::BrowserMigrations.plan(root: dir)
      sql = plan["migrations"]["20261121000001"]
      assert sql.any? { |stmt| stmt.include?('CREATE TABLE "instant_record_sync_notices"') }
      assert sql.any? { |stmt| stmt.include?("index_instant_record_sync_notices_on_mutation_id") }
    end
  end
end
