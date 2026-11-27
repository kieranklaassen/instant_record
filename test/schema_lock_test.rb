require "test_helper"
require "instant_record/compiler"
require "fileutils"
require "json"
require "tmpdir"

class SchemaLockTest < ActiveSupport::TestCase
  GEM_ROOT = File.expand_path("..", __dir__)
  V1 = 20261120000001
  V2 = 20261120000002
  V3 = 20261120000003

  teardown do
    InstantRecord.clear_outbox_upcasters!
  end

  test "write! and verify emit db/instant_record_lock.json and replay every historical version with pending outbox rows to HEAD" do
    Dir.mktmpdir do |dir|
      setup_app_v1(dir)
      lock_v1 = InstantRecord::Compiler.lock_schema(root: dir)

      assert_equal 1, lock_v1["lockfile_version"]
      assert_equal 20261120000001, lock_v1["schema_version"]
      assert_equal [20261120000001], lock_v1["versions"].map { |v| v["version"] }
      assert File.file?(File.join(dir, "db/instant_record_lock.json"))

      add_migration_v2(dir)
      add_migration_v3(dir)

      # Stale lockfile is caught before re-locking.
      stale_report = InstantRecord::Compiler.verify_schema(root: dir)
      refute stale_report.ok?
      assert_match(/lockfile is at 20261120000001/, stale_report.to_s)

      # Re-locking preserves historical v1 and appends v2 and v3.
      lock_v3 = InstantRecord::Compiler.lock_schema(root: dir)
      assert_equal [20261120000001, 20261120000002, 20261120000003], lock_v3["versions"].map { |v| v["version"] }

      report = InstantRecord::Compiler.verify_schema(root: dir)
      assert report.ok?, report.to_s
      assert_equal [20261120000001, 20261120000002, 20261120000003], report.replayed_versions
      assert_match(/replay 20261120000001/, report.to_s)
      assert_match(/pending outbox row\(s\) preserved & compatible/, report.to_s)
    end
  end

  test "editing or deleting a published migration fails both lock_schema and verify_schema" do
    Dir.mktmpdir do |dir|
      setup_app_v1(dir)
      InstantRecord::Compiler.lock_schema(root: dir)

      # Tamper with the published v1 migration.
      File.write(File.join(dir, "db/migrate/20261120000001_create_notes.rb"), <<~RUBY)
        class CreateNotes < ActiveRecord::Migration[8.1]
          def change
            create_table :notes, id: :string do |t|
              t.string :title, null: false
              t.text :body, null: false, default: ""
              t.string :tampered_col
              t.integer :server_version, null: false, default: 0
              t.string :sync_state, null: false, default: "synced"
              t.timestamps
            end
          end
        end
      RUBY

      assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler.lock_schema(root: dir)
      end

      report = InstantRecord::Compiler.verify_schema(root: dir)
      refute report.ok?
      assert_match(/published migration 20261120000001 changed/, report.to_s)
    end
  end

  test "upgrade-ladder replay catches a migration that breaks on non-empty tables from an earlier version" do
    Dir.mktmpdir do |dir|
      setup_app_v1(dir)
      InstantRecord::Compiler.lock_schema(root: dir)

      # SQLite rejects ADD COLUMN ... NOT NULL without a DEFAULT on a non-empty table,
      # even though it succeeds on an empty table!
      File.write(File.join(dir, "db/schema.rb"), <<~RUBY)
        ActiveRecord::Schema[8.1].define(version: 2026_11_20_000002) do
        end
      RUBY
      File.write(File.join(dir, "db/migrate/20261120000002_add_required_author.rb"), <<~RUBY)
        class AddRequiredAuthor < ActiveRecord::Migration[8.1]
          def change
            add_column :notes, :author, :string, null: false
          end
        end
      RUBY

      InstantRecord::Compiler.lock_schema(root: dir)
      report = InstantRecord::Compiler.verify_schema(root: dir)

      refute report.ok?
      assert_match(/replay 20261120000001/, report.to_s)
      assert_match(/Cannot add a NOT NULL column with default value NULL/i, report.to_s)
    end
  end

  test "upgrade-ladder replay catches un-upcasted column renames in pending outbox mutations and passes once upcast_outbox is declared" do
    Dir.mktmpdir do |dir|
      setup_app_v1(dir)
      InstantRecord::Compiler.lock_schema(root: dir)

      # v2 renames `body` -> `content` via companion SQLite migration.
      File.write(File.join(dir, "db/schema.rb"), <<~RUBY)
        ActiveRecord::Schema[8.1].define(version: 2026_11_20_000002) do
        end
      RUBY
      File.write(File.join(dir, "db/migrate/20261120000002_rename_body_to_content.rb"), <<~RUBY)
        class RenameBodyToContent < ActiveRecord::Migration[8.1]
          def change
            rename_column :notes, :body, :content
          end
        end
      RUBY
      FileUtils.mkdir_p(File.join(dir, "db/browser_migrate"))
      File.write(
        File.join(dir, "db/browser_migrate/20261120000002_rename_body_to_content.sql"),
        'ALTER TABLE "notes" RENAME COLUMN "body" TO "content";'
      )

      InstantRecord::Compiler.lock_schema(root: dir)

      # Without upcast_outbox, pending v1 outbox rows still carry `body`, which is missing at HEAD!
      without_upcaster = InstantRecord::Compiler.verify_schema(root: dir)
      refute without_upcaster.ok?
      assert_match(/pending OutboxMutation from schema 20261120000001 for Note carries column\(s\) body missing at HEAD/, without_upcaster.to_s)
      assert_match(/upcast_outbox/, without_upcaster.to_s)

      # Declare an upcast_outbox transform on the model: now CI replay passes!
      note_model = Class.new(ActiveRecord::Base) do
        self.table_name = "notes"
        define_singleton_method(:name) { "Note" }
        include InstantRecord::Syncable

        upcast_outbox from: 20261120000001, to: 20261120000002 do |changes|
          changes["content"] = changes.delete("body") if changes.key?("body")
          changes
        end
      end

      with_upcaster = InstantRecord::Compiler.verify_schema(root: dir, models: [note_model])
      assert with_upcaster.ok?, with_upcaster.to_s
    end
  end

  test "Compiler.doctor integrates schema lock verification when root is provided" do
    Dir.mktmpdir do |dir|
      app_dir = File.join(dir, "app")
      setup_app_v1(app_dir)

      # Minimal fake toolchain that satisfies native doctor checks.
      tools = File.join(dir, "tools")
      FileUtils.mkdir_p(File.join(tools, "spinel/bin"))
      FileUtils.mkdir_p(File.join(tools, "spinel/lib"))
      FileUtils.mkdir_p(File.join(tools, "sqlite"))
      FileUtils.mkdir_p(File.join(tools, "cache"))
      %w[spinel/bin/spinel spinel/bin/spin roundhouse].each do |rel|
        path = File.join(tools, rel)
        File.write(path, "#!/bin/sh\n")
        File.chmod(0o755, path)
      end
      File.write(File.join(tools, "spinel/lib/libspinel_rt.a"), "rt")
      File.write(File.join(tools, "sqlite/sqlite3.c"), "/* sqlite */\n")

      tc_file = File.join(tools, "toolchain.env")
      File.write(tc_file, <<~ENV)
        SPINEL_HOME=#{tools}/spinel
        ROUNDHOUSE_BIN=#{tools}/roundhouse
        SQLITE_SRC=#{tools}/sqlite
        CACHE=#{tools}/cache
      ENV

      # Missing lockfile fails doctor.
      missing_report = InstantRecord::Compiler.doctor(toolchain: tc_file, target: :native, root: app_dir)
      refute missing_report.ok?
      assert_match(/\[ERROR\s+\] schema:lockfile/, missing_report.to_s)

      # Once locked, doctor passes toolchain + schema lock replay checks.
      InstantRecord::Compiler.lock_schema(root: app_dir)
      ok_report = InstantRecord::Compiler.doctor(toolchain: tc_file, target: :native, root: app_dir)
      assert ok_report.ok?, ok_report.to_s
      assert_match(/schema:replay 20261120000001/, ok_report.to_s)
    end
  end

  test "demo migrations generate and pass full upgrade-ladder lockfile verification" do
    demo_root = File.join(GEM_ROOT, "demo")
    migration_paths = [
      File.join(GEM_ROOT, "db/migrate"),
      File.join(demo_root, "db/migrate")
    ]
    Dir.mktmpdir do |dir|
      lock_path = File.join(dir, "instant_record_lock.json")
      InstantRecord::Compiler::SchemaLock.write!(
        root: demo_root,
        migration_paths: migration_paths,
        lock_path: lock_path
      )
      report = InstantRecord::Compiler::SchemaLock.verify(
        root: demo_root,
        migration_paths: migration_paths,
        lock_path: lock_path
      )
      assert report.ok?, report.to_s
      assert_operator report.replayed_versions.size, :>=, 15
    end
  end

  test "verify stops at a missing lockfile" do
    in_app do |dir|
      lock_path = File.join(dir, "db/instant_record_lock.json")
      report = InstantRecord::Compiler.verify_schema(root: dir)

      assert_equal lock_path, report.lock_path
      assert_checks report, ["lockfile", :error, "missing #{lock_path} (run `bin/rails instant_record:schema:lock`)"]
      assert_empty report.replayed_versions
    end
  end

  test "verify stops at a lockfile it cannot use" do
    in_app do |dir|
      ["{", "[]", "null", '{"lockfile_version":2,"versions":[]}', '{"lockfile_version":1,"versions":{}}'].each do |content|
        File.write(File.join(dir, "db/instant_record_lock.json"), content)
        report = InstantRecord::Compiler.verify_schema(root: dir)

        assert_checks report, ["lockfile", :error, "invalid or unsupported lockfile format"]
        assert_empty report.replayed_versions
      end
    end
  end

  test "verify stops when the migrations cannot be planned" do
    in_app do |dir|
      InstantRecord::Compiler.lock_schema(root: dir)
      schema_path = File.join(dir, "db/schema.rb")
      File.delete(schema_path)
      report = InstantRecord::Compiler.verify_schema(root: dir)

      assert_checks report,
        ["lockfile", :ok, "v1 (1 versions)"],
        ["migrations plan", :error, "Missing #{schema_path}"]
      assert_empty report.replayed_versions
    end
  end

  test "verify reports a stale schema version and unrecorded migration, then stops before replay" do
    in_app do |dir|
      InstantRecord::Compiler.lock_schema(root: dir)
      add_migration_v2(dir)
      report = InstantRecord::Compiler.verify_schema(root: dir)

      assert_checks report,
        ["lockfile", :ok, "v1 (1 versions)"],
        ["schema version", :error, "lockfile is at #{V1}, db/schema.rb is at #{V2} (run `bin/rails instant_record:schema:lock`)"],
        ["migration history", :error, "migration #{V2} is not recorded in db/instant_record_lock.json (run `bin/rails instant_record:schema:lock`)"]
      assert_empty report.replayed_versions
    end
  end

  test "a wrong schema version or baseline alone does not stop the replay" do
    in_app do |dir|
      InstantRecord::Compiler.lock_schema(root: dir)

      edit_lock(dir) { |lock| lock["baseline"] = 5 }
      report = InstantRecord::Compiler.verify_schema(root: dir)
      assert_includes report.checks.map(&:to_a), ["schema baseline", :error, "lockfile baseline 5 differs from configured nil"]
      assert_equal [V1], report.replayed_versions

      edit_lock(dir) { |lock| lock["schema_version"] = 7 }
      report = InstantRecord::Compiler.verify_schema(root: dir)
      assert_equal ["lockfile", "schema version", "migration history", "fresh HEAD schema", "replay #{V1}"], report.checks.map(&:name)
      assert_equal "0 step(s) -> 7, 1 pending outbox row(s) preserved & compatible", report.checks.last.detail
    end
  end

  test "verify lists every drifted migration and stops before replay" do
    in_app do |dir|
      add_migration_v2(dir)
      add_migration_v3(dir)
      InstantRecord::Compiler.lock_schema(root: dir)
      File.delete(File.join(dir, "db/migrate/#{V1}_create_notes.rb"))
      FileUtils.mkdir_p(File.join(dir, "db/browser_migrate"))
      File.write(File.join(dir, "db/browser_migrate/#{V2}_add_word_count_to_notes.sql"), "SELECT 1;")
      edit_lock(dir) { |lock| lock["versions"].last["digest"] = "wrong" }
      report = InstantRecord::Compiler.verify_schema(root: dir)

      assert_checks report,
        ["lockfile", :ok, "v1 (3 versions)"],
        ["schema version", :ok, V3.to_s],
        ["migration history", :error, "published migration #{V1} was deleted"],
        ["migration history", :error, "published migration #{V2} changed; add a new migration instead"],
        ["migration history", :error, "lockfile digest mismatch for migration #{V3}"]
      assert_empty report.replayed_versions
    end
  end

  test "a clean ladder reports every check in order" do
    in_app do |dir|
      add_migration_v2(dir)
      InstantRecord::Compiler.lock_schema(root: dir)
      report = InstantRecord::Compiler.verify_schema(root: dir)

      assert_checks report,
        ["lockfile", :ok, "v1 (2 versions)"],
        ["schema version", :ok, V2.to_s],
        ["migration history", :ok, "all 2 locked versions immutable and current"],
        ["fresh HEAD schema", :ok, "1 table(s), PRAGMA integrity_check ok"],
        ["replay #{V1}", :ok, "1 step(s) -> #{V2}, 1 pending outbox row(s) preserved & compatible"],
        ["replay #{V2}", :ok, "0 step(s) -> #{V2}, 1 pending outbox row(s) preserved & compatible"]
    end
  end

  test "a HEAD schema that cannot be built stops before any replay" do
    in_app do |dir|
      InstantRecord::Compiler.lock_schema(root: dir)
      edit_lock(dir) { |lock| lock["baseline_schema_sql"] = ["CREATE TABLE notes (id varchar)"] }
      report = InstantRecord::Compiler.verify_schema(root: dir)

      assert_equal ["fresh HEAD schema", :error], report.checks.last.to_a.first(2)
      assert_match(/\Amigration #{V1} failed inside transaction: table "notes" already exists/, report.checks.last.detail)
      assert_empty report.replayed_versions
    end
  end

  test "a failed replay does not stop the later ones" do
    in_app do |dir|
      add_sql_migration(dir, V2, 'ALTER TABLE "notes" ADD COLUMN "author" varchar NOT NULL;')
      InstantRecord::Compiler.lock_schema(root: dir)
      report = InstantRecord::Compiler.verify_schema(root: dir)

      assert_match(/\Amigration #{V2} failed inside transaction: Cannot add a NOT NULL column/, replay(report, V1).detail)
      assert_equal :ok, replay(report, V2).status
      assert_equal [V1, V2], report.replayed_versions
    end
  end

  test "replay reports lost and corrupted outbox rows" do
    {
      "DELETE FROM instant_record_outbox;" =>
        /\Aupgrade from #{V2} lost 1 pending OutboxMutation row\(s\): replay-#{V2}-notes-create\z/,
      "UPDATE instant_record_outbox SET changes_payload = '{';" =>
        /\Aupgrade from #{V2} corrupted OutboxMutation replay-#{V2}-notes-create JSON: /,
      "DROP TABLE instant_record_outbox;" =>
        /\Aupgrade from #{V2} lost 1 pending OutboxMutation row\(s\)/
    }.each do |sql, message|
      in_app do |dir|
        add_sql_migration(dir, V2, InstantRecord::Compiler::SchemaLock::OUTBOX_TABLE_DDL)
        add_sql_migration(dir, V3, sql)
        InstantRecord::Compiler.lock_schema(root: dir)
        report = InstantRecord::Compiler.verify_schema(root: dir)

        assert_equal :error, replay(report, V2).status
        assert_match message, replay(report, V2).detail
        assert_equal :ok, replay(report, V1).status
      end
    end
  end

  test "replay reports a schema that differs from HEAD" do
    in_app do |dir|
      InstantRecord::Compiler.lock_schema(root: dir)
      {
        [] => "upgrade from #{V1} is missing table \"notes\" present at HEAD",
        ["CREATE TABLE notes (id varchar, title varchar, body text, server_version integer, sync_state varchar, created_at datetime, b_extra text, a_extra text)"] =>
          "upgrade from #{V1} drifted on table \"notes\" (missing columns: updated_at; extra columns: a_extra, b_extra)"
      }.each do |schema_sql, message|
        edit_lock(dir) { |lock| lock["versions"].first["schema_sql"] = schema_sql }
        report = InstantRecord::Compiler.verify_schema(root: dir)
        assert_equal ["replay #{V1}", :error, message], report.checks.last.to_a
      end
    end
  end

  test "replay words a failed schema read as Active Record does" do
    in_app do |dir|
      InstantRecord::Compiler.lock_schema(root: dir)
      edit_lock(dir) do |lock|
        lock["versions"].first["schema_sql"] << <<~SQL
          PRAGMA writable_schema = ON;
          INSERT INTO sqlite_master VALUES ('table', 'broken', 'broken', 0, 'CREATE VIRTUAL TABLE broken USING missing_module(x)');
          PRAGMA writable_schema = RESET;
        SQL
      end
      report = InstantRecord::Compiler.verify_schema(root: dir)

      assert_match(/\ASQLite3::SQLException: no such module: missing_module/, replay(report, V1).detail)
    end
  end

  test "replay words a schema read that fails outside SQLite as Active Record does" do
    in_app do |dir|
      InstantRecord::Compiler.lock_schema(root: dir)
      edit_lock(dir) do |lock|
        lock["versions"].first["schema_sql"] << <<~SQL
          CREATE TABLE odd (id varchar);
          PRAGMA writable_schema = ON;
          UPDATE sqlite_master SET name = x'7aff' WHERE name = 'odd';
        SQL
      end
      report = InstantRecord::Compiler.verify_schema(root: dir)

      assert_match(/\AEncoding::UndefinedConversionError: /, replay(report, V1).detail)
    end
  end

  test "replay words a schema read that fails as its rows are read as Active Record does" do
    in_app do |dir|
      InstantRecord::Compiler.lock_schema(root: dir)
      edit_lock(dir) do |lock|
        lock["versions"].first["schema_sql"] << <<~SQL
          CREATE TABLE odd (id varchar);
          PRAGMA writable_schema = ON;
          UPDATE sqlite_master SET sql = 'garbage' WHERE name = 'odd';
          PRAGMA writable_schema = OFF;
          PRAGMA schema_version = 99;
        SQL
      end
      report = InstantRecord::Compiler.verify_schema(root: dir)

      assert_equal "SQLite3::CorruptException: malformed database schema (odd)", replay(report, V1).detail
    end
  end

  test "replay words a failed schema read with the query log tags" do
    tags = ->(sql, *) { "#{sql} /*application:App*/" }
    in_app do |dir|
      InstantRecord::Compiler.lock_schema(root: dir)
      edit_lock(dir) do |lock|
        lock["versions"].first["schema_sql"] << <<~SQL
          PRAGMA writable_schema = ON;
          INSERT INTO sqlite_master VALUES ('table', 'broken', 'broken', 0, 'CREATE VIRTUAL TABLE broken USING missing_module(x)');
          PRAGMA writable_schema = RESET;
        SQL
      end
      ActiveRecord.query_transformers << tags
      report = InstantRecord::Compiler.verify_schema(root: dir)

      assert_includes replay(report, V1).detail, "/*application:App*/"
    ensure
      ActiveRecord.query_transformers.delete(tags)
    end
  end

  test "replay reports a failed integrity check" do
    in_app do |dir|
      add_sql_migration(dir, V2, "CREATE TABLE counts (id varchar, n integer CHECK (n >= 0));")
      add_sql_migration(dir, V3, "PRAGMA ignore_check_constraints = ON; UPDATE counts SET n = -1; PRAGMA ignore_check_constraints = OFF;")
      InstantRecord::Compiler.lock_schema(root: dir)
      report = InstantRecord::Compiler.verify_schema(root: dir)

      assert_equal "SQLite PRAGMA integrity_check failed: CHECK constraint failed in counts", replay(report, V2).detail
      assert_equal :ok, replay(report, V1).status
    end
  end

  test "a baseline with schema SQL is replayed before the locked versions" do
    in_app do |dir|
      add_migration_v2(dir)
      lock = InstantRecord::Compiler.lock_schema(root: dir, baseline: V1)
      assert_equal 1, lock["baseline_schema_sql"].size
      report = InstantRecord::Compiler.verify_schema(root: dir, baseline: V1)

      assert report.ok?, report.to_s
      assert_equal [V1, V2], report.replayed_versions
      assert_equal "1 step(s) -> #{V2}, 1 pending outbox row(s) preserved & compatible", replay(report, V1).detail
    end
  end

  test "a baseline without schema SQL replays only the locked versions" do
    in_app do |dir|
      add_sql_migration(dir, V2, "CREATE TABLE tags (id varchar PRIMARY KEY);")
      File.delete(File.join(dir, "db/migrate/#{V1}_create_notes.rb"))
      lock = InstantRecord::Compiler.lock_schema(root: dir, baseline: V1)
      refute lock.key?("baseline_schema_sql")
      report = InstantRecord::Compiler.verify_schema(root: dir, baseline: V1)

      assert report.ok?, report.to_s
      assert_equal [V2], report.replayed_versions
    end
  end

  test "a lockfile without versions builds HEAD and replays nothing" do
    in_app do |dir|
      InstantRecord::Compiler.lock_schema(root: dir, baseline: V1)
      report = InstantRecord::Compiler.verify_schema(root: dir, baseline: V1)

      assert_checks report,
        ["lockfile", :ok, "v1 (0 versions)"],
        ["schema version", :ok, V1.to_s],
        ["migration history", :ok, "all 0 locked versions immutable and current"],
        ["fresh HEAD schema", :ok, "1 table(s), PRAGMA integrity_check ok"]
      assert_empty report.replayed_versions
    end
  end

  private

  def in_app
    Dir.mktmpdir do |dir|
      setup_app_v1(dir)
      yield dir
    end
  end

  def assert_checks(report, *expected)
    assert_equal expected, report.checks.map(&:to_a)
  end

  def replay(report, version)
    report.checks.find { |check| check.name == "replay #{version}" }
  end

  def edit_lock(dir)
    path = File.join(dir, "db/instant_record_lock.json")
    lock = JSON.parse(File.read(path))
    yield lock
    File.write(path, JSON.generate(lock))
  end

  def add_sql_migration(dir, version, sql)
    File.write(File.join(dir, "db/schema.rb"), "ActiveRecord::Schema[8.1].define(version: #{version}) do\nend\n")
    File.write(File.join(dir, "db/migrate/#{version}_step.rb"), "class Step < ActiveRecord::Migration[8.1]\nend\n")
    FileUtils.mkdir_p(File.join(dir, "db/browser_migrate"))
    File.write(File.join(dir, "db/browser_migrate/#{version}_step.sql"), sql)
  end

  def setup_app_v1(dir)
    FileUtils.mkdir_p(File.join(dir, "db/migrate"))
    File.write(File.join(dir, "db/schema.rb"), <<~RUBY)
      ActiveRecord::Schema[8.1].define(version: 2026_11_20_000001) do
      end
    RUBY
    File.write(File.join(dir, "db/migrate/20261120000001_create_notes.rb"), <<~RUBY)
      class CreateNotes < ActiveRecord::Migration[8.1]
        def change
          create_table :notes, id: :string do |t|
            t.string :title, null: false
            t.text :body, null: false, default: ""
            t.integer :server_version, null: false, default: 0
            t.string :sync_state, null: false, default: "synced"
            t.timestamps
          end
        end
      end
    RUBY
  end

  def add_migration_v2(dir)
    File.write(File.join(dir, "db/schema.rb"), <<~RUBY)
      ActiveRecord::Schema[8.1].define(version: 2026_11_20_000002) do
      end
    RUBY
    File.write(File.join(dir, "db/migrate/20261120000002_add_word_count_to_notes.rb"), <<~RUBY)
      class AddWordCountToNotes < ActiveRecord::Migration[8.1]
        def change
          add_column :notes, :word_count, :integer, null: false, default: 0
          execute "UPDATE notes SET word_count = length(body)"
        end
      end
    RUBY
  end

  def add_migration_v3(dir)
    File.write(File.join(dir, "db/schema.rb"), <<~RUBY)
      ActiveRecord::Schema[8.1].define(version: 2026_11_20_000003) do
      end
    RUBY
    File.write(File.join(dir, "db/migrate/20261120000003_add_notes_title_index.rb"), <<~RUBY)
      class AddNotesTitleIndex < ActiveRecord::Migration[8.1]
        def change
          add_index :notes, :title
        end
      end
    RUBY
  end
end
