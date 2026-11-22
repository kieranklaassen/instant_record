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
end
