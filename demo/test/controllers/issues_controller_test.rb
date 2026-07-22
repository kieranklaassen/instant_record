require "test_helper"

class IssuesControllerTest < ActionDispatch::IntegrationTest
  test "index renders and the server_only filter runs in the server runtime" do
    issue = Issue.new(title: "visible", state: "open")
    issue.id = SecureRandom.uuid
    issue.save!

    get issues_url

    assert_response :success
    assert_includes response.body, "visible"
    assert_equal "server", response.headers["x-instant-record-runtime"],
      "server_only before_action must run in the server runtime"
  end
end
