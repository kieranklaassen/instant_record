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
    "SELECT * FROM items WHERE owner = 'x' AND \"union\" = 'é''EXCEPT'"
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
