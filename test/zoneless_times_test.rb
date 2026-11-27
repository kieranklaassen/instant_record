require "test_helper"

# A compiled model's attributes hold a time as its column stores it: UTC, with no
# zone written. Such a time gets into snapshots and queued mutations, and the client
# reads it back on a machine in any zone. CRuby's own attributes always carry a zone,
# so these tests put the compiled form in by hand.
class ZonelessTimesTest < Minitest::Test
  ZONES = %w[UTC America/Los_Angeles Europe/Amsterdam Asia/Kolkata Pacific/Kiritimati].freeze

  # An ordinary time, then times written the way a local clock skips or repeats them
  # when Los Angeles and Amsterdam change theirs.
  TIMES = [
    Time.utc(2026, 7, 1, 12, 0, 0, 250_000),
    Time.utc(2026, 3, 8, 2, 30),
    Time.utc(2026, 11, 1, 1, 30),
    Time.utc(2026, 3, 29, 2, 30),
    Time.utc(2026, 10, 25, 2, 30)
  ].freeze

  class SilentNotifier
    def records_changed = nil
  end

  def setup
    @model = syncable_model("Note")
    InstantRecord.sync(@model)
    InstantRecord::Client.notifier = SilentNotifier.new
    reset_instant_record_tables!
  end

  def teardown
    InstantRecord.sync
    InstantRecord::Client.notifier = nil
  end

  def test_a_row_with_a_pending_edit_takes_only_a_newer_server_change
    each_zone_and_time do |at, label, id|
      { "newer" => 1800, "older" => -1800 }.each do |age, seconds|
        { "no clock" => false, "a clock" => true }.each do |clocked, clock|
          row = "#{id}-#{age}-#{clock}"
          note = seed(row, at)
          in_browser { note.update!(state: "closed") }
          write_snapshot_without_zones(row)

          in_browser { InstantRecord::Client.apply_change(change(row, at + seconds, "server", 2, clock: clock)) }

          expected = age == "newer" ? "server" : "first"
          assert_equal [expected, "closed"], [note.reload.title, note.state], "#{label}: #{age} change with #{clocked}"
        end
      end
    end
  end

  def test_a_clean_row_takes_only_a_newer_server_change_whose_time_has_no_zone
    each_zone_and_time do |at, label, id|
      { "newer" => 1800, "older" => -1800 }.each do |age, seconds|
        row = "#{id}-#{age}"
        note = seed(row, at)
        event = change(row, at + seconds, "server", 2)
        event["attributes"]["updated_at"] = stored(at + seconds)

        in_browser { InstantRecord::Client.apply_change(event) }

        assert_equal (age == "newer" ? "server" : "first"), note.reload.title, "#{label}: #{age} change"
      end
    end
  end

  def test_an_acknowledged_edit_does_not_rewind_a_newer_confirmed_time
    each_zone_and_time do |at, label, id|
      note = seed(id, at)
      in_browser { note.update!(state: "closed") }
      mutation = InstantRecord::OutboxMutation.ordered.last
      changes = mutation.changes_payload.merge("updated_at" => stored(at + 60))
      snapshot = InstantRecord::Client::Rebaser.confirmed_snapshot("Note", id)
      advanced = advance(snapshot, mutation, changes)

      assert_equal stored(at + 60), advanced["attributes"]["updated_at"], "#{label}: a later edit moves the time"

      snapshot["attributes"]["updated_at"] = (at + 120).iso8601(6)
      advanced = advance(snapshot, mutation, changes)

      assert_equal (at + 120).iso8601(6), advanced["attributes"]["updated_at"], "#{label}: an earlier edit does not"
    end
  end

  def test_a_rejected_action_restores_the_time_the_row_had
    each_zone_and_time do |at, label, id|
      note = seed(id, at)
      before = InstantRecord.snapshot_attributes(note.attributes).merge("created_at" => stored(at), "updated_at" => stored(at))
      note.update_columns(title: "guess", updated_at: at + 60)
      mutation = InstantRecord::OutboxMutation.create!(
        record_type: "Note", record_id: id, operation: "mutator",
        changes_payload: { "mutator" => "Note.guess", "args" => {}, "touched" => [{ "type" => "Note", "id" => id, "op" => "update", "before" => before }] }
      )

      in_browser do
        InstantRecord::Client.apply_results([{ "mutation_id" => mutation.id, "status" => "rejected", "reason" => "no", "records" => [] }])
      end

      assert_equal ["first", at], [note.reload.title, note.updated_at.to_time.utc], label
    end
  end

  def test_a_branch_edit_is_stale_only_when_the_row_is_newer
    each_zone_and_time do |at, label, id|
      { "newer" => 1800, "older" => -1800 }.each do |age, seconds|
        row = "#{id}-#{age}"
        note = seed(row, at)
        replayed = in_browser do
          InstantRecord::Branch.replay_mutations([
            { "id" => "m-#{row}", "record_type" => "Note", "record_id" => row, "operation" => "update",
              "changes" => { "title" => "branch", "updated_at" => stored(at + seconds) } }
          ])
        end

        assert_equal (age == "newer" ? 1 : 0), replayed["applied"], "#{label}: #{age} edit"
        assert_equal (age == "newer" ? "branch" : "first"), note.reload.title, "#{label}: #{age} edit"
      end
    end
  end

  def test_a_replayed_branch_edit_keeps_the_time_it_was_made
    each_zone_and_time do |at, label, id|
      reset_instant_record_tables!
      in_browser do
        InstantRecord::Branch.replay_mutations([
          { "id" => "m-#{id}", "record_type" => "Note", "record_id" => id, "operation" => "create",
            "created_at" => stored(at), "changes" => { "title" => "branch" } }
        ])
      end

      assert_equal at, InstantRecord::OutboxMutation.find("m-#{id}").created_at.to_time.utc, label
    end
  end

  def test_a_time_that_names_its_zone_is_read_in_that_zone
    each_zone_and_time do |at, label, id|
      note = seed(id, at)
      event = change(id, at, "server", 2)
      event["attributes"]["updated_at"] = (at + 1800).getlocal("+05:30").iso8601(6)

      in_browser { InstantRecord::Client.apply_change(event) }
      assert_equal "server", note.reload.title, label

      event["attributes"].merge!("title" => "late", "updated_at" => (at + 900).getlocal("-08:00").iso8601(6))
      in_browser { InstantRecord::Client.apply_change(event) }
      assert_equal "server", note.reload.title, label
    end
  end

  private

  def each_zone_and_time
    zone_before = ENV["TZ"]
    ZONES.each do |zone|
      ENV["TZ"] = zone
      TIMES.each_with_index { |at, index| yield at, "#{zone} at #{stored(at)}", "#{zone.tr("/", "-")}-#{index}" }
    end
  ensure
    ENV["TZ"] = zone_before
  end

  # The text a datetime(6) column holds.
  def stored(time) = time.strftime("%Y-%m-%d %H:%M:%S.%6N")

  def change(id, at, title, version, clock: false)
    event = {
      "type" => "Note", "id" => id, "operation" => version == 1 ? "create" : "update", "version" => version,
      "attributes" => {
        "id" => id, "title" => title, "state" => "open", "owner" => "alice",
        "created_at" => at.iso8601(6), "updated_at" => at.iso8601(6)
      }
    }
    event["hlc"] = InstantRecord::HLC.from_time(at, node: InstantRecord::HLC::SERVER_NODE) if clock
    event
  end

  # A row the server sent with no clock.
  def seed(id, at)
    in_browser { InstantRecord::Client.apply_change(change(id, at, "first", 1)) }
    @model.find(id)
  end

  def write_snapshot_without_zones(id)
    rebaser = InstantRecord::Client::Rebaser
    snapshot = rebaser.confirmed_snapshot("Note", id)
    %w[attributes initial_attributes].each do |part|
      %w[created_at updated_at].each { |column| snapshot[part][column] = stored(Time.parse(snapshot[part][column]).utc) }
    end
    rebaser.send(:write_confirmed_snapshot, "Note", id, snapshot)
  end

  def advance(snapshot, mutation, changes)
    mutation.changes_payload = changes
    InstantRecord::Client::Rebaser.send(:advance_confirmed_snapshot, snapshot, mutation, 2, @model)
  end
end
