require "test_helper"
require "tmpdir"
require "instant_record/compiler"

# SyncMetadata.set on the server, where every applied mutation calls it.
class SyncMetadataTest < Minitest::Test
  Meta = InstantRecord::SyncMetadata

  def setup
    reset_instant_record_tables!
  end

  def test_set_then_get_stores_the_value_as_a_string
    on_server do
      Meta.set("a", "one")
      Meta.set("b", 42)
      Meta.set("c", nil)
      Meta.set("d", "it's a \\ \"quoted\" ? :value %s é")
    end

    assert_equal "one", Meta.get("a")
    assert_equal "42", Meta.get("b")
    assert_equal "", Meta.get("c")
    assert_equal "it's a \\ \"quoted\" ? :value %s é", Meta.get("d")
    assert_nil Meta.get("missing")
  end

  # The key can carry a record id the client chose.
  def test_a_nul_in_the_key_or_the_value_is_stored
    on_server do
      Meta.set("a\0b", "one")
      Meta.set("a\0b", "two")
      Meta.set("c", "x\0y")
      Meta.set("c", "it's plain")
      Meta.set("d", "x\0y")
    end

    assert_equal "two", Meta.get("a\0b")
    assert_equal "it's plain", Meta.get("c")
    assert_equal "x\0y", Meta.get("d")
    assert_equal 3, Meta.count
  end

  def test_a_mutation_whose_record_id_holds_a_nul_is_applied
    model = syncable_model("NulItem")
    InstantRecord.sync(model)
    result = on_server do
      InstantRecord::MutationApplier.apply(id: "m1", record_type: "NulItem", record_id: "a\0b",
        operation: "create", changes: { "title" => "t" })
    end

    assert_equal "applied", result[:status]
  ensure
    InstantRecord.sync
  end

  def test_other_encodings_are_stored
    on_server { Meta.set("u", "h\u00e9".encode("UTF-16LE")) }

    assert_equal 1, Meta.where(key: "u").count
  end

  def test_a_relation_scope_does_not_replace_the_value
    on_server { Meta.where(value: "scoped").scoping { Meta.set("k", "given") } }

    assert_equal "given", Meta.get("k")
  end

  def test_a_database_without_the_upsert_path_stores_the_exact_value
    on_server do
      Meta.set("k", "y")
      age("k")
      adapter = Meta.connection_pool.with_connection(&:itself)
      adapter.define_singleton_method(:adapter_name) { "Trilogy" }
      Meta.set("k", "Y")
    ensure
      adapter&.singleton_class&.send(:remove_method, :adapter_name)
    end

    row = Meta.find("k")
    assert_equal "Y", row.value
    assert_operator row.updated_at, :>, long_ago
  end

  # The read is inside the savepoint too, so a caller that rescues a failed
  # write can go on with its transaction.
  def test_postgres_writes_inside_a_savepoint
    adapter = Meta.connection_pool.with_connection(&:itself)
    adapter.define_singleton_method(:adapter_name) { "PostgreSQL" }
    statements = on_server do
      Meta.transaction do
        Meta.get("warm")
        sql_statements { Meta.set("k", "one") }
      end
    end

    assert_match(/\ASAVEPOINT/, statements.first)
    assert_match(/\ARELEASE SAVEPOINT/, statements.last)
    assert_equal 4, statements.size
    assert_equal "one", Meta.get("k")
  ensure
    adapter&.singleton_class&.send(:remove_method, :adapter_name)
  end

  def test_overwrite_keeps_created_at_and_moves_updated_at
    on_server do
      Meta.set("k", "one")
      Meta.set("other", "untouched")
      age("k")
      Meta.set("k", "it's two")
    end

    row = Meta.find("k")
    assert_equal "it's two", row.value
    assert_equal long_ago, row.created_at
    assert_in_delta Time.now.to_f, row.updated_at.to_f, 5
    assert_equal "untouched", Meta.get("other")
    assert_equal 2, Meta.count
  end

  def test_setting_the_stored_value_again_leaves_updated_at
    on_server do
      Meta.set("k", "same")
      age("k")
      Meta.set("k", "same")
    end

    assert_equal [long_ago, long_ago], Meta.find("k").then { |row| [row.created_at, row.updated_at] }
  end

  def test_a_null_value_is_replaced
    on_server do
      Meta.create!(key: "k", value: nil)
      age("k")
      Meta.set("k", "now set")
    end

    row = Meta.find("k")
    assert_equal "now set", row.value
    assert_operator row.updated_at, :>, long_ago
  end

  def test_new_row_is_stamped_with_the_application_clock
    before = Time.now
    on_server { Meta.set("k", "one") }
    row = Meta.find("k")

    assert_operator row.created_at, :>=, before.floor(6)
    assert_operator row.created_at, :<=, Time.now
    assert_equal row.created_at, row.updated_at
  end

  def test_set_belongs_to_the_callers_transaction
    on_server do
      Meta.set("kept", "before")
      Meta.transaction do
        Meta.set("kept", "inside")
        Meta.set("new", "inside")
        raise ActiveRecord::Rollback
      end
    end

    assert_equal "before", Meta.get("kept")
    assert_nil Meta.get("new")
  end

  def test_a_rolled_back_savepoint_leaves_the_outer_transaction_usable
    on_server do
      Meta.transaction do
        Meta.set("outer", "one")
        Meta.transaction(requires_new: true) do
          Meta.set("outer", "two")
          raise ActiveRecord::Rollback
        end
        Meta.set("after", "three")
      end
    end

    assert_equal "one", Meta.get("outer")
    assert_equal "three", Meta.get("after")
  end

  def test_a_read_inside_the_query_cache_sees_the_write
    on_server do
      Meta.cache do
        Meta.set("k", "one")
        assert_equal "one", Meta.get("k")
        Meta.set("k", "two")
        assert_equal "two", Meta.get("k")
      end
    end
  end

  def test_concurrent_sets_of_one_new_key_leave_one_row
    with_file_database do
      on_server do
        10.times do |round|
          barrier = Queue.new
          threads = 4.times.map do |n|
            Thread.new { barrier.pop; Meta.connection_pool.with_connection { Meta.set("round#{round}", "writer#{n}") } }
          end
          4.times { barrier << true }
          threads.each(&:value)
        end
      end

      assert_equal 10, Meta.count
      Meta.pluck(:value).each { |value| assert_match(/\Awriter[0-3]\z/, value) }
    end
  end

  def test_the_browser_still_finds_and_saves_the_record
    in_browser do
      Meta.set("k", 1)
      age("k")
      statements = sql_statements { Meta.set("k", 2) }
      assert_match(/\ASELECT/, statements.first)
      assert statements.none? { |sql| sql.include?("ON CONFLICT") }
    end

    row = Meta.find("k")
    assert_equal "2", row.value
    assert_equal long_ago, row.created_at
  end

  def test_the_server_writes_in_one_statement
    on_server do
      assert_equal 1, sql_statements { Meta.set("k", "one") }.size
      assert_equal 1, sql_statements { Meta.set("k", "two") }.size
      assert_equal 1, sql_statements { Meta.set("k", "two") }.size
      Meta.transaction do
        Meta.get("k")
        assert_equal 1, sql_statements { Meta.set("k", "three") }.size
      end
    end
  end

  def test_the_compiled_source_holds_only_the_browser_branch
    path = File.expand_path("../lib/instant_record/sync_metadata.rb", __dir__)
    lowered = InstantRecord::Compiler::AstLowerer.lower(File.read(path))
    body = lowered[/def self\.set.*?(?=def self\.delete)/m].lines.map(&:strip).reject(&:empty?)

    assert_equal [
      "def self.set(key, value)",
      "record = find_or_initialize_by(key: key)",
      "record.update!(value: value.to_s)",
      "end"
    ], body
  end

  private

  def long_ago = Time.utc(2020, 1, 2, 3, 4, 5)

  def age(key)
    Meta.where(key: key).update_all(created_at: long_ago, updated_at: long_ago)
  end

  def sql_statements
    seen = []
    callback = ->(*, payload) { seen << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    seen
  end

  # Threads need a database more than one connection can open.
  def with_file_database
    Dir.mktmpdir do |dir|
      Meta.establish_connection(adapter: "sqlite3", database: File.join(dir, "meta.sqlite3"), pool: 8, timeout: 5000)
      Meta.connection_pool.with_connection do |connection|
        connection.create_table(Meta.table_name, id: false) do |t|
          t.string :key, null: false, primary_key: true
          t.string :value
          t.timestamps
        end
      end
      yield
    ensure
      Meta.remove_connection
      Meta.reset_column_information
    end
  end
end
