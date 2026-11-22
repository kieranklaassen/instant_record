require "test_helper"
require "instant_record/compiler"
require "fileutils"
require "json"
require "tmpdir"

class SchemaLockTest < ActiveSupport::TestCase
  GEM_ROOT = File.expand_path("..", __dir__)

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

  test "demo db/instant_record_lock.json passes full upgrade-ladder verification" do
    demo_root = File.join(GEM_ROOT, "demo")
    migration_paths = [
      File.join(GEM_ROOT, "db/migrate"),
      File.join(demo_root, "db/migrate")
    ]
    report = InstantRecord::Compiler.verify_schema(
      root: demo_root,
      migration_paths: migration_paths
    )
    assert report.ok?, report.to_s
    assert_operator report.replayed_versions.size, :>=, 15
  end

  private

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
