require "test_helper"
require "instant_record/inertia"

class InertiaTest < ActiveSupport::TestCase
  FakeRequest = Struct.new(:fullpath, :headers, keyword_init: true)

  test "live props name one event per model on the local channel" do
    issue = Class.new { def self.name = "Issue" }
    live = InstantRecord::Inertia.live_props(mail: issue, counts: [issue, "Comment"])

    assert_equal %i[mail counts], live.keys
    assert_equal [{ channel: { name: "instant_record", type: "local" }, events: ["Issue"] }], live[:mail][:listeners]
    assert_equal %w[Issue Comment], live[:counts][:listeners].first[:events]
    assert_equal 150, live[:mail][:throttle]
  end

  test "Page builds a full Inertia response with typed props and liveProps matching live_props" do
    req = FakeRequest.new(fullpath: "/email?member=maya&inbox=support", headers: {})
    page = InstantRecord::Inertia::Page.for_request("Email/Inbox", req)
    page.string("member", "maya")
    page.int("count", 3)
    page.bool("composing", false)
    page.strings("inboxes", %w[support billing])
    page.raw("meta", '{"ok":true}')
    page.lazy("people") { '[["maya","support"]]' }
    page.live("mail", "MailEntry") { '{"rows":[]}' }
    page.live_many("counts", %w[MailEntry Issue]) { '{"total":3}' }

    refute page.inertia?
    refute page.partial?

    parsed = JSON.parse(page.json)
    assert_equal "Email/Inbox", parsed["component"]
    assert_equal "/email?member=maya&inbox=support", parsed["url"]
    assert_equal "", parsed["version"]
    assert_equal(
      {
        "errors" => {},
        "member" => "maya",
        "count" => 3,
        "composing" => false,
        "inboxes" => %w[support billing],
        "meta" => { "ok" => true },
        "people" => [["maya", "support"]],
        "mail" => { "rows" => [] },
        "counts" => { "total" => 3 }
      },
      parsed["props"]
    )
    assert_equal(
      InstantRecord::Inertia.live_props(mail: "MailEntry", counts: %w[MailEntry Issue]).as_json,
      parsed["liveProps"]
    )
  end

  test "Page honors X-Inertia-Partial-Component, Partial-Data, and Partial-Except without running skipped blocks" do
    req = FakeRequest.new(
      fullpath: "/email?member=maya&inbox=support",
      headers: {
        "X-Inertia" => "true",
        "X-Inertia-Partial-Component" => "Email/Inbox",
        "X-Inertia-Partial-Data" => "mail, counts",
        "X-Inertia-Partial-Except" => "counts"
      }
    )
    page = InstantRecord::Inertia::Page.for_request("Email/Inbox", req)
    assert page.inertia?
    assert page.partial?

    evaluated = []
    page.string("member", "maya")
    page.lazy("people") { evaluated << "people"; "[]" }
    page.live("mail", "MailEntry") { evaluated << "mail"; '{"rows":[1]}' }
    page.live("thread", "MailEntry") { evaluated << "thread"; '{"id":"t1"}' }
    page.live("counts", "MailEntry") { evaluated << "counts"; "5" }
    page.always_raw("flash", '{"notice":"saved"}')

    assert_equal ["mail"], evaluated
    parsed = JSON.parse(page.json)
    assert_equal %w[errors flash mail], parsed["props"].keys.sort
    assert_equal({ "rows" => [1] }, parsed["props"]["mail"])
    assert_equal({ "notice" => "saved" }, parsed["props"]["flash"])
    assert_equal %w[mail thread counts], parsed["liveProps"].keys
  end

  test "Page ignores partial headers when X-Inertia-Partial-Component does not match" do
    req = FakeRequest.new(
      fullpath: "/email",
      headers: {
        "X-Inertia" => "true",
        "X-Inertia-Partial-Component" => "Other/Page",
        "X-Inertia-Partial-Data" => "mail"
      }
    )
    page = InstantRecord::Inertia::Page.for_request("Email/Inbox", req)
    assert page.inertia?
    refute page.partial?

    page.string("member", "maya")
    page.live("thread", "MailEntry") { '{"id":"t1"}' }

    parsed = JSON.parse(page.json)
    assert_equal %w[errors member thread], parsed["props"].keys.sort
  end

  test "Page escapes control characters, quotes, and backslashes in JSON strings and omits empty liveProps" do
    page = InstantRecord::Inertia::Page.for_request("Test/View", nil, version: "v1")
    page.string("text", "a\"b\\c\nd\re\tf\u0001")

    parsed = JSON.parse(page.json)
    assert_equal "/", parsed["url"]
    assert_equal "v1", parsed["version"]
    assert_equal "a\"b\\c\nd\re\tf\u0001", parsed["props"]["text"]
    refute parsed.key?("liveProps")
  end
end
