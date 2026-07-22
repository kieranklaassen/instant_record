require "test_helper"

module Todo
  class IssuesControllerTest < ActionDispatch::IntegrationTest
    test "index renders and the server_only filter runs in the server runtime" do
      Issue.create!(title: "visible", state: "open")

      get todo_root_url

      assert_response :success
      assert_includes response.body, "visible"
      assert_equal "server", response.headers["x-instant-record-runtime"],
        "server_only before_action must run in the server runtime"
    end

    test "create persists and redirects back to the todo demo" do
      post todo_issues_url, params: { issue: { title: "new issue" } }

      assert_redirected_to todo_root_path
      assert Issue.exists?(title: "new issue")
    end

    test "update toggles done state" do
      issue = Issue.create!(title: "toggle me", state: "open")

      patch todo_issue_url(issue)

      assert_redirected_to todo_root_path
      assert_equal "done", issue.reload.state
    end

    test "destroy removes the issue" do
      issue = Issue.create!(title: "doomed", state: "open")

      delete todo_issue_url(issue)

      assert_redirected_to todo_root_path
      refute Issue.exists?(issue.id)
    end

    test "server rejects the server-only forbidden title" do
      assert_raises(ActiveRecord::RecordInvalid) do
        Issue.create!(title: "reject me", state: "open")
      end
    end

    test "root route still resolves after the move" do
      get root_url

      assert_response :success
    end
  end
end
