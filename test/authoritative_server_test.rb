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

  def test_rack_server_closes_response_body_when_iteration_or_auth_raises
    closed = []
    failing_body = Object.new
    failing_body.define_singleton_method(:each) { |&_blk| raise RuntimeError, "stream broke" }
    failing_body.define_singleton_method(:close) { closed << :exchange_body }

    auth_body = Object.new
    auth_body.define_singleton_method(:close) { closed << :auth_body }

    app = lambda do |env|
      if env["PATH_INFO"] == "/auth/session"
        [500, {}, auth_body]
      else
        [200, {}, failing_body]
      end
    end
    app.define_singleton_method(:config) { Struct.new(:instant_record).new(Struct.new(:mount_path).new("/sync")) }
    server = InstantRecord::Testing::AuthoritativeServer::RackServer.new(app: app)

    err = assert_raises(RuntimeError) { server.exchange("GET", "/bootstrap") }
    assert_equal "stream broke", err.message
    assert_equal [:exchange_body], closed

    auth_err = assert_raises(InstantRecord::Testing::Error) { server.exchange("GET", "/bootstrap", identity: "ada") }
    assert_match(%r{POST /auth/session failed}, auth_err.message)
    assert_equal [:exchange_body, :auth_body], closed
  end

  def test_standalone_server_cleans_up_on_initialize_failure
    prev_synced = InstantRecord.synced_models.dup
    prev_scope = InstantRecord.config.scope_from
    sentinel_model = syncable_model("BeforeFailure")
    sentinel_scope = ->(_req) { "sentinel" }
    InstantRecord.sync(sentinel_model)
    InstantRecord.config.scope_from = sentinel_scope

    captured_tmpdir = nil
    captured_shard = nil
    failing_class = Class.new(InstantRecord::Testing::AuthoritativeServer::StandaloneServer) do
      define_method(:ensure_models!) do
        captured_tmpdir = @tmpdir
        captured_shard = @shard
        InstantRecord.sync
        InstantRecord.config.scope_from = ->(_req) { "mutated" }
        raise RuntimeError, "boom during init"
      end
    end

    err = assert_raises(RuntimeError) { failing_class.new }
    assert_equal "boom during init", err.message

    refute_nil captured_tmpdir
    refute Dir.exist?(captured_tmpdir), "tmpdir should be removed when initialize fails"
    assert_nil ActiveRecord::Base.connection_handler.retrieve_connection_pool(
      ActiveRecord::Base.name,
      role: :writing,
      shard: captured_shard
    ), "shard connection pool should be removed when initialize fails"
    assert_equal [sentinel_model], InstantRecord.synced_models
    assert_equal sentinel_scope, InstantRecord.config.scope_from
  ensure
    InstantRecord.sync(*prev_synced)
    InstantRecord.config.scope_from = prev_scope
  end

  def test_standalone_server_preserves_original_initialize_error_when_close_raises
    prev_synced = InstantRecord.synced_models.dup
    prev_scope = InstantRecord.config.scope_from
    sentinel_model = syncable_model("BeforeMaskedFailure")
    sentinel_scope = ->(_req) { "sentinel" }
    InstantRecord.sync(sentinel_model)
    InstantRecord.config.scope_from = sentinel_scope

    captured_tmpdir = nil
    captured_shard = nil
    failing_class = Class.new(InstantRecord::Testing::AuthoritativeServer::StandaloneServer) do
      define_method(:ensure_models!) do
        captured_tmpdir = @tmpdir
        captured_shard = @shard
        raise RuntimeError, "original init failure"
      end

      define_method(:close) do
        super()
        raise RuntimeError, "secondary close failure"
      end
    end

    err = assert_raises(RuntimeError) { failing_class.new }
    assert_equal "original init failure", err.message
    refute_nil captured_tmpdir
    refute Dir.exist?(captured_tmpdir), "tmpdir should still be removed when close raises after cleanup"
    assert_nil ActiveRecord::Base.connection_handler.retrieve_connection_pool(
      ActiveRecord::Base.name,
      role: :writing,
      shard: captured_shard
    ), "shard pool should still be removed when close raises after cleanup"
  ensure
    InstantRecord.sync(*prev_synced)
    InstantRecord.config.scope_from = prev_scope
  end

  def test_standalone_server_close_is_idempotent_restores_state_and_runs_all_cleanup_steps
    prev_synced = InstantRecord.synced_models.dup
    prev_scope = InstantRecord.config.scope_from
    extra = nil
    broken = nil
    sentinel_model = syncable_model("BeforeOpen")
    after_model = syncable_model("AfterClose")
    sentinel_scope = ->(_req) { "before" }
    after_scope = ->(_req) { "after" }

    InstantRecord.sync(sentinel_model)
    InstantRecord.config.scope_from = sentinel_scope

    extra = InstantRecord::Testing::AuthoritativeServer::StandaloneServer.new
    tmpdir = File.dirname(extra.db_path)
    shard = extra.instance_variable_get(:@shard)
    assert Dir.exist?(tmpdir)
    refute_nil ActiveRecord::Base.connection_handler.retrieve_connection_pool(
      ActiveRecord::Base.name,
      role: :writing,
      shard: shard
    )

    InstantRecord.config.scope_from = ->(_req) { "during" }
    extra.close

    refute Dir.exist?(tmpdir)
    assert_nil ActiveRecord::Base.connection_handler.retrieve_connection_pool(
      ActiveRecord::Base.name,
      role: :writing,
      shard: shard
    )
    assert_equal [sentinel_model], InstantRecord.synced_models
    assert_equal sentinel_scope, InstantRecord.config.scope_from

    # Second close must be a no-op and must not overwrite state configured afterwards.
    InstantRecord.sync(after_model)
    InstantRecord.config.scope_from = after_scope
    extra.close
    assert_equal [after_model], InstantRecord.synced_models
    assert_equal after_scope, InstantRecord.config.scope_from

    # If an earlier cleanup step raises, nested ensure still runs remaining steps.
    broken = InstantRecord::Testing::AuthoritativeServer::StandaloneServer.new
    broken_tmpdir = File.dirname(broken.db_path)
    broken_shard = broken.instance_variable_get(:@shard)
    InstantRecord.config.scope_from = ->(_req) { "dirty" }

    config_singleton = InstantRecord.config.singleton_class
    config_singleton.class_eval do
      alias_method :original_scope_from_writer, :scope_from=
      define_method(:scope_from=) { |_val| raise RuntimeError, "scope restore failed" }
    end
    begin
      err = assert_raises(RuntimeError) { broken.close }
      assert_equal "scope restore failed", err.message
    ensure
      config_singleton.class_eval do
        remove_method :scope_from=
        alias_method :scope_from=, :original_scope_from_writer
        remove_method :original_scope_from_writer
      end
    end

    refute Dir.exist?(broken_tmpdir), "tmpdir must still be removed when an earlier cleanup step raises"
    assert_nil ActiveRecord::Base.connection_handler.retrieve_connection_pool(
      ActiveRecord::Base.name,
      role: :writing,
      shard: broken_shard
    ), "shard pool must still be removed when an earlier cleanup step raises"
  ensure
    begin
      extra&.close
    rescue StandardError
      nil
    end
    begin
      broken&.close
    rescue StandardError
      nil
    end
    InstantRecord.sync(*prev_synced)
    InstantRecord.config.scope_from = prev_scope
  end

  private

  def issues = @server.visible_state.fetch("Issue")
end
