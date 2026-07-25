require "test_helper"

# Transport double local to this file so it runs standalone under
# `ruby -Itest test/instrumentation_test.rb` (rake loads all files, order unknown).
class InstrumentationTransport
  attr_accessor :results_to_return, :fail_posts

  def initialize
    @results_to_return = []
    @events = []
  end

  def post_json(_path, payload)
    raise InstantRecord::Client::Transport::Error, "offline" if fail_posts

    mutations = payload[:mutations]
    { "results" => @results_to_return.presence || mutations.map { |m| { "mutation_id" => m[:id], "status" => "applied", "version" => 1 } } }
  end

  def get_json(_path) = { "cursor" => 0, "records" => [] }
  def each_event(_path) = nil
end

class InstrumentationTest < Minitest::Test
  def setup
    @model = syncable_model("Gauge")
    InstantRecord.sync(@model)
    @transport = InstrumentationTransport.new
    InstantRecord::Client.transport = @transport
    reset_instant_record_tables!
    @events = []
    @subscription = ActiveSupport::Notifications.subscribe(/\.instant_record\z/) do |name, _s, _f, _id, payload|
      @events << [name, payload]
    end
  end

  def teardown
    ActiveSupport::Notifications.unsubscribe(@subscription)
    InstantRecord.sync
    InstantRecord::Client.transport = nil
  end

  def test_drain_announces_what_the_pass_did
    in_browser do
      @model.create!(title: "observed")
      InstantRecord::Client.drain
    end

    name, payload = @events.find { |n, _| n == "drain.instant_record" }
    assert name, "drain must instrument"
    assert_equal 1, payload[:posted]
    assert_equal 0, payload[:rejected]
  end

  def test_drain_carries_rejection_reasons
    in_browser do
      @model.create!(title: "doomed")
      mutation_id = InstantRecord::OutboxMutation.sole.id
      @transport.results_to_return = [
        { "mutation_id" => mutation_id, "status" => "rejected", "reason" => "Title is too long" }
      ]

      InstantRecord::Client.drain
    end

    _, payload = @events.find { |n, _| n == "drain.instant_record" }
    assert_equal 1, payload[:rejected]
    assert_equal ["Title is too long"], payload[:reasons]
  end

  def test_transport_failure_announces_offline_with_the_phase
    in_browser do
      @model.create!(title: "stranded")
      @transport.fail_posts = true

      capture_io { InstantRecord::Client.drain }
    end

    _, payload = @events.find { |n, _| n == "offline.instant_record" }
    assert_equal "drain", payload[:phase]
    assert_equal "offline", payload[:error]
  end

  def test_forwarder_shapes_entries_the_inspector_already_renders
    entry = InstantRecord::Client::Instrumentation.send(:entry_for, "drain",
      { posted: 3, rejected: 1, reasons: ["Body is too long"] }, 12)
    assert_equal "sync-pass", entry[:kind]
    assert_equal "drained 3, 1 rejected: Body is too long", entry[:path]
    assert_equal 12, entry[:ms]

    assert_nil InstantRecord::Client::Instrumentation.send(:entry_for, "poll", { applied: 0 }, 1),
      "an empty poll is not news"

    entry = InstantRecord::Client::Instrumentation.send(:entry_for, "fetch_history",
      { applied: 50, has_more: false }, 40)
    assert_equal "history", entry[:kind]
    assert_includes entry[:path], "(beginning)"

    entry = InstantRecord::Client::Instrumentation.send(:entry_for, "offline", { phase: "drain" }, 0)
    assert_equal "offline", entry[:status]
  end
end
