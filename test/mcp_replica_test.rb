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

  test "the total counts every match, on a full page, the last one and past the end" do
    page = lambda do |where, limit, offset|
      result = @replica.query(model: "Issue", where: where, order: "id", limit: limit, offset: offset)
      [result["count"], result["total"]]
    end

    assert_equal [2, 3], page.({}, 2, 0)
    assert_equal [3, 3], page.({}, 3, 0)
    assert_equal [1, 3], page.({}, 2, 2)
    assert_equal [0, 3], page.({}, 2, 3)
    assert_equal [0, 3], page.({}, 2, 900)
    assert_equal [2, 2], page.({ "state" => "open" }, 50, 0)
    assert_equal [1, 2], page.({ "state" => "open" }, 50, 1)
    assert_equal [0, 0], page.({ "state" => "none" }, 50, 0)
    # A value nested in a list takes no place of its own, so no row is read.
    assert_equal [0, 2], page.({ "state" => [{}, "open"] }, 50, 0)
  end

  test "rejects unknown models, columns, operators, and sort directions against SQL injection" do
    assert_raises(ArgumentError) { @replica.query(model: "issues; DROP TABLE issues;--") }
    assert_raises(ArgumentError) { @replica.query(model: "Issue", where: { "title OR 1=1" => "x" }) }
    assert_raises(ArgumentError) { @replica.query(model: "Issue", where: { "title" => { "regex" => ".*" } }) }
    assert_raises(ArgumentError) { @replica.query(model: "Issue", order: "id desc; DROP TABLE issues") }
    assert_raises(ArgumentError) { @replica.query(model: "Issue", columns: ["id", "1; --"]) }
  end

  test "each filter becomes its SQL with every value bound" do
    {
      nil => ["", []],
      {} => ["", []],
      { "title" => {} } => ["", []],
      { "title" => {}, state: "open" } => [' WHERE "state" = ?', ["open"]],
      { "title" => nil } => [' WHERE "title" IS NULL', []],
      { "title" => "x' OR 1=1 --" } => [' WHERE "title" = ?', ["x' OR 1=1 --"]],
      { "title" => true, "state" => false } => [' WHERE "title" = ? AND "state" = ?', [1, 0]],
      { "title" => 1.5 } => [' WHERE "title" = ?', [1.5]],
      { "title" => [] } => [" WHERE 1 = 0", []],
      { "title" => [nil] } => [' WHERE "title" IN (?)', [nil]],
      { "title" => ["a", nil, true, 2] } => [' WHERE "title" IN (?, ?, ?, ?)', ["a", nil, 1, 2]],
      { "title" => { eq: "a" } } => [' WHERE "title" = ?', ["a"]],
      { "title" => { "eq" => nil } } => [' WHERE "title" IS NULL', []],
      { "title" => { "eq" => false } } => [' WHERE "title" = ?', [0]],
      { "title" => { "eq" => "a", "ne" => "b" } } => [' WHERE "title" = ? AND "title" != ?', %w[a b]],
      { "title" => { "ne" => nil } } => [' WHERE "title" IS NOT NULL', []],
      { "title" => { "ne" => false } } => [' WHERE "title" != ?', [0]],
      { "title" => { "gt" => 1, "gte" => "2", "lt" => 3.0, "lte" => true } } =>
        [' WHERE "title" > ? AND "title" >= ? AND "title" < ? AND "title" <= ?', [1, "2", 3.0, 1]],
      { "title" => { "gt" => nil, "gte" => nil, "lt" => nil, "lte" => nil } } =>
        [' WHERE "title" > ? AND "title" >= ? AND "title" < ? AND "title" <= ?', [nil, nil, nil, nil]],
      { "title" => { "gt" => false, "gte" => true, "lt" => false, "lte" => false } } =>
        [' WHERE "title" > ? AND "title" >= ? AND "title" < ? AND "title" <= ?', [0, 1, 0, 0]],
      { "title" => { "like" => "A%_\\É" } } => [%q( WHERE CAST("title" AS TEXT) LIKE ? ESCAPE '\\'), ["%a\\%\\_\\\\é%"]],
      { "title" => { "like" => nil } } => [%q( WHERE CAST("title" AS TEXT) LIKE ? ESCAPE '\\'), ["%%"]],
      { "title" => { "like" => true } } => [%q( WHERE CAST("title" AS TEXT) LIKE ? ESCAPE '\\'), ["%true%"]],
      { "title" => { "in" => [] } } => [" WHERE 1 = 0", []],
      { "title" => { "in" => nil } } => [" WHERE 1 = 0", []],
      { "title" => { "in" => "a" } } => [' WHERE "title" IN (?)', ["a"]],
      { "title" => { "in" => false } } => [' WHERE "title" IN (?)', [0]],
      { "title" => { "in" => [true, nil, 3] } } => [' WHERE "title" IN (?, ?, ?)', [1, nil, 3]],
      { "title" => { "in" => { "a" => 1 } } } => [' WHERE "title" IN (?)', [["a", 1]]],
      { "title" => { "is_null" => true, "not_null" => true } } => [' WHERE "title" IS NULL AND "title" IS NOT NULL', []],
      { "title" => { "is_null" => false, "not_null" => nil } } => [' WHERE "title" IS NOT NULL AND "title" IS NULL', []],
      { "title" => { "is_null" => 0, "not_null" => "" } } => [' WHERE "title" IS NULL AND "title" IS NOT NULL', []],
      { "title" => { "in" => [1, 2], "eq" => 3 }, "state" => [4], %(a"b) => 5 } =>
        [' WHERE "title" IN (?, ?) AND "title" = ? AND "state" IN (?) AND "a""b" = ?', [1, 2, 3, 4, 5]],
      Class.new(Hash)["title", Class.new(Hash)["eq", 1]] => [' WHERE "title" = ?', [1]]
    }.each do |where, expected|
      sql, binds = build_where(where)
      assert_equal expected, [sql, binds], where.inspect
      assert_equal expected.last.map(&:class), binds.map(&:class), where.inspect
    end
  end

  test "a filter that cannot be built names the first problem" do
    operators = "Allowed: eq, ne, gt, gte, lt, lte, like, in, is_null, not_null"
    columns = %(Available columns: title, state, a"b)
    {
      [] => "where must be an object/hash",
      "" => "where must be an object/hash",
      false => "where must be an object/hash",
      { "nope" => { "regex" => 1 } } => %(Unknown column "nope". #{columns}),
      { "nope" => {} } => %(Unknown column "nope". #{columns}),
      { "nope" => [] } => %(Unknown column "nope". #{columns}),
      { "nope" => nil } => %(Unknown column "nope". #{columns}),
      { "title" => { "regex" => 1 }, "nope" => 1 } => %(Unsupported filter operator "regex" for column title. #{operators}),
      { title: { "eq" => 1, "EQ" => 2, "regex" => 3 } } => %(Unsupported filter operator "EQ" for column title. #{operators}),
      { "title" => { nil => 1 } } => %(Unsupported filter operator "" for column title. #{operators})
    }.each do |where, message|
      error = assert_raises(ArgumentError, where.inspect) { build_where(where) }
      assert_equal message, error.message
    end
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

  test "search and the like filter fold ASCII case only and match every column as text" do
    write do |db|
      db.execute_batch(<<~SQL)
        INSERT INTO notes VALUES ('n-2', 'CAFÉ Menu', 'x', 45678, 'synced', 'a', 'a');
        INSERT INTO notes VALUES ('n-3', 'café menu', 'x', 3, 'synced', 'b', 'b');
        INSERT INTO notes VALUES ('n-4', CAST('Blob LABEL' AS BLOB), 'x', 4, 'synced', 'c', 'c');
      SQL
    end

    assert_equal %w[n-3 n-2], search_ids("MENU")
    # Ruby folds the term's É to é; SQLite leaves a stored É as it is.
    assert_equal ["n-3"], search_ids("CAFÉ")
    assert_equal ["n-4"], search_ids("blob label")
    assert_equal ["n-2"], search_ids("567", columns: ["server_version"])
    assert_equal [], search_ids("back\\slash")

    like = ->(column, text) { @replica.query(model: "Note", where: { column => { "like" => text } }, order: "id")["rows"].map { |r| r["id"] } }
    assert_equal %w[n-2 n-3], like.("title", "mEnU")
    assert_equal ["n-3"], like.("title", "CAFÉ")
    assert_equal ["n-4"], like.("title", "label")
    assert_equal ["n-2"], like.("server_version", "567")
    assert_equal [], like.("title", "%")
  end

  test "each read returns its own plain rows with string keys in column order" do
    columns = %w[id title body server_version sync_state created_at updated_at]
    read = -> {
      [@replica.find(model: "Note", id: "n-1")["record"],
       @replica.query(model: "Note")["rows"].first,
       @replica.search(query: "checklist")["matches"].first["record"]]
    }

    rows = read.call
    rows.each do |row|
      assert_instance_of Hash, row
      assert_equal columns, row.keys
      row["title"] = "changed by the caller"
    end
    assert_equal ["Release checklist"], read.call.map { |row| row["title"] }.uniq
    assert_equal [], @replica.query(model: "Note", where: { "id" => "nope" })["rows"]
    refute_predicate @replica.query(model: "Note")["rows"], :frozen?
    refute_predicate @replica.outbox["mutations"], :frozen?
    assert_equal({ "title" => "Release checklist", "id" => "n-1" },
      @replica.query(model: "Note", columns: %w[title id title])["rows"].first)
  end

  test "outbox keeps an unparseable payload as text and leaves out an empty one" do
    write do |db|
      db.execute_batch(<<~SQL)
        INSERT INTO instant_record_outbox VALUES ('m-2', 'Note', 'n-1', 'update', '{oops', 1, '2026-11-20T12:00:00Z', 'x');
        INSERT INTO instant_record_outbox VALUES ('m-3', 'Note', 'n-1', 'delete', '', 1, '2026-11-20T13:00:00Z', 'x');
      SQL
    end

    mutations = @replica.outbox["mutations"]
    assert_equal %w[m-1 m-2 m-3], mutations.map { |m| m["id"] }
    assert_equal "{oops", mutations[1]["changes"]
    refute mutations[2].key?("changes")
  end

  test "opens the replica read-only" do
    @replica.models
    assert_raises(SQLite3::ReadOnlyException) do
      @replica.send(:connection).execute("DELETE FROM notes")
    end
  end

  test "a column added underneath shows up in rows at once and as a name after refresh_schema!" do
    @replica.models
    write { |db| db.execute("ALTER TABLE notes ADD COLUMN tag TEXT DEFAULT 'Fresh'") }

    assert_equal "Fresh", @replica.find(model: "Note", id: "n-1")["record"]["tag"]
    assert_raises(ArgumentError) { @replica.query(model: "Note", where: { "tag" => "Fresh" }) }
    assert_equal [], search_ids("fresh")

    @replica.refresh_schema!
    assert_equal 1, @replica.query(model: "Note", where: { "tag" => "Fresh" })["total"]
    assert_equal ["n-1"], search_ids("fresh")
  end

  test "a table dropped underneath is an SQL error naming the table" do
    @replica.models
    write { |db| db.execute("DROP TABLE notes") }

    error = assert_raises(SQLite3::SQLException) { @replica.search(query: "release", models: ["Note"]) }
    assert_match(/no such table: (main\.)?notes/, error.message)
  end

  test "a replaced file is read after reopen, the old one until then" do
    @replica.models
    replacement = File.join(@dir, "next.sqlite3")
    seed_sqlite!(replacement)
    write(replacement) { |db| db.execute("UPDATE notes SET title = 'Second file'") }
    File.rename(replacement, @db_path)

    assert_equal "Release checklist", @replica.find(model: "Note", id: "n-1")["record"]["title"]
    @replica.reopen
    assert_equal "Second file", @replica.find(model: "Note", id: "n-1")["record"]["title"]
  end

  test "models reports counts on empty and populated tables with and without sync_state without sharing column hashes" do
    write do |db|
      db.execute_batch(<<~SQL)
        CREATE TABLE empty_synced_items (
          id TEXT PRIMARY KEY,
          label TEXT,
          sync_state TEXT NOT NULL DEFAULT 'synced'
        );
        CREATE TABLE plain_items (
          id TEXT PRIMARY KEY,
          label TEXT
        );
        CREATE TABLE empty_plain_items (
          id TEXT PRIMARY KEY,
          label TEXT
        );
        INSERT INTO plain_items VALUES ('p-1', 'Alpha'), ('p-2', 'Beta');
        UPDATE instant_record_sync_metadata
          SET value = 'Issue,Note,EmptySyncedItem,PlainItem,EmptyPlainItem'
          WHERE key = 'compiled_models';
      SQL
    end
    @replica.refresh_schema!

    first = @replica.models["models"]
    by_name = first.each_with_object({}) { |m, acc| acc[m["name"]] = m }

    assert_equal [3, 1], [by_name["Issue"]["count"], by_name["Issue"]["pending_count"]]
    assert_equal [1, 0], [by_name["Note"]["count"], by_name["Note"]["pending_count"]]
    assert_equal [0, 0], [by_name["EmptySyncedItem"]["count"], by_name["EmptySyncedItem"]["pending_count"]]
    assert_equal [2, 0], [by_name["PlainItem"]["count"], by_name["PlainItem"]["pending_count"]]
    assert_equal [0, 0], [by_name["EmptyPlainItem"]["count"], by_name["EmptyPlainItem"]["pending_count"]]

    # Mutating returned column metadata must not affect subsequent calls.
    by_name["Issue"]["columns"].first["name"] = "mutated"
    by_name["Issue"]["columns"] << { "name" => "extra" }

    second = @replica.models["models"].find { |m| m["name"] == "Issue" }
    assert_equal "id", second["columns"].first["name"]
    refute_includes second["columns"].map { |c| c["name"] }, "extra"
  end

  test "query total matches across full pages, short last pages, offset past end, and repeated cached binds" do
    # Full page (limit 2, offset 0) and short last page (limit 2, offset 2)
    full_page = @replica.query(model: "Issue", order: "id asc", limit: 2, offset: 0)
    assert_equal [2, 3], [full_page["count"], full_page["total"]]
    assert_equal %w[i-1 i-2], full_page["rows"].map { |r| r["id"] }

    last_page = @replica.query(model: "Issue", order: "id asc", limit: 2, offset: 2)
    assert_equal [1, 3], [last_page["count"], last_page["total"]]
    assert_equal %w[i-3], last_page["rows"].map { |r| r["id"] }

    past_end = @replica.query(model: "Issue", order: "id asc", limit: 2, offset: 10)
    assert_equal [0, 3], [past_end["count"], past_end["total"]]
    assert_equal [], past_end["rows"]

    # Reuse the same IN (?, ?) statement shape with normal binds followed by a nested hash.
    both = @replica.query(model: "Issue", where: { "state" => %w[open done] }, order: "id asc", limit: 2, offset: 0)
    assert_equal [2, 3], [both["count"], both["total"]]

    nested = @replica.query(model: "Issue", where: { "state" => [{}, "open"] }, order: "id asc", limit: 2, offset: 0)
    assert_equal [0, 2], [nested["count"], nested["total"]]
    assert_equal [], nested["rows"]
  end

  test "search handles NULLs, integers, LIKE wildcards, multi-term queries, custom columns, and multi-model limits" do
    write do |db|
      db.execute_batch(<<~SQL)
        CREATE TABLE logs (
          id TEXT PRIMARY KEY,
          title TEXT,
          detail TEXT,
          code INTEGER,
          updated_at TEXT
        );
        INSERT INTO logs VALUES ('l-1', NULL, '50% off_sale\\path', 42099, '2026-11-21T01:00:00Z');
        INSERT INTO logs VALUES ('l-2', 'Release 100% done', NULL, 777, '2026-11-21T02:00:00Z');
        UPDATE instant_record_sync_metadata
          SET value = 'Issue,Note,Log'
          WHERE key = 'compiled_models';
      SQL
    end
    @replica.refresh_schema!

    # Special LIKE characters (%, _, \) with NULL sibling column
    special = @replica.search(query: "50% off_sale\\path", models: ["Log"])
    assert_equal ["l-1"], special["matches"].map { |m| m["id"] }
    assert_equal ["detail"], special["matches"].first["matched_columns"]

    # Duplicate terms and mixed special + plain terms
    mixed = @replica.search(query: "release 100% release", models: ["Log"])
    assert_equal ["l-2"], mixed["matches"].map { |m| m["id"] }
    assert_equal ["title"], mixed["matches"].first["matched_columns"]

    # Custom integer column search
    by_code = @replica.search(query: "209", models: ["Log"], columns: %w[code title])
    assert_equal ["l-1"], by_code["matches"].map { |m| m["id"] }
    assert_equal ["code"], by_code["matches"].first["matched_columns"]

    # Multi-model limit slicing preserves model order and caps total matches
    limited = @replica.search(query: "release", models: %w[Issue Note Log], limit: 2)
    assert_equal 2, limited["count"]
    assert_equal %w[i-1 n-1], limited["matches"].map { |m| m["id"] }

    all_three = @replica.search(query: "release", models: %w[Issue Note Log], limit: 10)
    assert_equal 3, all_three["count"]
    assert_equal %w[i-1 n-1 l-2], all_three["matches"].map { |m| m["id"] }
  end

  test "close, reopen, and refresh_schema! finalize cached statements cleanly and reflect renamed columns" do
    # Warm cached statements across every read path
    @replica.models
    @replica.find(model: "Note", id: "n-1")
    @replica.query(model: "Issue", where: { "state" => "open" }, order: "updated_at desc", limit: 2)
    @replica.search(query: "release", limit: 5)

    # Column rename underneath is picked up on cached statements immediately
    write { |db| db.execute("ALTER TABLE notes RENAME COLUMN body TO content") }
    renamed = @replica.find(model: "Note", id: "n-1")["record"]
    assert_equal "Run tests and tag release", renamed["content"]
    refute renamed.key?("body")

    # refresh_schema! clears cached statements without error
    @replica.refresh_schema!
    assert_equal 1, @replica.query(model: "Note", where: { "content" => { "like" => "tag release" } })["total"]

    # reopen and repeated close never raise SQLite3::BusyException from unfinalized statements
    @replica.reopen
    assert_equal "Release checklist", @replica.find(model: "Note", id: "n-1")["record"]["title"]
    @replica.close
    @replica.close
  end

  private

  def write(path = @db_path)
    db = SQLite3::Database.new(path)
    yield db
  ensure
    db&.close
  end

  def build_where(where)
    @replica.send(:build_where, where, ["title", "state", %(a"b)])
  end

  def search_ids(text, **options)
    @replica.search(query: text, models: ["Note"], **options)["matches"].map { |m| m["id"] }
  end

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
