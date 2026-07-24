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
end
