require "test_helper"

# The four todo apps at /compare. Each is asked the same things, and each
# answers in its own way: a redirect, a Turbo Stream, an Inertia redirect.
class FourTodosTest < ActionDispatch::IntegrationTest
  TURBO_STREAM = { "Accept" => "text/vnd.turbo-stream.html, text/html" }.freeze

  { "plain" => [Plain::Todo, :todo], "instant" => [Issue, :issue] }.each do |way, (model, key)|
    test "#{way}: the list, an add, a tick and a delete, each by a redirect" do
      get "/#{way}"
      assert_response :success
      assert_select "ul.four-list[data-controller=stopwatch]"

      post "/#{way}/todos", params: { key => { title: "Buy milk" } }
      assert_redirected_to "/#{way}"
      todo = model.find_by!(title: "Buy milk")

      patch "/#{way}/todos/#{todo.id}", params: { done: "1" }
      assert_redirected_to "/#{way}"
      assert_equal "done", todo.reload.state

      # An unchecked box submits no parameter at all.
      patch "/#{way}/todos/#{todo.id}"
      assert_equal "open", todo.reload.state

      delete "/#{way}/todos/#{todo.id}"
      assert_redirected_to "/#{way}"
      assert_not model.exists?(todo.id)
    end
  end

  test "plain and instant are the same app, but for the model's name and where it runs" do
    as_instant = ->(source) { source.gsub("plain_", "instant_").gsub("todo[title]", "issue[title]").gsub("Todo.", "Issue.").gsub("todo_params", "issue_params").gsub(":todo)", ":issue)") }

    plain, instant = %w[plain instant].map { |way| Rails.root.join("app/views/#{way}/todos/index.html.erb").read }
    assert_equal as_instant.(plain), instant

    actions = ->(way) { Rails.root.join("app/controllers/#{way}/todos_controller.rb").read[/    def index.*/m] }
    assert_equal as_instant.(actions.("plain")), actions.("instant")
  end

  test "hotwire: each write is answered with the piece that changed" do
    post "/hotwire/todos", params: { todo: { title: "Buy milk" } }, headers: TURBO_STREAM
    todo = Hotwire::Todo.find_by!(title: "Buy milk")
    assert_select "turbo-stream[action=prepend][target=todos]", 1
    assert_select "turbo-stream[action=replace][target=new_todo]", 1

    patch "/hotwire/todos/#{todo.id}", params: { done: "1" }, headers: TURBO_STREAM
    assert_select "turbo-stream[action=replace][target=?]", ActionView::RecordIdentifier.dom_id(todo)
    assert_equal "done", todo.reload.state

    delete "/hotwire/todos/#{todo.id}", headers: TURBO_STREAM
    assert_select "turbo-stream[action=remove][target=?]", ActionView::RecordIdentifier.dom_id(todo)
    assert_not Hotwire::Todo.exists?(todo.id)
  end

  test "inertia: the list is props, and a write redirects back to them" do
    Inertia::Todo.create!(title: "Buy milk")

    get "/inertia"
    assert_includes response.body, %("component":"Todos/Index")
    assert_includes response.body, %("title":"Buy milk")
    assert_match %r{/assets/todos-\w+\.js}, response.body

    post "/inertia/todos", params: { todo: { title: "Walk the dog" } }
    assert_redirected_to "/inertia"
    assert Inertia::Todo.exists?(title: "Walk the dog")
  end

  test "compare shows the four apps and how much code each is" do
    get "/compare"
    assert_response :success
    assert_select "article.way", 4
    assert_select "iframe[src='/instant']"
    assert_match(/\d+ lines, \d+ files/, response.body)
  end

  test "compare's reset empties the four lists" do
    [Plain::Todo, Hotwire::Todo, Inertia::Todo, Issue].each { |model| model.create!(title: "Buy milk") }

    post "/compare/reset"

    assert_response :no_content
    assert_equal [0, 0, 0, 0], [Plain::Todo, Hotwire::Todo, Inertia::Todo, Issue].map(&:count)
  end
end
