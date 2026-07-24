require "test_helper"

# The claim Demo 03 makes: a migration applied to a local database that already
# holds rows AND undrained outbox mutations loses neither.
#
# Runs in the server runtime against Postgres. PGlite is Postgres compiled to
# wasm and takes the same DDL, but that is inference, not what these tests
# measure. The browser needs a ~5 minute wasm rebuild to check.
class ReleaseTest < ActiveSupport::TestCase
  setup { @verbose_was, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false }

  # DDL is transactional in Postgres, so the ALTER TABLE rolls back with the
  # test — but Note's cached column list does not. Put it back by hand or every
  # later test in this process believes word_count exists.
  teardown do
    Note.reset_column_information
    ActiveRecord::Migration.verbose = @verbose_was
  end

  # Without a reversal the page is one-shot: the first visitor ships and everyone
  # after them arrives to a migration already applied, with nothing left to watch.
  test "rolling back puts the database on v1 with the rows untouched, so the demo can run twice" do
    note = as_browser { Note.create!(title: "kept", body: "four words right here") }
    written_at = note.reload.updated_at

    Release.ship
    assert_includes Release.local_columns, Release::COLUMN
    assert_equal 4, note.reload.word_count

    Release.roll_back

    assert Release.pending?, "v1 has to be pending again or Ship v2 cannot be offered"
    refute_includes Release.local_columns, Release::COLUMN
    assert_equal 1, Note.count, "a rollback must not take rows with it"
    assert_equal "kept", note.reload.title
    assert_equal written_at, note.updated_at, "rolling back must not restamp a row"

    # And forward again, which is the whole reason for the reversal.
    Release.ship
    assert_equal 4, note.reload.word_count, "the backfill has to run again on the second ship"
  end

  test "v2 is pending: boot never runs it, and schema.rb never records it" do
    assert Release.pending?,
      "the v2 migration must stay outside config.paths['db/migrate'] so it is still pending at render time"
    refute_includes Release.local_columns, Release::COLUMN
    refute_includes ActiveRecord::Base.connection_pool.migration_context.migrations.map(&:version), Release.version,
      "the default migration path must not contain v2, or prepare_all would apply it at boot"
  end

  test "shipping v2 keeps every row, backfills the new column, and leaves the outbox alone" do
    as_browser do
      Note.create!(title: "one", body: "three words here")
      Note.create!(title: "two", body: "two words")
      Note.create!(title: "three", body: "")

      rows_before = Note.count
      pending_before = InstantRecord.pending_count
      payloads_before = InstantRecord::OutboxMutation.ordered.map { |m| [m.id, m.changes_payload] }

      assert_equal 3, rows_before
      assert_equal 3, pending_before, "each local write must have queued a mutation"

      Release.ship

      assert_equal rows_before, Note.count, "no row may be lost to the migration"
      assert_equal pending_before, InstantRecord.pending_count,
        "the migration must neither drop queued mutations nor enqueue new ones"
      assert_equal payloads_before, InstantRecord::OutboxMutation.ordered.map { |m| [m.id, m.changes_payload] },
        "queued mutations must survive unchanged, not be rewritten by the backfill"

      assert_includes Release.local_columns, Release::COLUMN
      assert_equal({ "one" => 3, "two" => 2, "three" => 0 },
        Note.pluck(:title, Release::COLUMN).to_h,
        "existing rows must gain a value derived from data that was already there")
      refute Release.pending?
    end
  end

  test "the backfill records no outbox mutation even though Note is syncable" do
    as_browser do
      Note.create!(title: "queued", body: "one two")
      InstantRecord::OutboxMutation.delete_all   # start the migration from an empty queue

      assert_no_difference -> { InstantRecord::OutboxMutation.count } do
        Release.ship
      end
    end
  end

  test "rows written before v2 keep their timestamps and their unsynced state" do
    as_browser do
      note = Note.create!(title: "early", body: "a b c")
      written_at = note.created_at

      Release.ship

      note.reload
      assert_equal written_at, note.created_at, "the page uses created_at as evidence the row is the original"
      assert_equal "pending", note.sync_state, "an unsynced row must not be marked synced by a migration"
    end
  end

  test "shipping twice is a no-op" do
    as_browser do
      Note.create!(title: "one", body: "one")
      Release.ship

      assert_no_difference ["Note.count", "InstantRecord::OutboxMutation.count"] do
        Release.ship
      end
      assert_equal 1, Note.sole.word_count
    end
  end

  test "a note written after v2 counts its own words" do
    Release.ship
    Note.create!(title: "after", body: "four little words here")

    assert_equal 4, Note.find_by!(title: "after").word_count
  end

  # The edge, pinned so it stays documented rather than discovered. Shipping v2
  # in the browser leaves the client one migration ahead of the sync server, and
  # MutationApplier assigns a mutation's payload straight onto the model. A
  # column the server has never heard of used to raise: the whole batch 500d, the
  # client kept the outbox row on the transport error, and it retried the same
  # mutation forever — one write blocking every write queued behind it.
  #
  # It is a rejection now. The write is still lost (there is no schema
  # negotiation in this protocol, and the deploy order — server first, client
  # second — is the whole defence), but it is lost loudly and once: the client
  # rolls its local record back and the queue keeps draining. Said as plainly on
  # the page.
  test "a v2-shaped mutation is rejected by a v1 server instead of jamming the outbox" do
    refute_includes Release.local_columns, Release::COLUMN, "this test needs a v1 server"
    record_id = SecureRandom.uuid

    result = InstantRecord::MutationApplier.apply({
      id: "shipped-ahead",
      record_type: "Note",
      record_id: record_id,
      operation: "create",
      changes: { "title" => "written after v2", "body" => "a b", Release::COLUMN => 2 }
    })

    assert_equal "rejected", result[:status]
    assert_match(/#{Release::COLUMN}/, result[:reason], "the client is told which column the server lacks")
    refute Note.exists?(record_id), "nothing partial may be stored"

    # The client retries the mutation id it never got an answer for; the
    # idempotency ledger answers with the same rejection rather than re-raising.
    replay = InstantRecord::MutationApplier.apply({
      id: "shipped-ahead",
      record_type: "Note",
      record_id: record_id,
      operation: "create",
      changes: { "title" => "written after v2", "body" => "a b", Release::COLUMN => 2 }
    })
    assert_equal result, replay
  end

  private

  # Local writes only record outbox mutations in the browser runtime
  # (InstantRecord::Syncable guards on it at call time), and undrained
  # mutations are half of what this demo claims to preserve — so the queue has
  # to be produced the real way, not hand-written.
  def as_browser
    [Note, Release].each(&:name)   # load the classes before the runtime moves under them

    InstantRecord.singleton_class.class_eval do
      alias_method :original_browser?, :browser?
      define_method(:browser?) { true }
    end

    yield
  ensure
    InstantRecord.singleton_class.class_eval do
      remove_method :browser?
      alias_method :browser?, :original_browser?
      remove_method :original_browser?
    end
  end
end
