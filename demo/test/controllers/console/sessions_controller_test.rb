require "test_helper"

module Console
  class SessionsControllerTest < ActionDispatch::IntegrationTest
    test "index renders the prompt and the runnable snippets" do
      get console_root_url

      assert_response :success
      assert_includes response.body, console_eval_path
      SessionsController::SNIPPETS.each do |snippet|
        assert_includes response.body, ERB::Util.html_escape(snippet)
      end
    end

    # The security boundary. This is the claim the feature rests on, so it is
    # asserted against the thing an attacker would actually send.
    test "the server runtime never evaluates the code it is sent" do
      assert_no_difference "Issue.count" do
        post console_eval_url, params: { code: %(Issue.create!(title: "pwned by eval")) }
      end

      assert_response :success
      assert_includes response.body, "Not evaluated"
      refute Issue.exists?(title: "pwned by eval")
    end

    test "the server runtime refuses even a harmless expression" do
      post console_eval_url, params: { code: "1 + 1" }

      assert_response :success
      assert_includes response.body, "Not evaluated"
      refute_includes response.body, "=&gt;</span><code>2</code>",
        "the server must not evaluate anything, however innocent"
    end

    # Why the boundary is absence rather than a guard: the evaluating #create is
    # defined inside a browser_only block, and on the server that block is never
    # class_eval'd, so the method does not exist to be reached.
    test "browser_only blocks define nothing in the server runtime" do
      probe = Class.new { extend InstantRecord::RuntimeScoped }
      probe.browser_only { def evaluates_ruby = true }
      probe.server_only { def refuses_instead = true }

      refute probe.new.respond_to?(:evaluates_ruby),
        "browser_only must not define methods on the server — the console's eval lives in one"
      assert probe.new.respond_to?(:refuses_instead)
    end

    # The browser runtime can't be exercised from here, but the binding the browser
    # evaluates against is plain Ruby, so its behaviour can be. Evaluating a
    # literal written in this test is not the thing the server refuses to do —
    # that is evaluating a string that arrived in a request.
    test "the session binding keeps locals and resolves the app's constants" do
      binding = SessionsController::SESSION

      assert_equal 41, eval("promptlocal = 41", binding)
      assert_equal 42, eval("promptlocal + 1", binding),
        "a local assigned on one line must still be in scope on the next"
      refute_kind_of SessionsController, eval("self", binding),
        "the prompt must not start with a live controller as self"
      assert_equal Issue.all.to_sql, eval("Issue.all.to_sql", binding)
    end

    test "the page warns against copying the endpoint" do
      get console_root_url

      assert_includes response.body, "Do not ship an eval endpoint"
      assert_includes response.body, "browser_only"
    end
  end
end
