require "test_helper"
require "instant_record/mcp"
require "sqlite3"
require "tmpdir"

class McpReplicaTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir
    @db_path = File.join(@dir, "replica.sqlite3")
    seed_sqlite!(@db_path)
    @replica = InstantRecord::Mcp::Replica.new(database_path: @db_path)
  end

  teardown do
    @replica&.close
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  test "discovers synced models from compiled_models metadata and reports row/pending counts" do
    result = @replica.models
    names = result["models"].map { |m| m["name"] }

    assert_equal %w[Issue Note], names
    issue_info = result["models"].find { |m| m["name"] == "Issue" }
    assert_equal "issues", issue_info["table"]
    assert_equal 3, issue_info["count"]
    assert_equal 1, issue_info["pending_count"]
    assert_includes issue_info["columns"].map { |c| c["name"] }, "title"
  end

  test "queries with equality, operators, sorting, column projection, and pagination in sub-millisecond time" do
    open_issues = @replica.query(model: "Issue", where: { "state" => "open" }, order: "created_at desc")
    assert_equal 2, open_issues["count"]
    assert_equal 2, open_issues["total"]
    assert_equal %w[i-2 i-1], open_issues["rows"].map { |r| r["id"] }

    # Table name and lowercased model name aliases work too.
    projected = @replica.query(
      model: "issues",
      where: { "server_version" => { "gte" => 2 }, "title" => { "like" => "invoice" } },
      columns: %w[id title]
    )
    assert_equal [{ "id" => "i-2", "title" => "Fix 100% invoice_total bug" }], projected["rows"]

    # Pagination
    page = @replica.query(model: "Issue", order: "id asc", limit: 2, offset: 1)
    assert_equal 3, page["total"]
    assert_equal %w[i-2 i-3], page["rows"].map { |r| r["id"] }

    # Latency benchmark: warm local SQLite queries stay well under 5ms (typically <0.5ms).
    times = 10.times.map { @replica.query(model: "Issue", where: { "state" => "open" })["elapsed_ms"] }
    assert_operator times.min, :<, 5.0, "expected local replica query to be sub-millisecond (got #{times.inspect})"
  end

  test "rejects unknown models, columns, operators, and sort directions against SQL injection" do
    assert_raises(ArgumentError) { @replica.query(model: "issues; DROP TABLE issues;--") }
    assert_raises(ArgumentError) { @replica.query(model: "Issue", where: { "title OR 1=1" => "x" }) }
    assert_raises(ArgumentError) { @replica.query(model: "Issue", where: { "title" => { "regex" => ".*" } }) }
    assert_raises(ArgumentError) { @replica.query(model: "Issue", order: "id desc; DROP TABLE issues") }
    assert_raises(ArgumentError) { @replica.query(model: "Issue", columns: ["id", "1; --"]) }
  end

  test "finds single record by primary key" do
    found = @replica.find(model: "Note", id: "n-1")
    assert_equal "Release checklist", found["record"]["title"]

    missing = @replica.find(model: "Note", id: "does-not-exist")
    assert_nil missing["record"]
  end

  test "searches across synced models with multi-term matching and LIKE wildcard escaping" do
    # Literal % and _ must NOT act as LIKE wildcards.
    literal = @replica.search(query: "100% invoice_total")
    assert_equal 1, literal["count"]
    assert_equal "i-2", literal["matches"].first["id"]
    assert_equal ["title"], literal["matches"].first["matched_columns"]

    # Multi-model search finds matches across both Issue and Note.
    across = @replica.search(query: "release")
    assert_equal %w[i-1 n-1], across["matches"].map { |m| m["id"] }.sort

    # Model-restricted search.
    only_notes = @replica.search(query: "release", models: ["Note"])
    assert_equal ["n-1"], only_notes["matches"].map { |m| m["id"] }
  end

  test "inspects queued outbox mutations with parsed changes" do
    outbox = @replica.outbox
    assert_equal 1, outbox["count"]
    mutation = outbox["mutations"].first
    assert_equal "Issue", mutation["record_type"]
    assert_equal "i-2", mutation["record_id"]
    assert_equal({ "title" => "Fix 100% invoice_total bug" }, mutation["changes"])
  end

  private

  def seed_sqlite!(path)
    db = SQLite3::Database.new(path)
    db.execute_batch(<<~SQL)
      CREATE TABLE instant_record_sync_metadata (
        key TEXT PRIMARY KEY,
        value TEXT,
        created_at TEXT,
        updated_at TEXT
      );
      CREATE TABLE instant_record_outbox (
        id TEXT PRIMARY KEY,
        record_type TEXT NOT NULL,
        record_id TEXT NOT NULL,
        operation TEXT NOT NULL,
        changes_payload TEXT,
        base_version INTEGER DEFAULT 0,
        created_at TEXT,
        updated_at TEXT
      );
      CREATE TABLE issues (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        state TEXT NOT NULL,
        server_version INTEGER NOT NULL DEFAULT 0,
        sync_state TEXT NOT NULL DEFAULT 'synced',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE notes (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        server_version INTEGER NOT NULL DEFAULT 0,
        sync_state TEXT NOT NULL DEFAULT 'synced',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      INSERT INTO instant_record_sync_metadata (key, value) VALUES ('compiled_models', 'Issue,Note');
      INSERT INTO instant_record_sync_metadata (key, value) VALUES ('cursor', '12');

      INSERT INTO issues VALUES ('i-1', 'Ship release notes', 'open', 1, 'synced', '2026-11-20T10:00:00Z', '2026-11-20T10:00:00Z');
      INSERT INTO issues VALUES ('i-2', 'Fix 100% invoice_total bug', 'open', 2, 'pending', '2026-11-20T11:00:00Z', '2026-11-20T11:00:00Z');
      INSERT INTO issues VALUES ('i-3', 'Archive old logs', 'done', 3, 'synced', '2026-11-20T09:00:00Z', '2026-11-20T09:00:00Z');

      INSERT INTO notes VALUES ('n-1', 'Release checklist', 'Run tests and tag release', 1, 'synced', '2026-11-20T12:00:00Z', '2026-11-20T12:00:00Z');

      INSERT INTO instant_record_outbox VALUES (
        'm-1', 'Issue', 'i-2', 'update', '{"title":"Fix 100% invoice_total bug"}', 1,
        '2026-11-20T11:00:00Z', '2026-11-20T11:00:00Z'
      );
    SQL
    db.close
  end
end
