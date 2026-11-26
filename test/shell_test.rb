require "test_helper"
require "instant_record/shell"
require "sqlite3"
require "tmpdir"

class ShellTest < ActiveSupport::TestCase
  setup do
    reset_instant_record_tables!
    @shells = Pathname(Dir.mktmpdir("instant_record_shell_test"))
    @previous_root = InstantRecord::Shell.root
    @previous_models = InstantRecord::Shell.instance_variable_get(:@models)
    @previous_serializer = InstantRecord::Shell.instance_variable_get(:@identity_serializer)
    @previous_deserializer = InstantRecord::Shell.instance_variable_get(:@identity_deserializer)
    InstantRecord::Shell.root = @shells
    InstantRecord::Shell.models = nil
    InstantRecord::Shell.identity_serializer = nil
    InstantRecord::Shell.identity_deserializer = nil
  end

  teardown do
    InstantRecord::Shell.root = @previous_root
    InstantRecord::Shell.models = @previous_models
    InstantRecord::Shell.identity_serializer = @previous_serializer
    InstantRecord::Shell.identity_deserializer = @previous_deserializer
    InstantRecord.sync
    FileUtils.rm_rf(@shells)
  end

  test "BrowserMigrations.schema_ddl produces ordered SQLite DDL and version" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "db/migrate"))
      File.write(File.join(dir, "db/schema.rb"), <<~RUBY)
        ActiveRecord::Schema[8.1].define(version: 2026_11_21_000002) do
        end
      RUBY
      File.write(File.join(dir, "db/migrate/20261121000001_create_widgets.rb"), <<~RUBY)
        class CreateWidgets < ActiveRecord::Migration[8.1]
          def change
            create_table :widgets, id: :string do |t|
              t.string :name, null: false
              t.timestamps
            end
          end
        end
      RUBY
      File.write(File.join(dir, "db/migrate/20261121000002_add_kind_to_widgets.rb"), <<~RUBY)
        class AddKindToWidgets < ActiveRecord::Migration[8.1]
          def change
            add_column :widgets, :kind, :string, default: "standard", null: false
            add_index :widgets, :kind
          end
        end
      RUBY

      ddl = InstantRecord::Compiler::BrowserMigrations.schema_ddl(root: dir)
      assert_equal 20261121000002, ddl[:version]
      assert_equal 3, ddl[:statements].size

      db = SQLite3::Database.new(":memory:")
      ddl[:statements].each { |sql| db.execute(sql) }
      columns = db.execute("PRAGMA table_info('widgets')").map { |row| row[1] }
      assert_equal %w[id name created_at updated_at kind], columns
      indexes = db.execute("PRAGMA index_list('widgets')").map { |row| row[1] }
      assert_includes indexes, "index_widgets_on_kind"
      db.close
    end
  end

  test "build reuses SyncScope.visible and SyncWindow and stamps SyncMetadata" do
    item_model = syncable_model("ScopedWindowItem") do
      sync_window limit: 2
      syncable_to { |who| who&.id ? where(state: ["public", who.id]) : where(state: "public") }
    end
    InstantRecord.sync(item_model)

    on_server do
      item_model.create!(id: "pub-1", title: "Oldest public", state: "public", created_at: 3.minutes.ago, updated_at: 3.minutes.ago)
      item_model.create!(id: "pub-2", title: "Middle public", state: "public", created_at: 2.minutes.ago, updated_at: 2.minutes.ago)
      item_model.create!(id: "ada-1", title: "Ada newest", state: "ada", created_at: 1.minute.ago, updated_at: 1.minute.ago)
      item_model.create!(id: "ben-1", title: "Ben private", state: "ben", created_at: 30.seconds.ago, updated_at: 30.seconds.ago)
    end

    ada = Person.new("ada")
    shell = InstantRecord::Shell.build(identity: ada, models: [item_model])

    assert File.file?(shell.path)
    assert InstantRecord::Shell.valid_sqlite?(File.binread(shell.path))
    assert_equal InstantRecord::Change.maximum(:id), shell.cursor

    db = SQLite3::Database.new(shell.path, results_as_hash: true)
    ids = db.execute("SELECT id FROM items ORDER BY id").map { |r| r["id"] }
    refute_includes ids, "ben-1", "private rows for another identity must never enter the shell"
    assert_includes ids, "ada-1"
    assert_equal ["synced"], db.execute("SELECT DISTINCT sync_state FROM items").map { |r| r["sync_state"] }

    meta = db.execute("SELECT key, value FROM instant_record_sync_metadata").to_h { |r| [r["key"], r["value"]] }
    assert_equal shell.cursor.to_s, meta["cursor"]
    assert_equal InstantRecord::SyncScope.key(ada), meta["identity"]
    assert_equal "ScopedWindowItem", meta["compiled_models"]
    assert_equal InstantRecord::Shell.fingerprint(models: [item_model]), meta["shell_fingerprint"]
    db.close
  end

  test "partition_key separates callers differing on either identity key or scope token" do
    dual = Struct.new(:token, :person_id) do
      def to_s = token.to_s
      def sync_identity_key = person_id || "anonymous"
    end

    k_anon = InstantRecord::Shell.partition_key(dual.new(nil, nil))
    k_v1 = InstantRecord::Shell.partition_key(dual.new("visitor-1", nil))
    k_v2 = InstantRecord::Shell.partition_key(dual.new("visitor-2", nil))
    k_ada_v1 = InstantRecord::Shell.partition_key(dual.new("visitor-1", "ada"))
    k_ben_v1 = InstantRecord::Shell.partition_key(dual.new("visitor-1", "ben"))

    assert_equal 5, [k_anon, k_v1, k_v2, k_ada_v1, k_ben_v1].uniq.size
  end

  test "signed tokens bind partition, holder, purpose, and lifetime" do
    item_model = syncable_model("TokenItem")
    InstantRecord.sync(item_model)
    shell = InstantRecord::Shell.build(partition: "support", models: [item_model], identity_key: nil)

    token = shell.signed_token(holder: "maya")
    found = InstantRecord::Shell.find_signed(token, partition: "support", holder: "maya")
    assert_equal shell.path, found.path

    assert_nil InstantRecord::Shell.find_signed(token, partition: "support", holder: "theo")
    assert_nil InstantRecord::Shell.find_signed(token, partition: "billing", holder: "maya")
    assert_nil InstantRecord::Shell.find_signed("forged", partition: "support", holder: "maya")
    assert_nil InstantRecord::Shell.find_signed("", partition: "support", holder: "maya")
    assert_nil InstantRecord::Shell.find_signed(token, partition: "../etc", holder: "maya")
  end

  test "valid_sqlite? requires exact 16-byte SQLite format 3 header" do
    assert InstantRecord::Shell.valid_sqlite?("SQLite format 3\x00extra".b)
    refute InstantRecord::Shell.valid_sqlite?("SQLite format 3".b)
    refute InstantRecord::Shell.valid_sqlite?("not sqlite".b)
    refute InstantRecord::Shell.valid_sqlite?(nil)
  end

  test "serializable_identity? and custom identity codec round-trip safely" do
    assert InstantRecord::Shell.serializable_identity?(nil)
    assert InstantRecord::Shell.serializable_identity?("visitor-1")
    assert InstantRecord::Shell.serializable_identity?(42)
    refute InstantRecord::Shell.serializable_identity?(Person.new("ada"))

    InstantRecord::Shell.identity_serializer = ->(p) { p.id }
    InstantRecord::Shell.identity_deserializer = ->(id) { Person.new(id) }
    assert InstantRecord::Shell.serializable_identity?(Person.new("ada"))
    dumped = InstantRecord::Shell.dump_identity(Person.new("ada"))
    assert_equal Person.new("ada"), InstantRecord::Shell.load_identity(dumped)
  end

  test "register and build_source support custom snapshot feeds" do
    item_model = syncable_model("CustomItem")
    InstantRecord.sync(item_model)
    InstantRecord::Shell.register(:custom_feed) do |name|
      {
        partition: "feed_#{name}",
        revision: 9,
        models: [item_model],
        identity_key: nil,
        snapshot: -> { { cursor: 9, records: [] } }
      }
    end

    shell = InstantRecord::Shell.build_source(:custom_feed, "alpha")
    assert_equal "feed_alpha", shell.partition
    assert_equal 9, shell.cursor
  ensure
    InstantRecord::Shell.sources.delete("custom_feed")
  end

  test "rows of several types and column lists each land as their own record says" do
    with_shell_rows_table do |rows|
      InstantRecord.sync(syncable_model("MixedItem"), rows)
      stamps = { "created_at" => "2026-01-01T00:00:00.000001Z", "updated_at" => "2026-01-01T00:00:00.000001Z" }

      built = read_shell([
        { type: "MixedItem", version: 3, attributes: stamps.merge("id" => "a", "title" => "first", "owner" => "o", "gone" => 1) },
        { type: "ShellRow", attributes: { id: "r1", flag: true, data: { "k" => [1, nil] }, day: Date.new(2026, 1, 2), ratio: 1.5 } },
        { "type" => "MixedItem", "version" => 4, "attributes" => stamps.merge("id" => "b", "title" => nil) },
        { type: "ShellRow", attributes: { "id" => "r2", "flag" => false, "data" => nil, "big" => 2**62, "bytes" => "\xFF\0".b } },
        { type: "MixedItem", attributes: stamps.merge("id" => "c", "title" => "é\0\u{1F600}", "owner" => "") },
        { type: "ShellRow", attributes: { "id" => "r3" } }
      ]) do |db|
        [
          db.execute("SELECT id, title, owner, server_version, sync_state FROM items ORDER BY id"),
          db.execute("SELECT id, flag, data, day, ratio, big, typeof(bytes) FROM shell_rows ORDER BY id")
        ]
      end

      assert_equal [
        ["a", "first", "o", 3, "synced"],
        ["b", nil, nil, 4, "synced"],
        ["c", "é\0\u{1F600}", "", 0, "synced"]
      ], built[0]
      assert_equal [
        ["r1", 1, '{"k":[1,null]}', "2026-01-02", 1.5, nil, "null"],
        ["r2", 0, nil, nil, nil, 2**62, "blob"],
        ["r3", nil, nil, nil, nil, nil, "null"]
      ], built[1]
    end
  end

  test "datetimes are stored in the runtime's format, whatever form they came in" do
    with_shell_rows_table do |rows|
      InstantRecord.sync(rows)
      forms = {
        "2026-01-28T23:59:59.999999Z" => "2026-01-28 23:59:59.999999",
        "2026-01-31T23:59:59.999999Z" => "2026-01-31 23:59:59.999999",
        "2024-02-29T00:00:00.000000Z" => "2024-02-29 00:00:00.000000",
        "2026-02-30T01:02:03.000004Z" => "2026-03-02 01:02:03.000004",
        "2026-12-31T24:00:00.000000Z" => "2027-01-01 00:00:00.000000",
        "2026-12-31T23:59:60.000000Z" => "2027-01-01 00:00:00.000000",
        "2026-01-01T00:00:00Z" => "2026-01-01 00:00:00.000000",
        "2026-01-01T00:00:00.1234567Z" => "2026-01-01 00:00:00.123456",
        "2026-01-01T01:00:00.123456+02:00" => "2025-12-31 23:00:00.123456",
        "2026-01-01 00:00:00.5 UTC" => "2026-01-01 00:00:00.500000",
        "2026-01-01T00:00:00.123456Z\n" => "2026-01-01 00:00:00.123456",
        "2026-01-01T00:00:00.123456Z".encode("US-ASCII") => "2026-01-01 00:00:00.123456",
        "2026-01-01T00:00:00.123456Z".b => "2026-01-01 00:00:00.123456",
        Time.new(2026, 1, 1, 2, 3, 4.5r, "+02:00") => "2026-01-01 00:03:04.500000",
        nil => nil
      }
      records = forms.keys.each_with_index.map { |form, i| { type: "ShellRow", attributes: { "id" => format("%02d", i), "at" => form } } }

      stored = read_shell(records) { |db| db.execute("SELECT at, typeof(at) FROM shell_rows ORDER BY id") }
      assert_equal forms.values.map { |text| [text, text ? "text" : "null"] }, stored
    end
  end

  test "a record that cannot be written raises and leaves no file behind" do
    InstantRecord.sync(syncable_model("BrokenItem"))
    good = { type: "BrokenItem", attributes: { "id" => "a", "created_at" => "2026-01-01T00:00:00Z", "updated_at" => "2026-01-01T00:00:00Z" } }
    with = ->(changes) { good.merge(attributes: good[:attributes].merge("id" => "b", **changes)) }

    {
      SQLite3::ConstraintException => good,
      ArgumentError => with.("created_at" => "not a time"),
      RuntimeError => with.("title" => Object.new),
      NameError => { type: "NoSuchShellModel", attributes: {} },
      IOError => nil
    }.each do |error, bad|
      records = Enumerator.new do |rows|
        rows << good
        bad ? rows << bad : raise(IOError, "the feed broke")
      end
      raised = assert_raises(error) { read_shell(records) }
      refute_kind_of SQLite3::BusyException, raised
      assert_empty Dir.glob(@shells.join("*.{sqlite3,tmp}*").to_s), error.name
    end
  end

  test "a model reloaded between builds is looked up again" do
    with_shell_rows_table do |rows|
      record = { type: "ReloadedItem", attributes: { "id" => "a", "title" => "t", "flag" => true, "created_at" => "2026-01-01T00:00:00Z", "updated_at" => "2026-01-01T00:00:00Z" } }
      counts = ->(db) { %w[items shell_rows].map { |table| db.get_first_value("SELECT COUNT(*) FROM #{table}") } }

      InstantRecord.sync(syncable_model("ReloadedItem"))
      assert_equal [1, 0], read_shell([record], &counts)

      rows.define_singleton_method(:name) { "ReloadedItem" }
      InstantRecord.instance_variable_set(:@synced_models, [rows])
      assert_equal [0, 1], read_shell([record], &counts)
    end
  end

  test "a build prepares one statement for each column list of a type" do
    InstantRecord.sync(syncable_model("PreparedItem"))
    record = ->(id, extra = {}) { { type: "PreparedItem", attributes: { "id" => id, "created_at" => "2026-01-01T00:00:00Z", "updated_at" => "2026-01-01T00:00:00Z" }.merge(extra) } }
    prepared = []
    count = Module.new do
      define_method(:prepare) do |sql, &block|
        prepared << sql if sql.start_with?('INSERT INTO "items"')
        super(sql, &block)
      end
    end
    opened = SQLite3::Database.method(:new)
    SQLite3::Database.define_singleton_method(:new) { |*args, **options| opened.call(*args, **options).extend(count) }
    begin
      read_shell([record.("a"), record.("b", "title" => "t"), record.("c"), record.("d", "title" => "u")])
    ensure
      SQLite3::Database.singleton_class.remove_method(:new)
    end

    assert_equal 2, prepared.size
  end

  test "connection DDL keeps the defaults a SQLite table can hold" do
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.create_table :shell_defaults, id: :string do |t|
        t.boolean :on, default: true
        t.boolean :off, default: false, null: false
        t.boolean :unset
        t.integer :zero, default: 0
        t.integer :below, default: -7
        t.decimal :price, precision: 10, scale: 2, default: "12.5"
        t.float :ratio, default: 1.5
        t.string :word, default: "007"
        t.string :empty, default: ""
        t.text :quoted, default: %q(it's "q" \\ 'x')
        t.date :day, default: "2026-01-02"
        t.datetime :moment, default: "2026-01-02 03:04:05"
        t.json :object, default: { "a" => [1, nil, "it's"] }
        t.json :scalar, default: "x"
        t.datetime :now, default: -> { "CURRENT_TIMESTAMP" }
      end

      table = InstantRecord::Shell.send(:connection_schema_statements).find { |sql| sql.start_with?('CREATE TABLE "shell_defaults"') }
      server = Class.new(ActiveRecord::Base) { self.table_name = "shell_defaults" }
      ActiveRecord::Base.connection.execute("INSERT INTO shell_defaults (id) VALUES ('one')")
      expected = server.find("one").attributes.except("now")

      assert_equal(
        {
          "on" => [1, "integer"], "off" => [0, "integer"], "unset" => [nil, "null"], "zero" => [0, "integer"],
          "below" => [-7, "integer"], "price" => [12.5, "real"], "ratio" => [1.5, "real"], "word" => ["007", "text"],
          "empty" => ["", "text"], "quoted" => [%q(it's "q" \\ 'x'), "text"], "day" => ["2026-01-02", "text"],
          "moment" => ["2026-01-02 03:04:05.000000", "text"], "object" => [%({"a":[1,null,"it's"]}), "text"],
          "scalar" => ['"x"', "text"], "now" => [nil, "null"]
        },
        stored_defaults(table, server.column_names - ["id"])
      )
      assert_equal expected, read_defaults(table).except("now")
      raise ActiveRecord::Rollback
    end
  end

  # What PostgreSQL's columns hand over, as each Rails hands it over: the
  # database's string, or (8.1.0 to 8.1.3.1) a value of a type that is not mutable.
  test "a default the SQLite table cannot hold stays where a row would be refused without it" do
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.create_table :shell_kept, id: :string do |t|
        t.time :opens, default: "10:00", null: false
        t.time :closes, default: "18:00"
      end
      table = InstantRecord::Shell.send(:connection_schema_statements).find { |sql| sql.start_with?('CREATE TABLE "shell_kept"') }

      assert_match(/"opens" \w+ NOT NULL DEFAULT '/, table)
      assert_match(/"closes" \w+[,)]/, table)
      raise ActiveRecord::Rollback
    end
  end

  test "a JSON default that cannot be decoded is not passed over" do
    broken = Object.new
    def broken.deserialize(_default) = raise(ArgumentError, "wrong number of arguments")
    column = Struct.new(:type, :default, :default_function, :cast_type) do
      def fetch_cast_type(_connection) = cast_type
    end

    assert_raises(ArgumentError) { InstantRecord::Shell.send(:sqlite_default, ActiveRecord::Base.connection, column.new(:jsonb, "{}", nil, broken)) }
    assert_nil InstantRecord::Shell.send(:sqlite_default, ActiveRecord::Base.connection, column.new(:numrange, "(1,5)", nil, broken))
    assert_equal "0", InstantRecord::Shell.send(:sqlite_default, ActiveRecord::Base.connection, column.new(:oid, "0", nil, ActiveModel::Type::Integer.new(limit: 8)))
  end

  test "a column default becomes the literal its SQLite column reads back" do
    type = ActiveRecord::Type
    reads = Struct.new(:given) { def deserialize(_) = given }
    refuses = Class.new { def deserialize(_) = raise(ArgumentError, "a Range cannot exclude its start") }.new
    {
      [:boolean, type::Boolean.new, "true"] => "1",
      [:boolean, type::Boolean.new, "false"] => "0",
      [:boolean, type::Boolean.new, true] => "1",
      [:boolean, type::Boolean.new, false] => "0",
      [:integer, type::Integer.new(limit: 8), "9007199254740993"] => "9007199254740993",
      [:integer, type::Integer.new(limit: 8), -7] => "-7",
      [:decimal, type::Decimal.new, "12.50"] => "12.5",
      [:decimal, type::Decimal.new, BigDecimal("12.50")] => "12.5",
      [:decimal, type::Decimal.new, "12345678901234567890.12345678901234567890"] => nil,
      [:decimal, type::Decimal.new, "9007199254740993"] => "9007199254740993",
      [:decimal, type::Decimal.new, "0.30000000000000004"] => nil,
      [:decimal, type::Decimal.new, "NaN"] => nil,
      [:float, type::Float.new, "1.5"] => "1.5",
      [:float, type::Float.new, "0.30000000000000004"] => "0.30000000000000004",
      [:float, type::Float.new, 1e30] => "1000000000000000000000000000000.0",
      [:float, type::Float.new, "Infinity"] => "'Infinity'",
      [:float, type::Float.new, "NaN"] => nil,
      [:string, type::String.new, "it's"] => "'it''s'",
      [:text, type::Text.new, "a\\b"] => "'a\\b'",
      [:uuid, type::String.new, "00000000-0000-0000-0000-000000000001"] => "'00000000-0000-0000-0000-000000000001'",
      [:date, type::Date.new, "2026-01-02"] => "'2026-01-02'",
      [:date, type::Date.new, Date.new(2026, 1, 2)] => "'2026-01-02'",
      [:date, reads.new(Float::INFINITY), "infinity"] => nil,
      [:datetime, type::DateTime.new, "2026-01-02 03:04:05.1"] => "'2026-01-02 03:04:05.100000'",
      [:datetime, reads.new(Float::INFINITY), "infinity"] => nil,
      [:jsonb, type::Json.new, '{"a": 1}'] => %('{"a":1}'),
      [:jsonb, type::Json.new, "false"] => "'false'",
      [:jsonb, type::Json.new, "null"] => "'null'",
      [:jsonb, type::Json.new, "bad"] => nil,
      [:jsonb, reads.new(101.times.reduce([]) { |inner, _| [inner] }), "deep"] => nil,
      [:jsonb, type::Json.new, '"x"'] => %('"x"'),
      [:jsonb, type::Json.new, "9223372036854775808"] => nil,
      [:jsonb, reads.new([]), "{}"] => "'[]'",
      [:string, reads.new(%w[a b]), "{a,b}"] => nil,
      [:integer, reads.new([1, 2]), "{1,2}"] => nil,
      [:boolean, reads.new([true]), "{t}"] => nil,
      [:time, type::Time.new, "03:04:05"] => nil,
      [:numrange, refuses, "(1,5)"] => nil,
      [:money, type::Decimal.new, "12.5"] => nil,
      [:string, type::String.new, nil] => nil,
      [:json, type::Json.new, nil] => nil,
      [:json, type::Json.new, "1e400"] => nil,
      [:integer, reads.new(2**63), "9223372036854775808"] => nil,
      [:decimal, type::Decimal.new, "Infinity"] => nil,
      [:binary, reads.new("hi".b), "\\x6869"] => "'hi'",
      [:binary, reads.new("\xFF".b), "\\xff"] => nil,
      [:binary, reads.new("\0".b), "\\x00"] => nil
    }.each do |(kind, cast_type, default), literal|
      column = Struct.new(:type, :default, :default_function, :cast_type) do
        def fetch_cast_type(_) = cast_type
      end.new(kind, default, nil, cast_type)
      actual = InstantRecord::Shell.send(:sqlite_default, ActiveRecord::Base.connection, column)
      literal.nil? ? assert_nil(actual, [kind, default].inspect) : assert_equal(literal, actual, [kind, default].inspect)
    end
  end

  class Client < ActiveRecord::Base
    self.abstract_class = true
  end

  private

  # A second table whose columns differ from the items table's, for a model
  # named ShellRow.
  def with_shell_rows_table
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.create_table :shell_rows, id: :string do |t|
        t.boolean :flag
        t.json :data
        t.date :day
        t.float :ratio
        t.bigint :big
        t.binary :bytes
        t.datetime :at
      end
      yield(Class.new(ActiveRecord::Base) do
        self.table_name = "shell_rows"
        define_singleton_method(:name) { "ShellRow" }
      end)
      raise ActiveRecord::Rollback
    end
  end

  # Builds a shell holding the records and hands its database to the block.
  def read_shell(records)
    FileUtils.rm_f(Dir.glob(@shells.join("*.sqlite3").to_s))
    shell = InstantRecord::Shell.build(partition: "rows", revision: 1, models: [], identity_key: nil) { { cursor: 1, records: records } }
    return unless block_given?

    database = SQLite3::Database.new(shell.path)
    yield database
  ensure
    database&.close
  end

  def stored_defaults(table, names)
    database = SQLite3::Database.new(":memory:")
    database.execute(table)
    database.execute("INSERT INTO shell_defaults (id) VALUES ('one')")
    names.to_h { |name| [name, database.execute(%(SELECT "#{name}", typeof("#{name}") FROM shell_defaults)).first] }
  ensure
    database&.close
  end

  def read_defaults(table)
    Client.establish_connection(adapter: "sqlite3", database: ":memory:")
    Client.connection.execute(table)
    Client.connection.execute("INSERT INTO shell_defaults (id) VALUES ('one')")
    Class.new(Client) { self.table_name = "shell_defaults" }.find("one").attributes
  ensure
    Client.remove_connection
  end
end
