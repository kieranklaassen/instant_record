require "test_helper"

class SourceControllerTest < ActionDispatch::IntegrationTest
  test "reads the real model, controller and view off disk for a page" do
    get source_url(page: "todo/issues", view: "index")

    assert_response :success
    # Not a fixture and not a snippet: the actual bytes of the file on disk.
    assert_includes response.body, "app/models/issue.rb"
    assert_includes response.body, "app/controllers/todo/issues_controller.rb"
    assert_includes response.body, "app/views/todo/issues/index.html.erb"

    # Highlighting splits a line across token spans, so the source is asserted
    # against the rendered text rather than the markup.
    text = Nokogiri::HTML5.fragment(response.body).text
    assert_includes text, "include InstantRecord::Syncable"
    assert_includes text, "class Issue < ApplicationRecord"
  end

  test "highlights ruby and erb without losing or reordering a single line" do
    get source_url(page: "todo/issues", view: "index")

    %w[app/models/issue.rb app/views/todo/issues/index.html.erb].each do |path|
      raw = File.readlines(Rails.root.join(path), chomp: true)
      rendered = Nokogiri::HTML5.fragment(response.body)
        .css("section.source-file")
        .find { |section| section.at_css(".source-path")&.text == path }

      lines = rendered.css(".source-line .source-text").map(&:text)
      assert_equal raw, lines, "#{path} did not survive highlighting intact"
      assert rendered.css(".source-text span[class]").any?, "#{path} was not tokenized at all"
    end
  end

  test "marks only the InstantRecord lines" do
    issue = File.readlines(Rails.root.join("app/models/issue.rb"), chomp: true)
    marked = issue.count { |line| SourceHelper::INSTANT_RECORD_LINE.match?(line) }

    get source_url(page: "todo/issues", view: "index")

    # The claim the drawer makes on the page is a ratio, so it has to be counted
    # from the file rather than asserted as prose.
    assert marked.positive?, "issue.rb must contain the InstantRecord opt-in"
    assert marked < issue.size, "most of issue.rb must be ordinary Rails"
    assert_includes response.body, "#{marked} InstantRecord lines of #{issue.size}"
  end

  test "a file that is not in the bundle says so instead of erroring" do
    # public/ is not packed into app.wasm, and a demo's view may not exist yet.
    get source_url(page: "home", view: "nonexistent_action")

    assert_response :success
    assert_includes response.body, "Not in this bundle"
  end

  test "refuses paths that could escape the app tree" do
    ["../config", "todo/../../etc", "/etc/passwd", "todo/issues.rb", "Todo/Issues"].each do |page|
      get source_url(page: page, view: "index")
      assert_response :bad_request, "#{page.inspect} must not reach the file reader"
    end

    ["../../config/master", "index/../../../secrets", "index.html.erb"].each do |view|
      get source_url(page: "todo/issues", view: view)
      assert_response :bad_request, "#{view.inspect} must not reach the file reader"
    end
  end

  test "the drawer is wired into every demo page" do
    get todo_root_url

    assert_includes response.body, %(id="source-drawer")
    assert_includes response.body,
      ERB::Util.html_escape(source_path(page: "todo/issues", view: "index"))
  end
end
