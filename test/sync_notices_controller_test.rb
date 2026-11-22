require "test_helper"
require "rails"
require "action_controller"
require "rack/mock"
require File.expand_path("../app/helpers/instant_record/sync_notices_helper", __dir__)
require File.expand_path("../app/controllers/instant_record/sync_notices_controller", __dir__)

class SyncNoticesControllerTest < Minitest::Test
  def setup
    reset_instant_record_tables!
    @model = syncable_model("Note")
    InstantRecord.sync(@model)
    InstantRecord::SyncNoticesController.prepend_view_path(File.expand_path("../app/views", __dir__))
  end

  def teardown
    InstantRecord.sync
  end

  Reply = Struct.new(:status, :headers, :body) do
    def json = JSON.parse(body)
  end

  def ask(action, method, path: "/instant_record/sync_notices", path_params: {}, body: nil, content_type: nil, accept: "application/json")
    env = Rack::MockRequest.env_for(path, {
      method: method,
      input: body,
      "CONTENT_TYPE" => content_type,
      "HTTP_ACCEPT" => accept
    }.compact)
    env["action_dispatch.request.path_parameters"] = path_params
    status, headers, response_body = InstantRecord::SyncNoticesController.action(action).call(env)
    bytes = +""
    response_body.each { |part| bytes << part }
    response_body.close if response_body.respond_to?(:close)
    Reply.new(status, headers, bytes)
  end

  def test_index_returns_active_notices_as_json_and_html_partial
    notice = InstantRecord::SyncNotice.record!(
      kind: "rejected", record_type: "Note", record_id: "n-1",
      operation: "create", reason: "Title is not allowed",
      attempted_changes: { "title" => "reject me" }
    )

    json_reply = ask(:index, "GET", path: "/instant_record/sync_notices.json")
    assert_equal 200, json_reply.status
    assert_equal true, json_reply.json["ok"]
    assert_equal [notice.id], json_reply.json["notices"].map { |n| n["id"] }

    html_reply = ask(:index, "GET", path: "/instant_record/sync_notices", accept: "text/html")
    assert_equal 200, html_reply.status
    assert_includes html_reply.body, "Title is not allowed"
    assert_includes html_reply.body, %(action="/instant_record/sync_notices/#{notice.id}/retry")
  end

  def test_retry_fork_and_dismiss_via_json_and_html
    note = in_browser { @model.create!(title: "server winner", state: "open") }
    InstantRecord::OutboxMutation.delete_all

    n1 = InstantRecord::SyncNotice.record!(
      kind: "conflict", record_type: "Note", record_id: note.id,
      operation: "update", reason: "stale",
      attempted_changes: { "title" => "local draft" },
      server_attributes: { "id" => note.id, "title" => "server winner", "state" => "open" }
    )
    n2 = InstantRecord::SyncNotice.record!(
      kind: "rejected", record_type: "Note", record_id: "n-missing",
      operation: "create", reason: "nope",
      attempted_changes: { "title" => "reject me", "state" => "open" }
    )

    in_browser do
      fork_reply = ask(:fork, "POST",
        path: "/instant_record/sync_notices/#{n1.id}/fork.json",
        path_params: { id: n1.id },
        body: JSON.generate(overrides: { title: "forked title" }),
        content_type: "application/json")
      assert_equal 200, fork_reply.status
      assert_equal true, fork_reply.json["ok"]
      forked = @model.find(fork_reply.json["record_id"])
      assert_equal "forked title", forked.title
      assert_equal "server winner", note.reload.title

      retry_reply = ask(:retry, "POST",
        path: "/instant_record/sync_notices/#{n2.id}/retry",
        path_params: { id: n2.id },
        body: "overrides[title]=fixed+title&return_to=%2Ftodo",
        content_type: "application/x-www-form-urlencoded",
        accept: "text/html")
      assert_equal 303, retry_reply.status
      assert_equal "http://example.org/todo", retry_reply.headers["location"]
      assert_equal "fixed title", @model.find("n-missing").title
    end

    n3 = InstantRecord::SyncNotice.record!(
      kind: "rejected", record_type: "Note", record_id: "n-3",
      operation: "create", reason: "bad", attempted_changes: { "title" => "x" }
    )
    dismiss_reply = ask(:dismiss, "POST",
      path: "/instant_record/sync_notices/#{n3.id}/dismiss.json",
      path_params: { id: n3.id })
    assert_equal 200, dismiss_reply.status
    assert_equal [], dismiss_reply.json["notices"]
    refute n3.reload.active?

    missing_reply = ask(:dismiss, "POST",
      path: "/instant_record/sync_notices/nope/dismiss.json",
      path_params: { id: "nope" })
    assert_equal 422, missing_reply.status
    assert_equal false, missing_reply.json["ok"]
  end

  def test_unsafe_return_to_falls_back_to_root
    notice = InstantRecord::SyncNotice.record!(
      kind: "rejected", record_type: "Note", record_id: "n-4",
      operation: "create", reason: "bad", attempted_changes: { "title" => "x" }
    )
    reply = ask(:dismiss, "POST",
      path: "/instant_record/sync_notices/#{notice.id}/dismiss",
      path_params: { id: notice.id },
      body: "return_to=//evil.example/phish",
      content_type: "application/x-www-form-urlencoded",
      accept: "text/html")
    assert_equal 303, reply.status
    assert_equal "http://example.org/", reply.headers["location"]
  end
end
