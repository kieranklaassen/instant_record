require "test_helper"
require "instant_record/testing"

class AuthoritativeServerTest < Minitest::Test
  def setup
    @server = InstantRecord::Testing::AuthoritativeServer.build
  end

  def teardown
    @server.close
  end

  def test_the_todo_pages_write_issues_and_redirect
    moved = { status: 302, headers: { "location" => "/todo" }, body: "" }
    assert_equal moved, @server.exchange("post", "/todo/issues", "issue[title]=A+%3Cb%3E")
    id = issues.sole.fetch("id")
    assert_equal(
      { status: 200, headers: { "content-type" => "text/html" },
        body: %(<ul class="issues"><li data-id="#{id}" class="open">A &lt;b&gt;</li></ul>) },
      @server.exchange("GET", "/todo")
    )
    assert_equal moved, @server.exchange("PATCH", "/todo/issues/#{id}", "done=1")
    assert_equal "done", issues.sole.fetch("state")
    assert_equal moved, @server.exchange("DELETE", "/todo/issues/#{id}")
    assert_empty issues
  end

  def test_the_sync_endpoints_answer_under_any_mount_path
    { "bootstrap" => "application/json", "events?after=0" => "text/event-stream" }.each do |path, type|
      assert_equal({ "content-type" => type }, @server.exchange("GET", "/any/where/#{path}").fetch(:headers))
    end
    sent = @server.exchange("POST", "/any/where/mutations", '{"mutations":[]}')
    assert_equal [200, { "content-type" => "application/json" }], sent.values_at(:status, :headers)
    assert_equal({ status: 404, headers: {}, body: "Not Found: POST /any/bootstrap" }, @server.exchange("POST", "/any/bootstrap"))
  end

  def test_records_refuses_what_it_cannot_page
    page = "before_created_at=2026-01-01&before_id=x"
    windowed = syncable_model("Windowed") do
      self.table_name = "issues"
      sync_window limit: 2
    end
    InstantRecord.sync(Issue, windowed)
    { "Nope" => 404, "Issue" => 422 }.each do |type, status|
      assert_equal({ status: status, headers: {}, body: "" }, @server.exchange("GET", "/records?type=#{type}&#{page}"))
    end
    assert_equal({ status: 400, headers: {}, body: "" }, @server.exchange("GET", "/records?type=Windowed"))
    assert_equal({ "content-type" => "application/json" }, @server.exchange("GET", "/records?type=Windowed&#{page}").fetch(:headers))
  end

  def test_a_changed_identity_resets_the_stream
    reset = @server.exchange("GET", "/events?identity=ben", identity: "ada")
    assert_match(/\Aevent: reset\ndata: \{.*\}\n\n\z/, reset[:body])
    assert_equal [200, { "content-type" => "text/event-stream" }], reset.values_at(:status, :headers)
  end

  def test_a_server_write_answers_the_record_or_nil_when_it_is_gone
    created = @server.server_write(model_name: "Issue", operation: "create", id: "i", attributes: { title: "A", nope: 1 })
    updated = @server.server_write(model_name: "Issue", operation: :update, id: "i", attributes: { title: "B" }, clock_offset: 90)
    assert_equal "B", updated.title
    assert_in_delta 90, updated.updated_at - created.updated_at, 5
    destroyed = @server.server_write(model_name: "Issue", operation: "destroy", id: "i")
    assert_predicate destroyed, :destroyed?

    %w[update destroy].each { |operation| assert_nil @server.server_write(model_name: "Issue", operation: operation, id: "i") }
    assert_raises(ArgumentError) { @server.server_write(model_name: "Issue", operation: "upsert") }
  end

  def test_the_cursor_floor_sets_the_next_change_id
    assert_equal 41, @server.set_cursor_floor("41")
    @server.server_write(model_name: "Issue", operation: "create", attributes: { title: "A" })
    assert_equal 42, @server.current_cursor

    @server.set_cursor_floor(99)
    seeded = @server.seed_boundary_record(id: "i", cursor_id: "77")
    assert_equal [77, "create"], seeded[:change].values_at(:id, :operation)
    @server.server_write(model_name: "Issue", operation: "update", id: "i", attributes: { title: "B" })
    assert_equal 100, @server.current_cursor

    assert_equal 0, @server.reset_data!
    @server.server_write(model_name: "Issue", operation: "create", attributes: { title: "C" })
    assert_equal 1, @server.current_cursor
  end

  def test_a_mounted_app_is_asked_under_its_mount_path_with_the_persons_session
    asked = []
    app = lambda do |env|
      asked << env.values_at("REQUEST_METHOD", "PATH_INFO", "QUERY_STRING", "CONTENT_TYPE", "HTTP_HOST", "HTTP_COOKIE") + [env["rack.input"].read]
      [200, { "set-cookie" => "a=1; path=/\nb=2; httponly" }, %w[o k]]
    end
    app.define_singleton_method(:config) { Struct.new(:instant_record).new(Struct.new(:mount_path).new("/sync/")) }
    server = InstantRecord::Testing::AuthoritativeServer::RackServer.new(app: app)

    assert_equal "ok", server.exchange("post", "/mutations?x=1", ' {"a":1}', identity: "ada")[:body]
    server.exchange("POST", "http://host/sync/bootstrap", "a=1", identity: "ada")
    server.exchange("PUT", "/notes", "{}")
    server.exchange("POST", "/todo", "\xff{", content_type: "text/plain")

    form = "application/x-www-form-urlencoded"
    assert_equal [
      ["POST", "/auth/session", "", "application/json", "localhost", nil, '{"person":"ada"}'],
      ["POST", "/sync/mutations", "x=1", "application/json", "localhost", "a=1; b=2", ' {"a":1}'],
      ["POST", "/sync/bootstrap", "", form, "localhost", "a=1; b=2", "a=1"],
      ["PUT", "/notes", "", form, "localhost", "", "{}"],
      ["POST", "/todo", "", "text/plain", "localhost", "", "\xff{".b]
    ], asked
  end

  private

  def issues = @server.visible_state.fetch("Issue")
end
