require "test_helper"
require "action_controller"
require File.expand_path("../app/controllers/instant_record/events_controller", __dir__)

# The SSE stream's idle behaviour: heartbeats on a quiet stream, and a client
# hang-up as a normal end rather than an exception.
class EventStreamTest < Minitest::Test
  Stream = InstantRecord::EventsController::EventStream

  def test_quiet_stream_writes_heartbeat_comments
    stream = Stream.new(cursor: InstantRecord::Change.maximum(:id).to_i, deadline: Time.current + 0.1, heartbeat: 0.01)

    chunks = []
    stream.each { |chunk| chunks << chunk }

    assert_includes chunks, ": hb\n\n"
    assert(chunks.all? { |c| c.start_with?(":") }, "a quiet stream must write nothing but comments")
  end

  def test_zero_heartbeat_disables_comments
    stream = Stream.new(cursor: InstantRecord::Change.maximum(:id).to_i, deadline: Time.current + 0.1, heartbeat: 0)

    chunks = []
    stream.each { |chunk| chunks << chunk }

    assert_empty chunks
  end

  def test_client_hangup_ends_the_stream_quietly
    stream = Stream.new(cursor: InstantRecord::Change.maximum(:id).to_i, deadline: Time.current + 5, heartbeat: 0.01)

    # A dead peer surfaces as EPIPE on the write (the yield). That is the
    # stream's normal end, so nothing may escape.
    stream.each { raise Errno::EPIPE }
  end

  def test_parser_skips_comment_blocks
    events = []
    parser = InstantRecord::Client::Transport::SseParser.new { |event| events << event }

    parser.feed(": hb\n\n")
    parser.feed("id: 5\nevent: change\ndata: {\"type\":\"Item\"}\n\n: hb\n\n")

    assert_equal [{ "type" => "Item", "cursor" => 5 }], events
  end

  def test_event_stream_headers_forbid_public_or_shared_caching
    cache_control = InstantRecord::EventsController::EVENT_STREAM_HEADERS["cache-control"]
    assert_equal "no-store", cache_control
    refute_match(/public|s-maxage/i, cache_control)
    assert_equal "text/event-stream", InstantRecord::EventsController::EVENT_STREAM_HEADERS["content-type"]
    assert_equal "no", InstantRecord::EventsController::EVENT_STREAM_HEADERS["x-accel-buffering"]
  end

  def test_event_stream_isolates_per_user_scoped_changes
    reset_instant_record_tables!
    model = scoped_model("EventScopedItem")
    previous_synced = InstantRecord.synced_models.dup
    InstantRecord.sync(model)

    cursor_before = InstantRecord::Change.maximum(:id).to_i
    alice_note = model.create!(title: "Alice secret", state: "alice")
    bob_note = model.create!(title: "Bob secret", state: "bob")
    public_note = model.create!(title: "Shared note", state: "public")

    alice_chunks = []
    Stream.new(cursor: cursor_before, deadline: Time.current, heartbeat: 0, identity: Person.new("alice")).each { |chunk| alice_chunks << chunk }

    bob_chunks = []
    Stream.new(cursor: cursor_before, deadline: Time.current, heartbeat: 0, identity: Person.new("bob")).each { |chunk| bob_chunks << chunk }

    alice_events = []
    InstantRecord::Client::Transport::SseParser.new { |event| alice_events << event }.feed(alice_chunks.join)
    bob_events = []
    InstantRecord::Client::Transport::SseParser.new { |event| bob_events << event }.feed(bob_chunks.join)

    alice_visible = alice_events.reject { |e| e["operation"] == "destroy" }.map { |e| e["id"] }
    bob_visible = bob_events.reject { |e| e["operation"] == "destroy" }.map { |e| e["id"] }
    assert_equal [alice_note.id, public_note.id], alice_visible
    assert_equal [bob_note.id, public_note.id], bob_visible
    refute_includes alice_chunks.join, "Bob secret"
    refute_includes bob_chunks.join, "Alice secret"
  ensure
    InstantRecord.sync(previous_synced) if previous_synced
  end

  def test_every_event_is_its_payload_then_the_time_it_was_written
    reset_instant_record_tables!
    title = "<b>&\u2028\u2029 caf\u00e9 \u{1F331}"
    payload = { "title" => title, "ratio" => 1.5e-7, "big" => 2**70, "nested" => { "a" => [1, nil, true, { "b" => "" }] } }
    stamp = "2026-11-26T00:00:00.000000Z-0000-00000000"
    stamped = log("Item", "i-1", "update", 3, payload)
    InstantRecord::SyncMetadata.set("#{InstantRecord::HLC::CHANGE_PREFIX}#{stamped.id}", stamp)
    bare = log("Missing::Type", "i-2", "destroy", 4, nil)
    ticks = 0
    clock = -> { Time.utc(2026, 11, 26, 0, 0, ticks += 1) }

    chunks = []
    InstantRecord::HLC.with_clock(clock) do
      Stream.new(cursor: 0, deadline: Time.current, heartbeat: 0).each { |chunk| chunks << chunk }
    end

    first = { type: "Item", id: "i-1", operation: "update", version: 3, attributes: payload, hlc: stamp,
              server_time: "2026-11-26T00:00:01.000000Z" }
    second = { type: "Missing::Type", id: "i-2", operation: "destroy", version: 4, attributes: nil,
               server_time: "2026-11-26T00:00:02.000000Z" }
    assert_equal ["id: #{stamped.id}\nevent: change\ndata: #{first.to_json}\n\n",
                  "id: #{bare.id}\nevent: change\ndata: #{second.to_json}\n\n"], chunks
    assert_includes chunks.first, '\u003cb\u003e\u0026\u2028\u2029'
  end

  def test_the_cursor_moves_as_each_event_is_written
    reset_instant_record_tables!
    ids = Array.new(3) { |i| log("Item", "i-#{i}", "update", i, {}).id }
    stream = Stream.new(cursor: 0, deadline: Time.current, heartbeat: 0)
    cursors = []

    stream.each do
      cursors << stream.instance_variable_get(:@cursor)
      raise Errno::EPIPE if cursors.size == 2
    end

    assert_equal ids.first(2), cursors
  end

  def test_a_rule_that_appears_between_polls_decides_the_next_one
    reset_instant_record_tables!
    previous_synced = InstantRecord.synced_models.dup
    open_model = syncable_model("Shifting")
    ruled_model = scoped_model("Shifting")
    log("Shifting", "i-1", "update", 1, { "title" => "secret" })
    changes = InstantRecord::Change.order(:id).to_a

    InstantRecord.sync(open_model)
    open_event = InstantRecord::SyncScope.events_for(changes, nil).first.last
    InstantRecord.sync(ruled_model)
    ruled_event = InstantRecord::SyncScope.events_for(changes, nil).first.last

    assert_equal({ "title" => "secret" }, open_event[:attributes])
    assert_equal({ type: "Shifting", id: "i-1", operation: "destroy", version: 0, attributes: {} }, ruled_event)
  ensure
    InstantRecord.sync(previous_synced) if previous_synced
  end

  private

  def log(type, id, operation, version, attributes)
    InstantRecord::Change.create!(record_type: type, record_id: id, operation: operation, version: version,
                                  attributes_payload: attributes)
  end
end
