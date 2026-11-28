require "test_helper"
require "instant_record/read_tracker_scan"

# ReadTrackerScan replaces ReadTracker's scanning on the server. The browser
# keeps the original, so every answer has to be the same one.
class ReadTrackerScanTest < Minitest::Test
  # read_tracker.rb again under another name, with nothing prepended to it.
  SOURCE = File.read(File.expand_path("../lib/instant_record/read_tracker.rb", __dir__))
  TOPLEVEL_BINDING.eval(SOURCE.sub("module ReadTracker\n", "module ReadTrackerReference\n"))
  REFERENCE = InstantRecord::ReadTrackerReference
  SCAN = InstantRecord::ReadTracker

  METHODS = %i[
    top_level_text mask_string_literals count_placeholders unwrap_outer_parens
    split_top_level_commas split_top_level_and extract_outer_where extract_tables
  ].freeze
  KEYWORDS = %w[WHERE GROUP ORDER LIMIT HAVING UNION INTERSECT EXCEPT OR AND].freeze
  BINDS = [nil, [], ["o"] * 3, [1, nil, "é"]].freeze

  ATOMS = [
    "'", "''", "''''", "(", ")", "?", ",", ";", " ", "\n", "a", "\"items\"", "items", "SELECT", "WHERE", "FROM", "JOIN",
    "AND", "or", "OR", "ORDER", "GROUP", "LIMIT", "UNION", "limıt", "interſect", "IN", "=", "$1", "1", "owner",
    "é", "日本", "ß", "-- c'\n", "/* ' */", "ANDx", "xOR", "\0", "'a''b'", "(1,2)", "WITH t AS ("
  ].freeze
  VALUES = ["?", "$1", "'x'", "'a''b'", "'é''日'", "''", "'('", "'OR'", "42", "NULL", "'un", "(SELECT ?)"].freeze
  COLUMNS = ["owner", "items.owner", "\"items\".\"owner_id\"", "id", "LOWER(title)"].freeze
  SOURCES = ["items", "\"items\"", "items i", "items JOIN labels l ON l.item_id = items.id", "(SELECT * FROM labels) t"].freeze
  ENDINGS = ["", "", " ORDER BY x LIMIT ?", " GROUP BY x", ";", " UNION SELECT * FROM labels WHERE owner = ?",
    " UNION ALL SELECT * FROM items", " INTERSECT SELECT * FROM items", " EXCEPT SELECT * FROM items"].freeze

  EDGES = [
    "", "'", "''", "'''", "''''", "(", ")", "()", "(')')", "((a) AND (b))", "(a) AND (b)", "((a)", "a)(", ",", ",,", "a,", "'a,b',(c,d),e",
    "(a 'un", "(a = ')'", "('a''b')", "'a''b', c", "OR", "'x'OR'y'", "(x OR y)",
    "SELECT * FROM items WHERE owner = 'a''b' AND id IN (?, ?)",
    "SELECT 'q''s' FROM items WHERE owner = ? ORDER BY id",
    "WITH t AS (SELECT * FROM labels WHERE owner = 'z') SELECT * FROM items WHERE owner = 'é'",
    "-- it's (\nSELECT * FROM items WHERE (owner = ?)",
    "SELECT * FROM items WHERE owner = 'x' UNION SELECT * FROM items WHERE owner = 'y'",
    "SELECT * FROM items WHERE owner = 'x' UNION ALL SELECT * FROM items",
    "SELECT * FROM items WHERE owner = 'x' INTERSECT SELECT * FROM items",
    "SELECT * FROM items EXCEPT SELECT * FROM items WHERE owner = 'x'",
    "SELECT union_id FROM items WHERE owner = 'a UNION b' AND id IN (SELECT 1 EXCEPT SELECT 2)",
    "SELECT * FROM items WHERE owner = 'x' AND \"union\" = 'é''EXCEPT'",
    "SELECT * FROM 'x'a",
    "SELECT * FROM items JOIN where AS items ON 1=1 WHERE items.owner = 'x'",
    "SELECT * FROM items WHERE owner = 'a''b' ORDER BY id",
    "SELECT * FROM items WHERE owner = 'café''日本' AND (a = 1 OR b = 2) ORDER BY id",
    "SELECT * FROM items WHERE owner = $0 AND id = $1",
    "SELECT * FROM items WHERE ('a' = 'a') AND owner = 'x'",
    "SELECT * FROM items WHERE\0owner = 'x'\0"
  ].freeze

  # Binds that are the same text, or only look it, as another.
  LIST_BINDS = [
    1, "1", 1.0, -3, 10**20, true, :a, "a", "a".b, "a".encode("UTF-16LE"), "é", "é".b, "é".encode("ISO-8859-1"),
    "é", "", "".encode("UTF-16LE"), "\xFF", "x'y"
  ].freeze
  LIST_LITERALS = ["1", "01", "'x'", "'a''b'", "'é,'", "'日本'", "''", "'('", "-3", "1.0"].freeze
  LISTS = ["id IN (%s)", "items.id IN (%s)", "(id IN (%s))", "((\"items\".\"id\" IN (%s)))", "owner IN (%s)", "id = 1 AND id IN (%s)"].freeze

  def setup
    @model = syncable_model("ScannedMemo") { sync_window limit: 20, partition_by: :owner }
    InstantRecord.sync(@model)
  end

  def teardown
    InstantRecord.sync
  end

  def test_the_scan_is_in_front_of_the_original
    assert_includes SCAN.singleton_class.ancestors, InstantRecord::ReadTrackerScan
    refute_includes REFERENCE.singleton_class.ancestors, InstantRecord::ReadTrackerScan
  end

  def test_edge_texts_scan_the_same
    EDGES.each { |text| encodings(text).each { |variant| assert_same_scan(variant, BINDS.last) } }
  end

  def test_generated_texts_scan_the_same
    @random = Random.new(20_261_125)
    narrowed = 0
    600.times do
      text = pick(encodings(pick([-> { noise }, -> { select }, -> { broken(select) }]).call))
      narrowed += 1 if assert_same_scan(text, pick(BINDS))
    end
    assert_operator narrowed, :>, 20, "too few generated queries reach partition narrowing"
  end

  def test_long_lists_read_the_same
    @random = Random.new(20_261_126)
    narrowed = 0
    150.times do
      queries = Array.new(1 + @random.rand(3)) { list_query }
      reference = outcome { track(REFERENCE, queries) }
      assert_equal reference, outcome { track(SCAN, queries) }, queries.inspect
      narrowed += 1 if reference.first == :ok && reference[1].first["partitions"].any?

      queries.each { |sql, binds| assert_same_values(sql, binds) }
    end
    assert_operator narrowed, :>, 20, "too few generated lists narrow"
  end

  def test_only_a_column_that_is_not_an_id_asks_the_models
    asked = { "id = 'x'" => 0, "id IN ('x', 'y')" => 0, "list_id = 'x'" => 0, "title LIKE 'x'" => 0, "owner = 'x'" => 1,
      "title = 'x' AND owner = 'y'" => 1 }
    asked.each do |where, times|
      sql = "SELECT * FROM items WHERE #{where}"
      assert_equal times, models_asked { SCAN.send(:extract_outer_partitions, sql, ["items"], nil) }, where
      assert_equal track(REFERENCE, [[sql, nil]]), track(SCAN, [[sql, nil]])
    end
  end

  # A model that loads while a block is tracked counts for the queries after it.
  def test_partition_columns_are_read_for_each_query
    sql = "SELECT * FROM items WHERE owner = 'x'"
    InstantRecord.sync(syncable_model("PlainMemo"))
    assert_empty SCAN.send(:extract_outer_partitions, sql, ["items"], nil)

    InstantRecord.sync(@model)
    assert_equal({ "items" => { "owner" => ["x"] } }, SCAN.send(:extract_outer_partitions, sql, ["items"], nil))
  end

  def test_repeated_record_sql_reflects_dynamic_partition_column_changes
    sql = 'SELECT "items".* FROM "items" WHERE "items"."owner" = ? AND "items"."title" = ? ORDER BY "items"."id" LIMIT 10'

    # Run repeatedly to exercise any internal query-plan caching.
    4.times do |i|
      binds = ["owner_#{i}", "title_#{i}"]
      assert_equal track(REFERENCE, [[sql.dup, binds]]), track(SCAN, [[sql.dup, binds]])
    end

    # Swap partition_by dynamically from :owner to :title.
    title_model = syncable_model("TitleMemo") { sync_window limit: 20, partition_by: :title }
    InstantRecord.sync(title_model)
    3.times do |i|
      binds = ["owner_#{i}", "title_#{i}"]
      expected = track(REFERENCE, [[sql.dup, binds]])
      actual = track(SCAN, [[sql.dup, binds]])
      assert_equal expected, actual
      assert_equal({ "TitleMemo" => { "title" => ["title_#{i}"] } }, actual.first["partitions"])
    end

    # Remove syncable models completely.
    InstantRecord.sync
    assert_equal track(REFERENCE, [[sql.dup, ["maya", "hi"]]]), track(SCAN, [[sql.dup, ["maya", "hi"]]])
  end

  def test_repeated_record_sql_multi_query_and_cache_isolation
    queries = [
      ['SELECT "items".* FROM "items" WHERE "items"."owner" = ? AND "items"."id" IN (?, ?, ?) ORDER BY "items"."id"', ["café", "1", 2, "1"]],
      ['SELECT "items".* FROM "items" WHERE "items"."owner" = ? AND (LOWER("items"."title") LIKE ? OR LOWER("items"."state") LIKE ?)', ["café", "%x%", "%y%"]],
      ['SELECT "items".* FROM "items" WHERE "items"."owner" = $1 AND "items"."id" IN ($2, \'a\'\'b\', 42)', ["café", "日本"]],
      ['SELECT "items".* FROM "items" WHERE "items"."owner" = \'café\'', nil],
      ['SELECT "items".* FROM "items" INNER JOIN "labels" "l" ON "l"."item_id" = "items"."id" WHERE "items"."owner" = ? AND "l"."id" = ?', ["café", 7]],
      ['SELECT "items".* FROM "items" WHERE "items"."owner" = ? OR "items"."title" = ?', ["theo", "urgent"]],
      ['INSERT INTO "items" ("id", "owner") VALUES (?, ?)', ["9", "café"]]
    ]

    # Run each sequence multiple times (cold + cached) and verify exact parity,
    # including encoding, frozenness, and order of partition values.
    4.times do
      assert_equal track(REFERENCE, queries.first(4)), track(SCAN, queries.first(4))
      queries.each do |sql, binds|
        mutable_sql = sql.dup
        expected = track(REFERENCE, [[mutable_sql, binds]])
        actual = track(SCAN, [[mutable_sql, binds]])
        assert_equal expected, actual, sql
        # Mutating caller string after record_sql must not affect subsequent calls.
        mutable_sql.replace("UPDATE items SET owner = 'mutated'")
      end
    end
  end

  def test_repeated_record_sql_only_asks_models_for_non_id_columns
    [
      ['SELECT * FROM items WHERE id = ?', ["1"], 0],
      ['SELECT * FROM items WHERE list_id IN (?, ?)', ["1", "2"], 0],
      ['SELECT * FROM items WHERE title LIKE ?', ["%a%"], 0],
      ['SELECT * FROM items WHERE owner = ?', ["maya"], 1],
      ['SELECT * FROM items WHERE title = ? AND owner = ?', ["hi", "maya"], 1]
    ].each do |sql, binds, expected_asks|
      3.times do
        asked = nil
        SCAN.track do
          asked = models_asked { SCAN.record_sql(sql.dup, binds) }
        end
        assert_equal expected_asks, asked, sql
      end
    end
  end

  def test_concurrent_record_sql_matches_reference
    templates = [
      'SELECT "items".* FROM "items" WHERE "items"."owner" = ? AND "items"."id" IN (?, ?)',
      'SELECT "items".* FROM "items" WHERE "items"."owner" = ? ORDER BY "items"."id" DESC LIMIT ?',
      'SELECT "items".* FROM "items" WHERE "items"."owner" = \'o\'\'connor\' AND "items"."id" = ?'
    ]

    # Precompute expected partition hashes from un-prepended reference.
    expected_by_idx = 12.times.map do |i|
      sql = templates[i % templates.length]
      binds = ["owner_#{i}", "id_#{i}", "id_#{i + 1}"]
      REFERENCE.send(:extract_outer_partitions, sql, ["items"], binds)
    end

    threads = 4.times.map do |t|
      Thread.new do
        25.times do |iter|
          idx = (t * 3 + iter) % 12
          sql = templates[idx % templates.length].dup
          binds = ["owner_#{idx}", "id_#{idx}", "id_#{idx + 1}"]
          got = SCAN.send(:extract_outer_partitions, sql, ["items"], binds)
          raise "Mismatch for idx=#{idx}: #{got.inspect} != #{expected_by_idx[idx].inspect}" unless got == expected_by_idx[idx]

          plan = SCAN.send(:compile_sql_plan, sql)
          raise "Unexpected plan for #{sql.inspect}" unless plan.tables == ["items"] && plan.frozen?
        end
      end
    end
    threads.each(&:join)
  end

  def test_non_string_and_invalid_utf8_fallback
    [nil, 123, :select, "SELECT * FROM items WHERE owner = 'x'\xFF", "\xC3SELECT * FROM items WHERE owner = 'x'",
     "SELECT * FROM items WHERE owner = 'x'".b, "SELECT * FROM items WHERE owner = 'x'".encode("UTF-16LE")].each do |input|
      assert_equal outcome { REFERENCE.track { REFERENCE.record_sql(input, nil) } },
        outcome { SCAN.track { SCAN.record_sql(input, nil) } }, input.inspect
    end

    ["'a\xFFb'", "'abc'".b, "'abc'".encode("UTF-16LE"), nil, 42].each do |expr|
      assert_same_answer(:resolve_value, expr, nil, 0)
    end
  end

  def test_single_table_foreign_predicates_and_rebound_aliases_match_across_cached_calls
    queries = [
      ["SELECT items.* FROM items INNER JOIN (SELECT 1 AS item_id) sub ON sub.item_id = items.id WHERE sub.item_id = 1", nil],
      ["SELECT * FROM items i LEFT JOIN (SELECT 1) sub ON 1=1 WHERE sub.owner = 'maya'", nil],
      ["SELECT * FROM items i JOIN (SELECT 1) bar AS items ON 1=1 WHERE items.owner = 'x'", nil],
      ["SELECT * FROM items i JOIN (SELECT 1) bar AS items ON 1=1 WHERE items.id = ?", [7]],
      ["SELECT * FROM items JOIN set AS s ON s.id = items.id WHERE s.id = ?", [9]]
    ]

    queries.each do |sql, binds|
      expected = track(REFERENCE, [[sql, binds]])
      3.times do |attempt|
        assert_equal expected, track(SCAN, [[sql, binds]]), "attempt #{attempt + 1} for #{sql.inspect}"
      end
    end
  end

  def test_doubled_quotes_before_where_stop_at_compound_keywords
    doubled_20 = "''" * 20
    doubled_16 = "''" * 16
    queries = [
      "SELECT 'a#{doubled_20}a', ( id = 1 UNION SELECT 2) FROM items WHERE x = 1",
      "SELECT 'a#{doubled_16}a', 'id = 1 UNION x' FROM items WHERE x = 1",
      "SELECT 'a#{doubled_20}a', ( id = 1 INTERSECT SELECT 2) FROM items WHERE x = 1",
      "SELECT 'a#{doubled_20}a', ( id = 1 EXCEPT SELECT 2) FROM items WHERE x = 1"
    ]

    queries.each do |sql|
      expected = track(REFERENCE, [[sql, nil]])
      3.times do |attempt|
        assert_equal expected, track(SCAN, [[sql, nil]]), "attempt #{attempt + 1} for #{sql.inspect}"
      end
    end
  end

  private

  def models_asked
    times = 0
    models = InstantRecord.method(:syncable_models)
    InstantRecord.define_singleton_method(:syncable_models) do
      times += 1
      models.call
    end
    yield
    times
  ensure
    InstantRecord.define_singleton_method(:syncable_models, models)
  end

  def pick(list) = list[@random.rand(list.size)]

  def noise = Array.new(@random.rand(20)) { pick(ATOMS) }.join(pick(["", " "]))

  def condition
    case @random.rand(5)
    when 0, 1 then "#{pick(COLUMNS)} = #{pick(VALUES)}"
    when 2 then "#{pick(COLUMNS)} IN (#{Array.new(1 + @random.rand(4)) { pick(VALUES) }.join(", ")})"
    when 3 then "(#{condition})"
    else "#{condition} #{pick(%w[AND AND OR])} #{condition}"
    end
  end

  def select = "SELECT #{pick(["*", "'q''s'", "(SELECT ?)"])} FROM #{pick(SOURCES)} WHERE #{condition}#{pick(ENDINGS)}"

  def broken(sql) = sql.dup.insert(@random.rand(sql.length + 1), pick(ATOMS))

  # One or two predicates, each a list of bind marks or literals, with repeats.
  def list_query
    binds = []
    predicates = Array.new(1 + @random.rand(2)) do
      size = 1 + @random.rand(80)
      items = Array.new(size) { @random.rand(2).zero? ? "?" : pick(LIST_LITERALS) }
      items = Array.new(size, "?") if @random.rand(2).zero?
      pool = pick([LIST_BINDS, ["a", "b", 1], (1..60).to_a])
      items.count("?").times { binds << (@random.rand(300).zero? ? nil : pick(pool)) }
      format(pick(LISTS), items.join(pick([", ", ","])))
    end
    ["SELECT * FROM items WHERE #{predicates.join(" AND ")}", binds]
  end

  def track(tracker, queries)
    reads = tracker.track { queries.each { |sql, binds| tracker.record_sql(sql, binds) } }
    [reads, details(reads["partitions"])]
  end

  # Order, encoding and frozenness of the values as they leave the query.
  def assert_same_values(sql, binds)
    assert_equal(*[REFERENCE, SCAN].map do |tracker|
      result = tracker.send(:extract_outer_partitions, sql, ["items"], binds)
      [result, details(result)]
    end)
  end

  def details(partitions)
    partitions.map do |name, columns|
      [name, columns.frozen?, columns.map { |column, values| [column, values.map { |v| [v.b, v.encoding, v.frozen?] }] }]
    end
  end

  # UTF-8 first, and forms the scan hands to the original.
  def encodings(text)
    [text, text, text, text.b, text.dup.force_encoding("US-ASCII"), text.encode("Shift_JIS", undef: :replace),
     "#{text}\xFF", "\xC3#{text}"]
  end

  def assert_same_scan(text, binds)
    before = text.b
    METHODS.each { |name| assert_same_answer(name, text) }
    KEYWORDS.each { |keyword| assert_same_answer(:find_top_level_keyword, text, keyword) }
    assert_same_answer(:resolve_in_values, text, binds, 0)
    reference = outcome { REFERENCE.track { REFERENCE.record_sql(text, binds) } }
    assert_equal reference, outcome { SCAN.track { SCAN.record_sql(text, binds) } }, text.inspect
    assert_equal before, text.b, "the scan changed its input"
    reference.first == :ok && reference[1]["partitions"].any?
  end

  def assert_same_answer(name, *arguments)
    assert_equal outcome { REFERENCE.send(name, *arguments) }, outcome { SCAN.send(name, *arguments) },
      "#{name} #{arguments.inspect}"
  end

  # An answer with its encodings, or the error.
  def outcome
    value = yield
    [:ok, value, Array(value).map { |item| item.encoding if item.is_a?(String) }]
  rescue StandardError => error
    [:raised, error.class, error.message]
  end
end
