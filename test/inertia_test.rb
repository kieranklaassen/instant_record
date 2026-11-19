require "test_helper"
require "instant_record/inertia"

class InertiaTest < ActiveSupport::TestCase
  test "live props name one event per model on the local channel" do
    issue = Class.new { def self.name = "Issue" }
    live = InstantRecord::Inertia.live_props(mail: issue, counts: [issue, "Comment"])

    assert_equal %i[mail counts], live.keys
    assert_equal [{ channel: { name: "instant_record", type: "local" }, events: ["Issue"] }], live[:mail][:listeners]
    assert_equal %w[Issue Comment], live[:counts][:listeners].first[:events]
    assert_equal 150, live[:mail][:throttle]
  end
end
