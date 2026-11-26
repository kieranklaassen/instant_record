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
  ENDINGS = ["", "", " ORDER BY x LIMIT ?", " GROUP BY x", ";", " UNION SELECT * FROM labels WHERE owner = ?"].freeze

  EDGES = [
    "", "'", "''", "'''", "''''", "(", ")", "()", "(')')", "((a) AND (b))", "(a) AND (b)", "((a)", "a)(", ",", ",,", "a,", "'a,b',(c,d),e",
    "(a 'un", "(a = ')'", "('a''b')", "'a''b', c", "OR", "'x'OR'y'", "(x OR y)",
    "SELECT * FROM items WHERE owner = 'a''b' AND id IN (?, ?)",
    "SELECT 'q''s' FROM items WHERE owner = ? ORDER BY id",
    "WITH t AS (SELECT * FROM labels WHERE owner = 'z') SELECT * FROM items WHERE owner = 'é'",
    "-- it's (\nSELECT * FROM items WHERE (owner = ?)",
    "SELECT * FROM items WHERE owner = 'x' UNION SELECT * FROM items WHERE owner = 'y'"
  ].freeze

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

  private

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
