require "test_helper"
require "instant_record/compiler"
require "fileutils"
require "json"
require "tmpdir"

class CompilerTest < ActiveSupport::TestCase
  GEM_ROOT = File.expand_path("..", __dir__)
  PIPELINE_DIR = File.join(GEM_ROOT, "compiled/pipeline")

  test "Toolchain parses KEY=VALUE lines with $VAR expansion and comments" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "toolchain.env")
      File.write(env_file, <<~ENV)
        # Comment line
        TOOLS=/opt/tools
        SPINEL_HOME=$TOOLS/spinel
        ROUNDHOUSE_BIN=$TOOLS/roundhouse/target/release/roundhouse
        EMPTY=
      ENV

      tc = InstantRecord::Compiler::Toolchain.load(env_file)
      assert_equal "/opt/tools", tc.fetch("TOOLS")
      assert_equal "/opt/tools/spinel", tc.fetch("SPINEL_HOME")
      assert_equal "/opt/tools/roundhouse/target/release/roundhouse", tc.fetch("ROUNDHOUSE_BIN")
      assert_equal "/opt/tools/spinel/bin/spinel", tc.join("SPINEL_HOME", "bin/spinel")
      assert_raises(InstantRecord::Compiler::BuildError) { tc.fetch("EMPTY") }
      assert_raises(InstantRecord::Compiler::BuildError) { tc.fetch("UNKNOWN") }
    end
  end

  test "Toolchain expands $VAR without prefix collisions and does not search PATH for missing slash paths" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "toolchain.env")
      File.write(env_file, <<~ENV)
        TOOLS=/opt/a
        TOOLS_CACHE=/opt/b
        BIN=$TOOLS_CACHE/bin
      ENV

      tc = InstantRecord::Compiler::Toolchain.load(env_file)
      assert_equal "/opt/b/bin", tc.fetch("BIN")
      assert_nil InstantRecord::Compiler::Toolchain.which("./definitely-not-a-real-binary")
    end
  end

  test "FileCopy.copy_tree dereferences directory symlinks without crashing or looping" do
    Dir.mktmpdir do |dir|
      src = File.join(dir, "src")
      shared = File.join(dir, "shared")
      dst = File.join(dir, "dst")
      FileUtils.mkdir_p(src)
      FileUtils.mkdir_p(shared)
      File.write(File.join(shared, "helper.rb"), "# shared\n")
      File.symlink(shared, File.join(src, "linked"))
      File.symlink(src, File.join(shared, "cycle"))

      InstantRecord::Compiler::FileCopy.copy_tree(src, dst)
      assert_equal "# shared\n", File.read(File.join(dst, "linked/helper.rb"))
    end
  end

  test "Toolchain.load raises ArgumentError when file is missing" do
    assert_raises(ArgumentError) do
      InstantRecord::Compiler::Toolchain.load("/nonexistent/instant_record_toolchain.env")
    end
  end

  test "Toolchain#doctor reports missing and present tools cleanly" do
    Dir.mktmpdir do |dir|
      fake = create_fake_toolchain(dir)
      tc = InstantRecord::Compiler::Toolchain.load(fake[:toolchain_file])

      report = tc.doctor(target: :wasm)
      assert report.ok?, report.to_s
      assert_match(/InstantRecord toolchain check \(wasm\)/, report.to_s)
      assert_match(/\[OK\s+\] spinel/, report.to_s)

      native_report = tc.doctor(target: :native)
      assert native_report.ok?, native_report.to_s

      File.delete(fake[:roundhouse])
      broken = tc.doctor(target: :wasm)
      refute broken.ok?
      assert_match(/\[MISSING\s+\] roundhouse/, broken.to_s)
    end
  end

  test "PathScrubber replaces prefix with neutral bytes of exact same length" do
    Dir.mktmpdir do |dir|
      wasm = File.join(dir, "app.wasm")
      prefix = "/Users/dev/secret-checkout/.build/wasm-tree"
      original = ("\x00asm\x01\x00\x00\x00" + prefix + "/app.rb\x00" + prefix + "/boot.rb").b
      File.binwrite(wasm, original)

      result = InstantRecord::Compiler.scrub_path(wasm, prefix)
      scrubbed = File.binread(wasm)

      assert_equal 2, result[:count]
      assert_equal 0, result[:remaining]
      assert_equal original.bytesize, result[:size]
      assert_equal original.bytesize, scrubbed.bytesize
      refute scrubbed.include?(prefix.b)
      assert scrubbed.include?("/build/_".b)
    end
  end

  test "BrowserMigrations.plan compiles migrations without disturbing ActiveRecord::Base.connection" do
    original_connection_id = ActiveRecord::Base.connection.object_id
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "db/migrate"))
      FileUtils.mkdir_p(File.join(dir, "db/browser_migrate"))
      File.write(File.join(dir, "db/schema.rb"), <<~RUBY)
        ActiveRecord::Schema[8.1].define(version: 2026_11_20_000002) do
        end
      RUBY
      File.write(File.join(dir, "db/migrate/20261120000001_create_tasks.rb"), <<~RUBY)
        class CreateTasks < ActiveRecord::Migration[8.1]
          def change
            create_table :tasks, id: :string do |t|
              t.string :title, null: false
            end
          end
        end
      RUBY
      File.write(File.join(dir, "db/migrate/20261120000002_custom_backfill.rb"), <<~RUBY)
        class CustomBackfill < ActiveRecord::Migration[8.1]
          def change
            Task.find_each(&:touch)
          end
        end
      RUBY
      File.write(File.join(dir, "db/browser_migrate/20261120000002_custom_backfill.sql"), "UPDATE tasks SET title = trim(title);")

      plan = InstantRecord::Compiler::BrowserMigrations.plan(root: dir)

      assert_equal 20261120000002, plan["version"]
      assert_nil plan["baseline"]
      assert_equal %w[20261120000001 20261120000002], plan["migrations"].keys
      assert_match(/CREATE TABLE "tasks"/, plan["migrations"]["20261120000001"].first)
      assert_equal ["UPDATE tasks SET title = trim(title);"], plan["migrations"]["20261120000002"]
      assert_equal 64, plan["history"]["20261120000001"].length
      assert_equal original_connection_id, ActiveRecord::Base.connection.object_id

      # Leading-zero baseline parses as base 10 (not octal) and stamps schema version cleanly.
      zero_padded = InstantRecord::Compiler::BrowserMigrations.plan(root: dir, baseline: "00000020261120000002")
      assert_equal 20261120000002, zero_padded["baseline"]
      assert_empty zero_padded["migrations"]
      steps = InstantRecord::Compiler::EntryBuilder.migrations(
        demo: false,
        plan: zero_padded,
        previous: 'InstantRecord::SyncMetadata.get("schema_version").to_s',
        applied: 'InstantRecord::SyncMetadata.set("schema_version", "<<version>>")'
      )
      assert_includes steps, 'InstantRecord::SyncMetadata.set("schema_version", "00000020261120000002")'
    end
  end

  test "BrowserMigrations.plan matches SQLite3Adapter DDL across fast-path and fallback operations" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "db/migrate"))
      File.write(File.join(dir, "db/schema.rb"), ("# header\n" * 600) + "ActiveRecord::Schema[8.1].define(version: 2026_11_20_000003) do\nend\n")
      mig1 = File.join(dir, "db/migrate/20261120000001_create_entities.rb")
      mig2 = File.join(dir, "db/migrate/20261120000002_alter_entities.rb")
      mig3 = File.join(dir, "db/migrate/20261120000003_fallback_options.rb")

      File.write(mig1, <<~RUBY)
        class CreateEntities < ActiveRecord::Migration[8.1]
          def change
            create_table :entities, id: :string, primary_key: :uid do |t|
              t.string :title, :slug, null: false, index: true
              t.text :note, default: "it's \\"ok\\""
              t.integer :count, null: false, default: 0
              t.decimal :price, precision: 10, scale: 2, null: false
              t.float :ratio, default: 1.5
              t.boolean :active, default: true, null: false
              t.boolean :archived, default: false, null: false
              t.datetime :seen_at, precision: 3
              t.column :code, :string, limit: 32, default: ""
              t.index [:title, :slug], unique: true
              t.timestamps
            end
            create_table :settings, id: false do |t|
              t.string :key, null: false, primary_key: true
              t.string :val
            end
          end
        end
      RUBY
      File.write(mig2, <<~RUBY)
        class AlterEntities < ActiveRecord::Migration[8.1]
          def change
            add_column :entities, :very_long_descriptive_column_name_for_index_truncation, :string, default: nil
            add_column :entities, :required_tag, :string, default: nil, null: false
            add_index :entities, [:very_long_descriptive_column_name_for_index_truncation, :title]
            add_index :entities, :slug, where: "active = 1"
            execute "UPDATE entities SET count = 1"
          end
        end
      RUBY
      File.write(mig3, <<~RUBY)
        class FallbackOptions < ActiveRecord::Migration[8.1]
          def change
            create_table :scratch_rows, temporary: true do |t|
              t.string :label
            end
            add_index :entities, [:title, :count], order: :desc
          end
        end
      RUBY

      plan = InstantRecord::Compiler::BrowserMigrations.plan(root: dir)
      reference = InstantRecord::Compiler::BrowserMigrations.new(ActiveRecord::Base.connection)

      assert_equal 20261120000003, plan["version"]
      assert_equal reference.compile(mig1), plan["migrations"]["20261120000001"]
      assert_equal reference.compile(mig2), plan["migrations"]["20261120000002"]
      assert_equal reference.compile(mig3), plan["migrations"]["20261120000003"]

      # Verify mig1 and mig2 compile strictly via the pure-Ruby fast path without touching SQLite3Adapter.
      fast_compiler = InstantRecord::Compiler::BrowserMigrations.new
      assert_equal reference.compile(mig1), fast_compiler.compile(mig1)
      assert_equal reference.compile(mig2), fast_compiler.compile(mig2)
      assert_nil fast_compiler.instance_variable_get(:@connection)
    end
  end

  test "BrowserMigrations.plan matches SQLite3Adapter on decimal defaults, non-native and time limits, integer bounds, and non-boolean options" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "db/migrate"))
      File.write(File.join(dir, "db/schema.rb"), "ActiveRecord::Schema[8.1].define(version: 2026_11_20_000003) do\nend\n")
      mig_fast = File.join(dir, "db/migrate/20261120000001_fast_edge_types.rb")
      mig_fallback = File.join(dir, "db/migrate/20261120000002_fallback_edge_types.rb")
      mig_alters = File.join(dir, "db/migrate/20261120000003_edge_alters.rb")

      File.write(mig_fast, <<~RUBY)
        class FastEdgeTypes < ActiveRecord::Migration[8.1]
          def change
            create_table :fast_edge_items, id: false do |t|
              t.column :big_id, :bigint, limit: 8
              t.column :ext_uid, :uuid, limit: 36
              t.column :raw_blob, :blob, limit: 16
              t.time :clock_at, limit: 4
              t.datetime :plain_dt, precision: nil, limit: 4
              t.column :plain_ts, :timestamp, precision: nil, limit: 4
              t.integer :tiny_ok, limit: 1, default: 127
              t.integer :tiny_min, limit: 1, default: -128
            end
          end
        end
      RUBY
      File.write(mig_fallback, <<~RUBY)
        class FallbackEdgeTypes < ActiveRecord::Migration[8.1]
          def change
            create_table :fallback_edge_items, id: false do |t|
              t.integer :pk_num, primary_key: 1
              t.decimal :d_no_scale, precision: 10, default: 0
              t.decimal :d_scale_zero, precision: 10, scale: 0, default: 1.5
              t.decimal :d_rounded, precision: 10, scale: 2, default: 1.555
              t.decimal :d_tiny, default: 0.00001
              t.decimal :d_huge, precision: 10, scale: 2, default: 1000000000000000
              t.column :virt_col, :virtual
              t.float :inf_float, default: #{10**400}
            end
            create_table :edge_str_pk, id: false do |t|
              t.string :code, primary_key: 1
            end
          end
        end
      RUBY
      File.write(mig_alters, <<~RUBY)
        class EdgeAlters < ActiveRecord::Migration[8.1]
          def change
            add_column :fast_edge_items, :extra_big, :bigint, limit: 8
            add_column :fast_edge_items, :extra_uid, :uuid, limit: 36
            add_column :fast_edge_items, :extra_time, :time, limit: 4
            add_column :fast_edge_items, :extra_dec, :decimal, precision: 10, scale: 2, default: 1.555
            add_column :fast_edge_items, :extra_virt, :virtual
            add_index :fast_edge_items, :ext_uid, name: false
          end
        end
      RUBY

      plan = InstantRecord::Compiler::BrowserMigrations.plan(root: dir)
      reference = InstantRecord::Compiler::BrowserMigrations.new(ActiveRecord::Base.connection)

      assert_equal reference.compile(mig_fast), plan["migrations"]["20261120000001"]
      assert_equal reference.compile(mig_fallback), plan["migrations"]["20261120000002"]
      assert_equal reference.compile(mig_alters), plan["migrations"]["20261120000003"]

      fast_compiler = InstantRecord::Compiler::BrowserMigrations.new
      assert_equal reference.compile(mig_fast), fast_compiler.compile(mig_fast)
      assert_nil fast_compiler.instance_variable_get(:@connection)

      # Out-of-range integer defaults must fail via SQLite3Adapter validation, matching reference behavior.
      [
        "create_table(:bad) { |t| t.integer :a, limit: 1, default: 200 }",
        "create_table(:bad) { |t| t.integer :a, limit: 2, default: 40000 }",
        "create_table(:bad) { |t| t.integer :a, limit: 4, default: 3000000000 }",
        "create_table(:bad) { |t| t.integer :a, default: 9223372036854775808 }",
        "create_table(:bad) { |t| t.integer :a, limit: 0, default: 1 }",
        "add_column :edge_items, :bad, :integer, limit: 1, default: 200"
      ].each_with_index do |body, i|
        Dir.mktmpdir do |err_dir|
          FileUtils.mkdir_p(File.join(err_dir, "db/migrate"))
          File.write(File.join(err_dir, "db/schema.rb"), "ActiveRecord::Schema[8.1].define(version: 1) do\nend\n")
          File.write(File.join(err_dir, "db/migrate/1_bad_#{i}.rb"), <<~RUBY)
            class Bad#{i} < ActiveRecord::Migration[8.1]
              def change
                #{body}
              end
            end
          RUBY
          err = assert_raises(InstantRecord::Compiler::BuildError, "expected RangeError for #{body}") do
            InstantRecord::Compiler::BrowserMigrations.plan(root: err_dir)
          end
          assert_match(/out of range/i, err.message)
        end
      end
    end
  end

  test "BrowserMigrations.plan reflects in-place same-size same-mtime edits and companion changes without stale caching" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "db/migrate"))
      File.write(File.join(dir, "db/schema.rb"), "ActiveRecord::Schema[8.1].define(version: 1) do\nend\n")
      mig = File.join(dir, "db/migrate/1_create_notes.rb")
      src_a = "class CreateNotes < ActiveRecord::Migration[8.1]\n  def change\n    create_table :notes do |t|\n      t.string :aaaa\n    end\n  end\nend\n"
      src_b = "class CreateNotes < ActiveRecord::Migration[8.1]\n  def change\n    create_table :notes do |t|\n      t.string :bbbb\n    end\n  end\nend\n"
      assert_equal src_a.bytesize, src_b.bytesize

      File.write(mig, src_a)
      stat = File.stat(mig)
      first = InstantRecord::Compiler::BrowserMigrations.plan(root: dir)
      assert_includes first["migrations"]["1"].first, '"aaaa"'

      File.write(mig, src_b)
      File.utime(stat.atime, stat.mtime, mig)
      second = InstantRecord::Compiler::BrowserMigrations.plan(root: dir)
      assert_includes second["migrations"]["1"].first, '"bbbb"'
      refute_equal first["history"]["1"], second["history"]["1"]

      FileUtils.mkdir_p(File.join(dir, "db/browser_migrate"))
      companion = File.join(dir, "db/browser_migrate/1_create_notes.sql")
      File.write(companion, "CREATE TABLE notes (id integer PRIMARY KEY);")
      third = InstantRecord::Compiler::BrowserMigrations.plan(root: dir)
      assert_equal ["CREATE TABLE notes (id integer PRIMARY KEY);"], third["migrations"]["1"]

      File.delete(companion)
      fourth = InstantRecord::Compiler::BrowserMigrations.plan(root: dir)
      assert_equal second["migrations"]["1"], fourth["migrations"]["1"]
    end
  end

  test "BrowserMigrations.plan is thread-safe and does not leak SQLite connections" do
    demo_root = File.join(GEM_ROOT, "demo")
    migration_paths = [File.join(GEM_ROOT, "db/migrate"), File.join(demo_root, "db/migrate")]
    expected = InstantRecord::Compiler::BrowserMigrations.plan(root: demo_root, migration_paths: migration_paths)

    GC.start
    open_before = ObjectSpace.each_object(SQLite3::Database).count { |db| !db.closed? }

    results = 6.times.map do
      Thread.new do
        4.times.map { InstantRecord::Compiler::BrowserMigrations.plan(root: demo_root, migration_paths: migration_paths) }
      end
    end.flat_map(&:value)

    results.each { |plan| assert_equal expected, plan }

    GC.start
    open_after = ObjectSpace.each_object(SQLite3::Database).count { |db| !db.closed? }
    assert_operator open_after, :<=, open_before
  end

  test "AppStage and GemVendor stage the real demo via local_first reachability with all seams intact" do
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app-src")
      manifest_path = File.join(dir, "instant_record.manifest.json")
      staged = InstantRecord::Compiler::AppStage.stage(
        source: File.join(GEM_ROOT, "demo"),
        target: app,
        native: false,
        overlay_dir: File.join(PIPELINE_DIR, "demo"),
        manifest_path: manifest_path
      )

      refute File.exist?(File.join(app, "config/initializers/ruby_llm.rb"))
      refute File.exist?(File.join(app, "app/screens"))
      refute File.exist?(File.join(app, "app/models/mailbox.rb"))
      refute File.exist?(File.join(app, "app/models/mail_shell.rb"))
      refute File.exist?(File.join(app, "app/models/assistant/reply.rb"))
      refute File.exist?(File.join(app, "app/controllers/source_controller.rb"))
      refute File.exist?(File.join(app, "app/controllers/auth/sessions_controller.rb"))
      refute File.exist?(File.join(app, "app/controllers/slack/resets_controller.rb"))
      refute File.exist?(File.join(app, "app/controllers/email/sync_controller.rb"))
      refute File.exist?(File.join(app, "app/views/inertia.html.erb"))
      refute File.exist?(File.join(app, "app/views/source"))
      refute File.exist?(File.join(app, "app/helpers/source_helper.rb"))

      # The overlay's console controller renders no partial, so the one the
      # server's controller renders is not staged for the compiler to choke on.
      assert File.file?(File.join(app, "app/views/console/sessions/index.html.erb"))
      refute File.exist?(File.join(app, "app/views/console/sessions/_result.html.erb"))

      # Of the four todo apps only /instant is local_first; the Rails-served
      # three and /compare stay out of the browser build.
      assert File.file?(File.join(app, "app/controllers/instant/todos_controller.rb"))
      %w[plain hotwire inertia].each do |way|
        refute File.exist?(File.join(app, "app/controllers", way))
        refute File.exist?(File.join(app, "app/models", way))
        refute File.exist?(File.join(app, "app/views", way))
      end
      refute File.exist?(File.join(app, "app/controllers/compare_controller.rb"))
      refute File.exist?(File.join(app, "app/views/compare"))

      assert File.file?(manifest_path)
      manifest = InstantRecord::Compiler::Manifest.read(manifest_path)
      assert_equal "island", manifest.mode
      assert_equal %w[AssistantChat AssistantTurn AuthNote Channel ChatUser Issue MailEntry Message Note], manifest.synced_model_names
      assert_equal({ "limit" => 50, "partition_by" => "channel_id" }, manifest.sync_windows["Message"])
      assert_equal({ "column" => "visitor_id", "policy" => false }, manifest.sync_scopes["AssistantChat"])
      assert_equal({ "column" => nil, "policy" => true }, manifest.sync_scopes["AuthNote"])
      assert_equal manifest.to_h, staged.manifest.to_h

      count = InstantRecord::Compiler::GemVendor.vendor(gem_src: GEM_ROOT, app_dir: app, demo: true)
      assert_equal 23, count
      assert File.file?(File.join(app, "lib/instant_record/client/rebaser.rb"))
      assert File.file?(File.join(app, "lib/instant_record/inertia.rb"))
      assert File.file?(File.join(app, "lib/instant_record/read_tracker.rb"))
      assert File.file?(File.join(app, "lib/instant_record/sync_partition.rb"))
      assert File.file?(File.join(app, "lib/instant_record/sync_notice.rb"))
      assert File.file?(File.join(app, "lib/instant_record/hlc.rb"))
      assert_includes File.read(File.join(app, "lib/instant_record/host.rb")), "def browser? = true"
      assert_includes File.read(File.join(app, "lib/instant_record/host.rb")), "def load_inertia_renderer = nil"
      assert_includes File.read(File.join(app, "lib/instant_record/host.rb")), "id.blank?"
      assert_includes File.read(File.join(app, "lib/instant_record/host.rb")), 'Db.exec("SAVEPOINT "'
      assert_includes File.read(File.join(app, "lib/instant_record.rb")), "def browser? = Host.browser?"
      refute_includes File.read(File.join(app, "lib/instant_record.rb")), "branch/sqlite_store"
      assert File.file?(File.join(app, "lib/instant_record/branch.rb"))
      refute File.exist?(File.join(app, "lib/instant_record/syncable.rb"))
      assert File.file?(File.join(app, "app/models/concerns/syncable.rb"))
      assert_includes File.read(File.join(app, "app/models/concerns/syncable.rb")), "InstantRecord::Host.blank_id?(id)"
      assert_includes File.read(File.join(app, "app/models/mail_entry.rb")), "include Syncable"
      assert_includes File.read(File.join(app, "app/models/mail_entry.rb")), "sync_partition :mailbox_id"
      refute_includes File.read(File.join(app, "app/models/mail_entry.rb")), "authorize_partition"
      refute_includes File.read(File.join(app, "app/models/slack/seeds.rb")), "apply_backfill"
      vendored_actions = File.read(File.join(app, "lib/instant_record/sync_actions.rb"))
      assert Prism.parse(vendored_actions).success?, "vendored sync_actions.rb must remain valid Ruby"
      assert_includes vendored_actions, "InstantRecord::Host.with_savepoint"
      refute_includes vendored_actions, "ActiveJobCommitGuard"
      refute_includes vendored_actions, "class ServerFrame"
      vendored_code = vendored_actions.lines.reject { |l| l.lstrip.start_with?("#") }.join
      refute_match(/\b(?:public_send|send|constantize)\b/, vendored_code)
      assert File.file?(File.join(app, "sig/instant_record/native.rbs"))
      assert File.file?(File.join(app, "sig/instant_record/inertia.rbs"))
      assert File.file?(File.join(app, "lib/instant_record/inertia.rb"))
      refute_includes File.read(File.join(app, "lib/instant_record/inertia.rb")), "instant_record/inertia/renderer"
      assert_includes File.read(File.join(app, "app/views/todo/issues/index.html.erb")), '<% content_for(:demo_scope, "todo") %>'
      assert_includes File.read(File.join(app, "app/helpers/slack_helper.rb")), '"/slack/reset?instant_record_network=1"'
      assert_includes File.read(File.join(app, "app/helpers/auth_helper.rb")), '"/instant_record/bootstrap?instant_record_network=1"'
      assert_includes File.read(File.join(app, "app/controllers/slack/channels_controller.rb")), ".order(:created_at, :id).to_a : []"
      refute_includes File.read(File.join(app, "app/controllers/slack/channels_controller.rb")), "InstantRecord.browser?"

      # The entire staged demo tree must pass the pre-Spinel static AOT/32-bit linter.
      lint = InstantRecord::Compiler::StaticLinter.lint(app, staged: true)
      assert lint.ok?, lint.to_s

      dist = File.join(dir, "dist")
      InstantRecord::Compiler::SourcePages.write(
        app_dir: app,
        dist_dir: dist,
        version: "abc123",
        demo_dir: File.join(GEM_ROOT, "demo"),
        pipeline_dir: PIPELINE_DIR
      )
      InstantRecord::Compiler::SourcePages::PAGES.each_key do |page|
        html = File.read(File.join(dist, "assets/source/abc123", "#{page}.html"))
        assert_includes html, "Source used by this compiled build"
      end
      assert_includes File.read(File.join(dist, "assets/source/abc123/migrate.html")), "compiled/pipeline/sqlite_release.rb"
    end
  end

  test "GemVendor unwraps browser_only and client_only blocks and strips server_only blocks across models, controllers, helpers, and screens" do
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(app, "app/controllers"))
      FileUtils.mkdir_p(File.join(app, "app/screens"))
      FileUtils.mkdir_p(File.join(app, "app/models"))
      FileUtils.mkdir_p(File.join(app, "app/helpers"))

      File.write(File.join(app, "app/models/item.rb"), <<~RUBY)
        class Item < ApplicationRecord
          include InstantRecord::Syncable
          server_only do
            validate :quota_check
          end
          browser_only do
            after_commit :flash_confetti
          end
          client_only do
            def local_label = title
          end
        end
      RUBY

      File.write(File.join(app, "app/helpers/items_helper.rb"), <<~RUBY)
        module ItemsHelper
          server_only do
            def secret_banner = "server"
          end
          browser_only do
            def local_banner = "browser"
          end
        end
      RUBY

      File.write(File.join(app, "app/controllers/items_controller.rb"), <<~RUBY)
        class ItemsController < ApplicationController
          server_only do
            before_action :require_server_secret
          end
          browser_only do
            skip_forgery_protection
          end
        end
      RUBY

      File.write(File.join(app, "app/screens/items_screen.rb"), <<~RUBY)
        class ItemsScreen < InstantRecord::Native::Screen
          client_only do
            def fast_path
              true
            end
          end
        end
      RUBY

      InstantRecord::Compiler::GemVendor.vendor(gem_src: GEM_ROOT, app_dir: app, demo: false)

      model = File.read(File.join(app, "app/models/item.rb"))
      refute_includes model, "quota_check"
      refute_includes model, "browser_only"
      refute_includes model, "client_only"
      assert_includes model, "  after_commit :flash_confetti\n"
      assert_includes model, "  def local_label = title\n"

      helper = File.read(File.join(app, "app/helpers/items_helper.rb"))
      refute_includes helper, "secret_banner"
      refute_includes helper, "browser_only"
      assert_includes helper, "  def local_banner = \"browser\"\n"

      controller = File.read(File.join(app, "app/controllers/items_controller.rb"))
      refute_includes controller, "require_server_secret"
      refute_includes controller, "browser_only"
      assert_includes controller, "  skip_forgery_protection\n"

      screen = File.read(File.join(app, "app/screens/items_screen.rb"))
      refute_includes screen, "client_only"
      assert_includes screen, "  def fast_path\n    true\n  end\n"

      vendored_core = File.read(File.join(app, "lib/instant_record.rb"))
      refute_includes vendored_core, "Rails.application.config.instant_record"
    end
  end

  test "EntryBuilder emits consumer sync_windows, endpoint, and mount_path and validates identifiers" do
    Dir.mktmpdir do |dir|
      emit = File.join(dir, "emit")
      app = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(emit, "app/models/instant_record/client"))
      FileUtils.mkdir_p(File.join(app, "app/screens"))

      File.write(File.join(emit, "main.rb"), "require_relative \"boot\"\nif ARGV.length > 0 && ARGV[0] == \"sidekiq\"\nend\n")
      File.write(File.join(emit, "app/models/instant_record/host.rb"), InstantRecord::Compiler::HostAdapters::Wasm.host_source)

      plan = { "version" => 1, "baseline" => nil, "migrations" => {} }
      windows = {
        "Event" => { limit: 100, partition_by: nil },
        "Message" => { limit: 25, partition_by: "room_id" }
      }

      InstantRecord::Compiler::EntryBuilder.write_wasm_entry(
        emit_dir: emit,
        demo: false,
        models: %w[Event Message],
        sync_windows: windows,
        endpoint: "https://api.example.test/sync",
        mount_path: "/sync",
        migration_plan: plan,
        pipeline_dir: PIPELINE_DIR
      )

      wasm_main = File.read(File.join(emit, "main_wasm.rb"))
      assert_includes wasm_main, 'InstantRecord.config.endpoint = "https://api.example.test/sync"'
      assert_includes wasm_main, 'InstantRecord.config.mount_path = "/sync"'
      assert_includes wasm_main, "Event.sync_window(limit: 100)"
      assert_includes wasm_main, "Message.sync_window(limit: 25, partition_by: :room_id)"

      InstantRecord::Compiler::EntryBuilder.write_native_entry(
        tree_dir: emit,
        app_dir: app,
        demo: false,
        models: %w[Event Message],
        sync_windows: windows,
        endpoint: "https://api.example.test/sync",
        mount_path: "/sync",
        migration_plan: plan
      )

      native_main = File.read(File.join(emit, "main_native.rb"))
      assert_includes native_main, "Event.sync_window(limit: 100)"
      assert_includes native_main, "Message.sync_window(limit: 25, partition_by: :room_id)"

      assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::EntryBuilder.sync_windows_code(
          demo: false,
          sync_windows: { "Message" => { limit: 10, partition_by: "bad col!" } }
        )
      end
      assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::EntryBuilder.sync_windows_code(
          demo: false,
          sync_windows: { "bad_model" => { limit: 10 } }
        )
      end
    end
  end

  test "WasmBuild input_digest tracks sync_windows and mount_path and fails cleanly when WEB_NODE_MODULES is missing" do
    Dir.mktmpdir do |dir|
      fake = create_fake_toolchain(dir)
      app_root = File.join(dir, "my_app")
      create_consumer_app(app_root)
      workspace = File.join(app_root, "tmp/instant_record/compiled")
      FileUtils.mkdir_p(File.join(workspace, "web"))

      base = InstantRecord::Compiler::WasmBuild.new(
        workspace: workspace, gem_root: GEM_ROOT, toolchain: fake[:toolchain_file],
        app_source: app_root, models: ["Task"], endpoint: "/instant_record"
      )
      with_window = InstantRecord::Compiler::WasmBuild.new(
        workspace: workspace, gem_root: GEM_ROOT, toolchain: fake[:toolchain_file],
        app_source: app_root, models: ["Task"], sync_windows: { "Task" => { limit: 20 } }, endpoint: "/instant_record"
      )
      with_mount = InstantRecord::Compiler::WasmBuild.new(
        workspace: workspace, gem_root: GEM_ROOT, toolchain: fake[:toolchain_file],
        app_source: app_root, models: ["Task"], endpoint: "/sync", mount_path: "/sync"
      )

      refute_equal base.input_digest, with_window.input_digest
      refute_equal base.input_digest, with_mount.input_digest

      File.write(fake[:toolchain_file], File.read(fake[:toolchain_file]).sub(/WEB_NODE_MODULES=.*/, "WEB_NODE_MODULES=#{dir}/missing_modules"))
      broken = InstantRecord::Compiler::WasmBuild.new(
        workspace: workspace, gem_root: GEM_ROOT, toolchain: fake[:toolchain_file],
        app_source: app_root, models: ["Task"], endpoint: "/instant_record"
      )
      error = assert_raises(InstantRecord::Compiler::BuildError) do
        broken.send(:ensure_web_node_modules, File.join(workspace, "web"))
      end
      assert_match(/npm ci/, error.message)

      # Existing broken symlink pointing at the configured path also raises BuildError.
      File.symlink("#{dir}/missing_modules", File.join(workspace, "web/node_modules"))
      broken_link_error = assert_raises(InstantRecord::Compiler::BuildError) do
        broken.send(:ensure_web_node_modules, File.join(workspace, "web"))
      end
      assert_match(/npm ci/, broken_link_error.message)

      # NativeBuild strips trailing slashes from endpoint and mount_path while preserving nil.
      native_norm = InstantRecord::Compiler::NativeBuild.new(
        workspace: workspace, gem_root: GEM_ROOT, toolchain: fake[:toolchain_file],
        app_source: app_root, models: ["Task"], endpoint: "https://api.example/sync/", mount_path: "/sync/"
      )
      assert_equal "https://api.example/sync", native_norm.instance_variable_get(:@endpoint)
      assert_equal "/sync", native_norm.instance_variable_get(:@mount_path)
    end
  end

  test "EntryBuilder escapes migration SQL interpolation and builds wasm and native entries" do
    Dir.mktmpdir do |dir|
      emit = File.join(dir, "emit")
      app = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(emit, "app/models/instant_record/client"))
      FileUtils.mkdir_p(File.join(app, "app/screens"))

      File.write(File.join(emit, "main.rb"), <<~RUBY)
        require_relative "boot"
        if ARGV.length > 0 && ARGV[0] == "sidekiq"
          puts "sidekiq"
        end
      RUBY
      File.write(File.join(app, "app/screens/inbox_list_screen.rb"), "class InboxListScreen < InstantRecord::Native::Screen; end\n")
      File.write(File.join(emit, "app/models/instant_record/host.rb"), InstantRecord::Compiler::HostAdapters::Wasm.host_source)

      plan = {
        "version" => 20261120000001,
        "baseline" => nil,
        "migrations" => {
          "20261120000001" => ['UPDATE notes SET tag = "#{x}#@y#$z"']
        }
      }

      InstantRecord::Compiler::EntryBuilder.write_wasm_entry(
        emit_dir: emit,
        demo: false,
        models: ["Note"],
        migration_plan: plan,
        pipeline_dir: PIPELINE_DIR,
        shell_fingerprint: "abc123fingerprint"
      )

      wasm_main = File.read(File.join(emit, "main_wasm.rb"))
      assert_includes wasm_main, "module WasmBridge"
      assert_includes wasm_main, "InstantRecord::Client.handle_history("
      assert_includes wasm_main, 'File.read("/host/in")'
      assert_includes wasm_main, "InstantRecord::ReadTracker.track"
      assert_includes wasm_main, "InstantRecord::Client.capture_local_changes"
      assert_includes wasm_main, "X-Instant-Record-Reads: "
      assert_includes wasm_main, 'if previous < "00000020261120000001"'
      assert_includes wasm_main, 'Db.exec("BEGIN IMMEDIATE")'
      assert_includes wasm_main, 'Db.exec("COMMIT")'
      assert_includes wasm_main, 'Db.exec("ROLLBACK")'
      assert_includes wasm_main, "def self.export_outbox"
      assert_includes wasm_main, "def self.import_outbox"
      assert_includes wasm_main, 'File.exist?("/host/recovery") && File.read("/host/recovery") == "extract_outbox"'
      assert_includes wasm_main, '\#{x}\#@y\#$z'
      assert_includes wasm_main, "InstantRecord.sync(Note)"
      assert_includes wasm_main, "InstantRecord::Client.streaming = true"
      assert_includes wasm_main, 'fingerprint: "abc123fingerprint"'
      assert_includes wasm_main, "def self.notices"
      assert_includes wasm_main, "notices="
      assert_includes wasm_main, "def self.branch_outbox"
      assert_includes wasm_main, "def self.branch_replay"

      screens = InstantRecord::Compiler::EntryBuilder.write_native_entry(
        tree_dir: emit,
        app_dir: app,
        demo: false,
        models: ["Note"],
        migration_plan: plan,
        shell_fingerprint: "abc123fingerprint"
      )

      assert_equal ["inbox_list"], screens
      native_main = File.read(File.join(emit, "main_native.rb"))
      assert_includes native_main, "module NativeBridge"
      assert_includes native_main, "InstantRecord::Client.handle_history("
      assert_includes native_main, "def self.branch_outbox"
      assert_includes native_main, "def self.branch_replay"
      assert_includes native_main, 'when "inbox_list" then InboxListScreen.new(params)'
      assert_includes native_main, 'Db.exec("BEGIN IMMEDIATE")'
      assert_includes native_main, 'NativeHost.ir_host_give("reads", InstantRecord::ReadTracker.serialize(reads))'
      assert_includes native_main, 'InstantRecord::SyncMetadata.set("schema_version", "00000020261120000001")'
      assert_includes native_main, "InstantRecord::Client.streaming = false"
      assert_includes native_main, 'fingerprint: "abc123fingerprint"'

      host = File.read(File.join(emit, "app/models/instant_record/host.rb"))
      assert_includes host, "NativeHost.ir_host_take(name)"
      assert_includes host, "NativeHost.ir_host_give(name, body)"
    end
  end

  test "EntryBuilder wraps each migration version in an atomic SQLite transaction that rolls back on mid-step failure" do
    plan = {
      "version" => 2,
      "baseline" => nil,
      "migrations" => {
        "1" => [
          'CREATE TABLE "widgets" ("id" varchar NOT NULL PRIMARY KEY, "name" varchar NOT NULL)',
          'INSERT INTO "widgets" ("id", "name") VALUES (\'w-1\', \'alpha\')'
        ],
        "2" => [
          'ALTER TABLE "widgets" ADD COLUMN "priority" integer NOT NULL DEFAULT 0',
          'INSERT INTO "widgets" ("id", "name", "priority") VALUES (\'w-1\', \'duplicate-pk\', 9)'
        ]
      }
    }

    code = InstantRecord::Compiler::EntryBuilder.migrations(
      demo: false,
      plan: plan,
      previous: '"00000000000000000000"',
      applied: 'applied_versions << "<<version>>"'
    )

    conn = ActiveRecord::ConnectionAdapters::SQLite3Adapter.new({ adapter: "sqlite3", database: ":memory:" })
    raw = conn.raw_connection
    db_mod = Module.new do
      define_singleton_method(:exec) { |sql| raw.execute_batch(sql) }
    end

    runner = Module.new
    runner.const_set(:Db, db_mod)
    applied_versions = []
    restored = true

    # Step 1 commits atomically; step 2 fails on its 2nd statement and rolls back its ALTER TABLE.
    error = assert_raises(SQLite3::ConstraintException) do
      runner.module_eval(<<~RUBY)
        restored = #{restored}
        applied_versions = ObjectSpace._id2ref(#{applied_versions.object_id})
        #{code}
      RUBY
    end
    assert_match(/UNIQUE constraint failed/, error.message)

    # Step 1 was committed and stamped; step 2's ALTER TABLE was rolled back cleanly.
    assert_equal ["00000000000000000001"], applied_versions
    columns = conn.select_all('PRAGMA table_info("widgets")').map { |r| r["name"] }
    assert_equal %w[id name], columns
    assert_equal 1, conn.select_value('SELECT COUNT(*) FROM "widgets"')
  ensure
    conn&.disconnect!
  end

  test "EntryBuilder discovers sync_actions and emits static Spinel case dispatch with zero send or constantize" do
    Dir.mktmpdir do |dir|
      emit = File.join(dir, "emit")
      app = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(emit, "app/models/instant_record/client"))
      FileUtils.mkdir_p(File.join(app, "app/models/billing"))
      FileUtils.mkdir_p(File.join(app, "app/screens"))

      File.write(File.join(emit, "main.rb"), <<~RUBY)
        require_relative "boot"
        if ARGV.length > 0 && ARGV[0] == "sidekiq"
          puts "sidekiq"
        end
      RUBY
      File.write(File.join(emit, "app/models/instant_record/host.rb"), InstantRecord::Compiler::HostAdapters::Wasm.host_source)

      File.write(File.join(app, "app/models/issue.rb"), <<~RUBY)
        class Issue < ApplicationRecord
          include InstantRecord::Syncable

          sync_action :close
          sync_action :reopen
          sync_action :purge_all

          def self.close(args)
            find(args["id"]).update!(state: "closed")
          end

          class << self
            def reopen(id:, state: "open")
              find(id).update!(state: state)
            end

            def purge_all
              delete_all
            end
          end
        end
      RUBY

      File.write(File.join(app, "app/models/billing/invoice.rb"), <<~RUBY)
        module Billing
          class Invoice < ApplicationRecord
            include InstantRecord::Syncable
            sync_action :pay
            def self.pay(id:, amount:)
              find(id).update!(paid: amount)
            end
          end
        end
      RUBY

      plan = { "version" => 1, "baseline" => nil, "migrations" => {} }
      InstantRecord::Compiler::EntryBuilder.write_wasm_entry(
        emit_dir: emit,
        demo: false,
        models: ["Issue"],
        migration_plan: plan,
        pipeline_dir: PIPELINE_DIR,
        app_dir: app
      )
      InstantRecord::Compiler::EntryBuilder.write_native_entry(
        tree_dir: emit,
        app_dir: app,
        demo: false,
        models: ["Issue"],
        migration_plan: plan
      )

      %w[main_wasm.rb main_native.rb].each do |entry_name|
        generated = File.read(File.join(emit, entry_name))
        assert Prism.parse(generated).success?, "#{entry_name} must remain valid Ruby"
        assert_includes generated, 'when "Issue.close" then Issue.close(args)'
        assert_includes generated, 'when "Issue.reopen" then Issue.reopen(id: args["id"], state: args.key?("state") ? args["state"] : "open")'
        assert_includes generated, 'when "Issue.purge_all" then Issue.purge_all'
        assert_includes generated, 'when "Billing::Invoice.pay" then Billing::Invoice.pay(id: args["id"], amount: args["amount"])'
        generated_code = generated.lines.reject { |l| l.lstrip.start_with?("#") }.join
        refute_match(/\b(?:public_send|send|constantize)\b/, generated_code)
      end

      # Block-form sync_action cannot be statically dispatched in Spinel and fails fast at build time.
      File.write(File.join(app, "app/models/bad.rb"), <<~RUBY)
        class Bad < ApplicationRecord
          include InstantRecord::Syncable
          sync_action :oops do |args|
            args
          end
        end
      RUBY
      err = assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::EntryBuilder.discover_sync_actions(app)
      end
      assert_match(/cannot use a block in compiled builds/, err.message)
    end
  end

  test "WasmTree renames threading constants, injects shims, and patches emitted runtime" do
    Dir.mktmpdir do |dir|
      emit = File.join(dir, "emit")
      tree = File.join(dir, "tree")
      FileUtils.mkdir_p(File.join(emit, "runtime/active_record"))
      FileUtils.mkdir_p(File.join(emit, "app/models"))
      FileUtils.mkdir_p(File.join(emit, "app/views/slack/channels"))

      File.write(File.join(emit, "boot.rb"), "# header\nrequire_relative \"runtime/db\"\n")
      File.write(File.join(emit, "main_wasm.rb"), "m = Mutex.new\n")
      File.write(File.join(emit, "runtime/pool.rb"), "require \"timeout\"\nThread.current\nFiber.yield\n")
      File.write(File.join(emit, "runtime/message_digest.rb"), "require \"openssl\"\nmodule MD\n  def self.aes_256_gcm_encrypt; end\nend\n")
      File.write(File.join(emit, "runtime/db.rb"), "sqlite3_bind_int64\nsqlite3_last_insert_rowid\n")
      File.write(File.join(emit, "runtime/sqlite_adapter.rb"), "module SqliteAdapter\n  def self.each_row(sql)\n  end\nend\n")
      File.write(File.join(emit, "runtime/active_record/base.rb"), "module ActiveRecord\n  class Base\n    def has_changes_to_save?\n    end\n  end\nend\n")
      File.write(File.join(emit, "runtime/active_record/connection.rb"), "module ActiveRecord\n  class Connection\n    def quote_string(str)\n    end\n  end\nend\n")
      File.write(File.join(emit, "runtime/action_text.rb"), "line1\nline2\n")
      File.write(File.join(emit, "app/models/note.rb"), <<~RUBY)
        if name == "created_at"
          if respond_to?(:created_at=)
            self.created_at = value
          end
        end
        def fill_timestamps(creating)
          now = ActiveSupport.db_now
          if !(creating) || @updated_at_raw.nil? || @updated_at_raw.empty?
            @updated_at_raw = now
          end
        end
      RUBY
      File.write(File.join(emit, "app/views/slack/channels/_sidebar.rb"), <<~RUBY)
        channels.each do |channel|
          active = channel == channel
        end
        dms.each do |dm|
        end
      RUBY

      stats = InstantRecord::Compiler::WasmTree.build(source: emit, target: tree, demo: true)

      assert_operator stats[:touched], :>=, 2
      assert_equal 2, stats[:pruned_lines]
      assert_includes File.read(File.join(tree, "boot.rb")), 'require_relative "runtime/wasm_threads"'
      assert_includes File.read(File.join(tree, "main_wasm.rb")), "WasmMutex.new"
      pool = File.read(File.join(tree, "runtime/pool.rb"))
      assert_includes pool, '# require "timeout"'
      assert_includes pool, "WasmThread.current"
      assert_includes pool, "WasmFiber.yield"
      assert_includes File.read(File.join(tree, "runtime/db.rb")), "rh_sqlite3_bind_int64"
      assert_includes File.read(File.join(tree, "runtime/sqlite_adapter.rb")), "InstantRecord::ReadTracker.record_sql(sql)"
      assert_includes File.read(File.join(tree, "runtime/message_digest.rb")), "NotImplementedError"
      assert_includes File.read(File.join(tree, "runtime/active_record/base.rb")), "def changed"
      assert_includes File.read(File.join(tree, "app/models/note.rb")), "ActiveSupport.cast_datetime(value)"
      assert_includes File.read(File.join(tree, "app/models/note.rb")), "!(creating) && !InstantRecord::Client.applying_remote?"
      assert_includes File.read(File.join(tree, "app/views/slack/channels/_sidebar.rb")), "channel_row == channel"
      assert_includes File.read(File.join(tree, "runtime/action_text.rb")), "# Pruned for browser wasm"
    end
  end

  test "WasmTree rewrites only what its patches name, in every folder they cover" do
    form_attrs = '#{ActionView::ViewHelpers.tag_attr("form", { data: { turbo: false, action: "submit->issues#submit" } })}'
    button = 'class=\"#{"button_to"}\">'
    stats, tree = build_wasm_tree(
      "config/nested/queue.rb" => "Queue.new\nrequire \"timeout\"\n",
      "runtime/timeout_only.rb" => "require \"timeout\"\n",
      "runtime/sqlite_adapter.rb" => "  def self.select_rows(sql, binds)\n    def query(sql)\n  def other(sql)\n",
      "app/models/admin/note.rb" => <<~RUBY,
        if name == "read_at"
          if respond_to?(:read_at=)
            self.read_at = value
        if !(creating) || @updated_at_raw.nil? || @updated_at_raw.empty?
      RUBY
      "app/models/plain.rb" => "Thread.new\n",
      "app/views/admin/list.rb" => "each_with_index\nActionView::ViewHelpers.raw(_cap)\n",
      "app/views/button.rb" => form_attrs + button,
      "app/views/plain.rb" => "ActionView::ViewHelpers.raw(_cap)\n#{button}",
      "runtime/cable.rb" => "kept\n",
      "test/skipped.rb" => ""
    )

    assert_equal({ touched: 2, pruned_lines: 0 }, stats)
    expected = {
      "main_wasm.rb" => "WasmMutex.new\n",
      "config/nested/queue.rb" => "WasmQueue.new\n# require \"timeout\"  (wasm: see runtime/wasm_threads.rb)\n",
      "runtime/timeout_only.rb" => "# require \"timeout\"  (wasm: see runtime/wasm_threads.rb)\n",
      "runtime/sqlite_adapter.rb" => <<~RUBY.gsub(/^/, "  "),
        def self.select_rows(sql, binds)
          InstantRecord::ReadTracker.record_sql(sql)
          def query(sql)
            InstantRecord::ReadTracker.record_sql(sql)
        def other(sql)
      RUBY
      "app/models/admin/note.rb" => <<~RUBY,
        if name == "read_at"
          if respond_to?(:read_at=)
            self.read_at = ActiveSupport.cast_datetime(value)
        if (!(creating) && !InstantRecord::Client.applying_remote?) || @updated_at_raw.nil? || @updated_at_raw.empty?
      RUBY
      "app/models/plain.rb" => "Thread.new\n",
      "app/views/admin/list.rb" => "each_with_index\nio << _cap\n",
      "app/views/button.rb" => 'class=\"#{"button_to"}\" data-turbo=\"false\" data-action=\"submit-&gt;issues#submit\">',
      "app/views/plain.rb" => "ActionView::ViewHelpers.raw(_cap)\n#{button}",
      "runtime/cable.rb" => "kept\n"
    }
    assert_equal expected, tree.slice(*expected.keys)
    refute_includes tree, "test/skipped.rb"
  end

  test "WasmTree leaves a tracked adapter alone and needs main_wasm.rb but no app or config" do
    tracked = "def self.query(sql)\n  InstantRecord::ReadTracker.record_sql(sql)\nend\n"
    _stats, tree = build_wasm_tree("runtime/sqlite_adapter.rb" => tracked)

    assert_equal tracked, tree["runtime/sqlite_adapter.rb"]
    refute_includes build_wasm_tree({}).last, "runtime/sqlite_adapter.rb"
    assert_raises(Errno::ENOENT) { build_wasm_tree("main_wasm.rb" => nil) }
  end

  # SyncWindow builds its SQL with these, and an emitted Connection has neither.
  test "WasmTree gives the emitted Connection the identifier quoting Rails has for SQLite" do
    emitted = "class Connection\n    def quote_string(str)\n      str\n    end\nend\n"
    _stats, tree = build_wasm_tree("runtime/active_record/connection.rb" => emitted)

    sandbox = Module.new
    sandbox.module_eval(tree["runtime/active_record/connection.rb"])
    compiled = sandbox.const_get(:Connection).new
    rails = ActiveRecord::Base.connection
    ["messages", "main.messages", 'odd"name', :created_at].each do |name|
      assert_equal rails.quote_table_name(name), compiled.quote_table_name(name)
      assert_equal rails.quote_column_name(name), compiled.quote_column_name(name)
    end
    assert_equal "kept", compiled.quote_string("kept")
  end

  test "WasmTree refuses an emitted Connection it cannot give the quoting to, and leaves one that has it" do
    path = "runtime/active_record/connection.rb"
    [nil, "def other\nend\n", "def quote_table_name(name)\nend\n    def quote_string(str)\n"].each do |emitted|
      assert_raises(InstantRecord::Compiler::BuildError) { build_wasm_tree(path => emitted) }
    end
    quoting = "def quote_column_name(name)\nend\ndef quote_table_name(name)\nend\n"
    assert_equal quoting, build_wasm_tree(path => quoting).last[path]
  end

  # A retried notice, like any JSON, holds its attributes under String keys.
  test "WasmTree makes the emitted update! take String keys, as its update does" do
    emitted = <<~RUBY
      class Emitted
        attr_reader :title, :saved

        def update(attrs)
          attrs = attrs.to_h { |k, v| [k.to_s.to_sym, v] } if attrs.is_a?(Hash) && attrs.any? { |k, _| k.is_a?(String) }
          @title = attrs[:title] if attrs.key?(:title)
        end

        def update!(attrs)
          @title = attrs[:title] if attrs.key?(:title)
          @saved = true
          self
        end
      end
    RUBY
    path = "app/models/emitted.rb"
    _stats, tree = build_wasm_tree(path => emitted)

    sandbox = Module.new
    sandbox.module_eval(tree[path])
    record = sandbox.const_get(:Emitted).new
    assert_equal "by string", record.update!({ "title" => "by string" }).title
    assert_equal "by symbol", record.update!({ title: "by symbol" }).title
    assert_equal "by symbol", record.update!({}).title
    assert record.saved
    assert_equal tree[path], build_wasm_tree(path => tree[path]).last[path], "a tree that converts the keys is left alone"
  end

  test "Compiler.build and Compiler.build_native run end-to-end with a stub toolchain and cache unchanged builds" do
    Dir.mktmpdir do |dir|
      fake = create_fake_toolchain(dir)
      app_root = File.join(dir, "my_app")
      create_consumer_app(app_root)

      output = with_path(fake[:bin_dir]) do
        InstantRecord::Compiler.build(
          root: app_root,
          models: ["Task"],
          toolchain: fake[:toolchain_file],
          endpoint: "/instant_record"
        )
      end

      assert_equal Pathname(app_root).realpath.join("tmp/instant_record/compiled/web/dist"), output
      assert File.file?(File.join(app_root, "db/instant_record_lock.json")), "first compile should emit db/instant_record_lock.json"
      assert File.file?(output.join("index.html"))
      assert File.file?(output.join("instant-record-release.json"))
      assert File.file?(output.join("instant_record.manifest.json"))
      assert File.file?(output.join("service-worker.js"))
      assert File.file?(output.join("assets/turbo.min.js"))
      assert_equal 1, Dir.glob(output.join("app-*.wasm").to_s).size

      # The staged schema loses a foreign key to a table that does not sync. A server's shells are
      # named by its own schema, so the fingerprint is that one's.
      staged_schema = Dir.glob(File.join(app_root, "tmp/instant_record/compiled/**/app-src/db/schema.rb"), File::FNM_DOTMATCH).first
      refute_includes File.read(staged_schema), "add_foreign_key"
      entry = Dir.glob(File.join(app_root, "tmp/instant_record/compiled/**/emit/main_wasm.rb"), File::FNM_DOTMATCH).first
      fingerprint = InstantRecord::Shell.fingerprint(models: ["Task"], schema_path: File.join(app_root, "db/schema.rb"))
      assert_includes File.read(entry), "fingerprint: \"#{fingerprint}\""
      refute File.exist?(Pathname(app_root).join("tmp/instant_record/compiled/pipeline")), "pipeline scripts should not be copied into tmp/"

      index_html = output.join("index.html").read
      assert_includes index_html, 'window.__worker = new Worker("/harness/worker-abc.js", { type: "module" })'
      refute_includes index_html, "modulepreload"
      assert_includes index_html, '<link rel="preload" as="style" href="https://fonts.example.test/font.css">'
      assert_includes index_html, "instant_record.warmed"

      # Second build with unchanged inputs hits stamp cache without re-running Roundhouse.
      calls_before = File.read(fake[:call_log]).lines.count
      with_path(fake[:bin_dir]) do
        InstantRecord::Compiler.build(
          root: app_root,
          models: ["Task"],
          toolchain: fake[:toolchain_file],
          endpoint: "/instant_record"
        )
      end
      assert_equal calls_before, File.read(fake[:call_log]).lines.count

      # Updating WEB_NODE_MODULES replaces a stale symlink cleanly.
      new_modules = File.join(dir, "tools/web_node_modules_v2")
      FileUtils.mkdir_p(new_modules)
      File.write(fake[:toolchain_file], File.read(fake[:toolchain_file]).sub("web_node_modules", "web_node_modules_v2"))
      with_path(fake[:bin_dir]) do
        InstantRecord::Compiler.build(
          root: app_root,
          models: ["Task"],
          toolchain: fake[:toolchain_file],
          endpoint: "/instant_record"
        )
      end
      assert_equal new_modules, File.readlink(Pathname(app_root).realpath.join("tmp/instant_record/compiled/web/node_modules"))

      # Native host build runs end-to-end and outputs libinstant_record_app.a + host + typed contracts.
      custom_swift = File.join(dir, "exported/Contracts.swift")
      native_out = with_path(fake[:bin_dir]) do
        InstantRecord::Compiler.build_native(
          root: app_root,
          models: ["Task"],
          toolchain: fake[:toolchain_file],
          endpoint: "/instant_record",
          swift_out: custom_swift,
          kotlin: true,
          kotlin_package: "com.acme.tasks"
        )
      end
      assert File.file?(native_out.join("libinstant_record_app.a"))
      assert File.file?(native_out.join("host"))
      assert File.file?(native_out.join(InstantRecord::Compiler::NativeBuild.shared_library_name))
      assert File.file?(native_out.join("generated/InstantRecordContracts.swift"))
      assert File.file?(native_out.join("generated/InstantRecordContracts.kt"))
      assert File.file?(custom_swift)
      assert_includes native_out.join("generated/InstantRecordContracts.swift").read, "public struct TasksViewProps"
      assert_includes native_out.join("generated/InstantRecordContracts.kt").read, "package com.acme.tasks"
      assert_includes native_out.join("generated/InstantRecordContracts.kt").read, "data class TasksViewProps"
      refute_includes native_out.join("app-src/app/screens/tasks_screen.rb").read, "contract"

      # Both WasmBuild and NativeBuild compile sqlite3.c with FTS5 enabled.
      calls = File.read(fake[:call_log]).lines
      wasm_sqlite_call = calls.find { |line| line.start_with?("clang ") && line.include?("sqlite3.c") }
      native_sqlite_call = calls.find { |line| line.start_with?("cc ") && line.include?("sqlite3.c") }
      assert_includes wasm_sqlite_call, "-DSQLITE_ENABLE_FTS5"
      assert_includes native_sqlite_call, "-DSQLITE_ENABLE_FTS5"

      # Native iOS simulator build cross-compiles Spinel runtime into libspinel_rt.a.
      ios_out = with_path(fake[:bin_dir]) do
        InstantRecord::Compiler.build_native(
          root: app_root,
          models: ["Task"],
          toolchain: fake[:toolchain_file],
          endpoint: "/instant_record",
          target: "iphonesimulator"
        )
      end
      assert File.file?(ios_out.join("libinstant_record_app.a"))
      assert File.file?(ios_out.join("libspinel_rt.a"))
      refute File.exist?(ios_out.join("host"))
      refute File.exist?(ios_out.join(InstantRecord::Compiler::NativeBuild.shared_library_name))
    end
  end

  test "WasmBuild#inject_preloads keeps core CSS as low-priority preloads and defers extra stylesheets" do
    Dir.mktmpdir do |dir|
      fake = create_fake_toolchain(dir)
      dist = File.join(dir, "dist")
      FileUtils.mkdir_p(File.join(dist, "harness"))
      FileUtils.mkdir_p(File.join(dist, "assets"))
      File.write(File.join(dist, "index.html"), "<!doctype html><html><head>\n  </head><body></body></html>")
      File.write(File.join(dist, "harness/worker-123.js"), "// worker\n")
      %w[base.css ui-deadbeef01.css mail.css slack.css extra.css].each do |name|
        File.write(File.join(dist, "assets", name), "body { color: #000; }\n")
      end

      build = InstantRecord::Compiler::WasmBuild.new(
        workspace: dir,
        gem_root: File.expand_path("..", __dir__),
        toolchain: fake[:toolchain_file]
      )
      build.inject_preloads(dist, nil)

      html = File.read(File.join(dist, "index.html"))
      assert_includes html, 'window.__worker = new Worker("/harness/worker-123.js", { type: "module" })'
      assert_includes html, '<link rel="preload" as="style" fetchpriority="low" href="/assets/base.css">'
      assert_includes html, '<link rel="preload" as="style" fetchpriority="low" href="/assets/ui-deadbeef01.css">'
      assert_includes html, '<link rel="preload" as="style" fetchpriority="low" href="/assets/mail.css">'
      refute_includes html, '<link rel="preload" as="style" fetchpriority="low" href="/assets/slack.css">'
      refute_includes html, '<link rel="preload" as="style" fetchpriority="low" href="/assets/extra.css">'
      assert_includes html, '"/assets/slack.css"'
      assert_includes html, '"/assets/extra.css"'
    end
  end

  private

  # Builds the smallest emit WasmTree accepts plus the given files (nil drops one), and returns the
  # stats with every Ruby file of the tree by path.
  def build_wasm_tree(files)
    Dir.mktmpdir do |dir|
      emit = File.join(dir, "emit")
      tree = File.join(dir, "tree")
      {
        "boot.rb" => "require_relative \"runtime/db\"\n",
        "main_wasm.rb" => "Mutex.new\n",
        "runtime/message_digest.rb" => "  def self.aes_256_gcm_encrypt\n",
        "runtime/db.rb" => "",
        "runtime/active_record/base.rb" => "    def has_changes_to_save?\n",
        "runtime/active_record/connection.rb" => "    def quote_string(str)\n"
      }.merge(files).compact.each do |rel, text|
        path = File.join(emit, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, text)
      end
      stats = InstantRecord::Compiler::WasmTree.build(source: emit, target: tree)
      [stats, Dir.glob("**/*.rb", base: tree).to_h { |rel| [rel, File.read(File.join(tree, rel))] }]
    end
  end

  def with_path(prepend_dir)
    old_path = ENV["PATH"]
    old_cc = ENV["CC"]
    ENV["PATH"] = "#{prepend_dir}#{File::PATH_SEPARATOR}#{old_path}"
    ENV["CC"] = File.join(prepend_dir, "cc")
    yield
  ensure
    ENV["PATH"] = old_path
    ENV["CC"] = old_cc
  end

  def create_consumer_app(app_root)
    FileUtils.mkdir_p(File.join(app_root, "app/models"))
    FileUtils.mkdir_p(File.join(app_root, "app/controllers"))
    FileUtils.mkdir_p(File.join(app_root, "app/views/layouts"))
    FileUtils.mkdir_p(File.join(app_root, "app/views/pwa"))
    FileUtils.mkdir_p(File.join(app_root, "app/javascript/controllers"))
    FileUtils.mkdir_p(File.join(app_root, "app/screens"))
    FileUtils.mkdir_p(File.join(app_root, "config"))
    FileUtils.mkdir_p(File.join(app_root, "db/migrate"))

    File.write(File.join(app_root, "Gemfile"), "source 'https://rubygems.org'\n")
    File.write(File.join(app_root, "config/routes.rb"), "Rails.application.routes.draw { root 'tasks#index' }\n")
    File.write(File.join(app_root, "app/models/task.rb"), "class Task < ApplicationRecord\n  include InstantRecord::Syncable\nend\n")
    File.write(File.join(app_root, "app/screens/tasks_screen.rb"), <<~RUBY)
      class TasksScreen < InstantRecord::Native::Screen
        contract "TasksView" do |c|
          c.string :heading
          c.int :count
          c.action :refresh
        end

        def body
          swift "TasksView" do
            prop "heading", "Tasks"
            number "count", 0
          end
        end
      end
    RUBY
    File.write(File.join(app_root, "app/views/layouts/application.html.erb"), <<~HTML)
      <html><head>
        <link rel="preconnect" href="https://fonts.example.test">
        <link rel="stylesheet" href="https://fonts.example.test/font.css">
      </head><body><%= yield %></body></html>
    HTML
    File.write(File.join(app_root, "app/views/pwa/service-worker.js"), "// sw\n")
    File.write(File.join(app_root, "app/javascript/controllers/tasks_controller.js"), "export default {}\n")
    File.write(File.join(app_root, "db/schema.rb"), <<~RUBY)
      ActiveRecord::Schema[8.1].define(version: 2026_11_20_000001) do
        add_foreign_key "tasks", "users"
      end
    RUBY
    File.write(File.join(app_root, "db/migrate/20261120000001_create_tasks.rb"), <<~RUBY)
      class CreateTasks < ActiveRecord::Migration[8.1]
        def change
          create_table :tasks, id: :string do |t|
            t.string :title
          end
        end
      end
    RUBY
  end

  def create_fake_toolchain(dir)
    tools = File.join(dir, "tools")
    spinel = File.join(tools, "spinel")
    wasi = File.join(tools, "wasi-sdk")
    sqlite = File.join(tools, "sqlite")
    rails_gems = File.join(tools, "rails_gems")
    node_modules = File.join(tools, "web_node_modules")
    cache = File.join(tools, "cache")
    bin_dir = File.join(tools, "bin")
    call_log = File.join(tools, "calls.log")

    [
      File.join(spinel, "bin"),
      File.join(spinel, "lib/wasm32-wasi"),
      File.join(spinel, "lib/regexp"),
      File.join(spinel, "packages/json"),
      File.join(spinel, "packages/stringio"),
      File.join(spinel, "packages/zlib"),
      File.join(wasi, "bin"),
      sqlite,
      File.join(rails_gems, "turbo-rails"),
      node_modules,
      cache,
      bin_dir
    ].each { |path| FileUtils.mkdir_p(path) }
    File.write(call_log, "")

    File.write(File.join(spinel, "lib/wasm32-wasi/libspinel_rt.a"), "rt")
    File.write(File.join(spinel, "lib/libspinel_rt.a"), "rt")
    File.write(File.join(spinel, "lib/regexp/re.c"), "/* re */\n")
    File.write(File.join(spinel, "lib/rt_core.c"), "/* rt */\n")
    File.write(File.join(spinel, "Makefile"), "RE_SRC = lib/regexp/re.c\nRT_MEMBERS = rt_core\n")
    %w[json stringio zlib].each do |pkg|
      File.write(File.join(spinel, "packages/#{pkg}/sp_#{pkg}_wasi.o"), "o")
      File.write(File.join(spinel, "packages/#{pkg}/sp_#{pkg}.o"), "o")
      File.write(File.join(spinel, "packages/#{pkg}/sp_#{pkg}.c"), "/* pkg */\n")
    end
    File.write(File.join(sqlite, "sqlite3.c"), "/* sqlite */\n")
    File.write(File.join(sqlite, "sqlite3.h"), "/* sqlite */\n")
    File.write(File.join(rails_gems, "turbo-rails/turbo.min.js"), "// turbo\n")

    roundhouse = File.join(tools, "roundhouse")
    write_exec(roundhouse, <<~SH)
      #!/bin/sh
      echo "roundhouse $*" >> "#{call_log}"
      out=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
      done
      mkdir -p "$out/runtime/active_record" "$out/config" "$out/app/models/instant_record/client" "$out/app/views"
      printf 'require_relative "runtime/db"\\n' > "$out/boot.rb"
      printf 'require_relative "boot"\\nif ARGV.length > 0 && ARGV[0] == "sidekiq"\\nend\\n' > "$out/main.rb"
      printf 'allocator = "jemalloc"\\n' > "$out/spin.toml"
      printf 'module Schema; end\\n' > "$out/config/schema.rb"
      printf 'pin "tasks", to: "/assets/controllers/tasks_controller.js"\\n' > "$out/config/importmap.rb"
      printf 'require "openssl"\\n  def self.aes_256_gcm_encrypt; end\\nend\\n' > "$out/runtime/message_digest.rb"
      printf 'sqlite3_bind_int64\\n' > "$out/runtime/db.rb"
      printf '    def has_changes_to_save?\\n    end\\n' > "$out/runtime/active_record/base.rb"
      printf '    def quote_string(str)\\n    end\\n' > "$out/runtime/active_record/connection.rb"
      printf 'module InstantRecord; module Host; end; end\\n' > "$out/app/models/instant_record/host.rb"
    SH

    write_exec(File.join(spinel, "bin/spin"), <<~SH)
      #!/bin/sh
      echo "spin $*" >> "#{call_log}"
      echo "-I."
    SH

    write_exec(File.join(spinel, "bin/spinel"), <<~SH)
      #!/bin/sh
      echo "spinel $*" >> "#{call_log}"
      out=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
      done
      printf 'int app_boot(void) { return 0; }\\n' > "$out"
    SH

    touch_out_script = <<~SH
      #!/bin/sh
      echo "$(basename "$0") $*" >> "#{call_log}"
      out=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
      done
      if [ -n "$out" ]; then
        mkdir -p "$(dirname "$out")"
        printf '\\0asm\\1\\0\\0\\0' > "$out"
      fi
    SH

    write_exec(File.join(wasi, "bin/clang"), touch_out_script)
    write_exec(File.join(wasi, "bin/llvm-strip"), touch_out_script)
    write_exec(File.join(bin_dir, "cc"), touch_out_script)
    write_exec(File.join(bin_dir, "xcrun"), <<~SH)
      #!/bin/sh
      echo "xcrun $*" >> "#{call_log}"
      if [ "$3" = "--show-sdk-path" ]; then
        echo "/FakeSDK"
        exit 0
      fi
      out=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
      done
      if [ -n "$out" ]; then
        mkdir -p "$(dirname "$out")"
        printf 'obj' > "$out"
      fi
    SH

    ar_script = <<~SH
      #!/bin/sh
      echo "$(basename "$0") $*" >> "#{call_log}"
      mkdir -p "$(dirname "$2")"
      printf '!<arch>\\n' > "$2"
    SH
    write_exec(File.join(wasi, "bin/llvm-ar"), ar_script)
    write_exec(File.join(bin_dir, "ar"), ar_script)

    write_exec(File.join(bin_dir, "npx"), <<~SH)
      #!/bin/sh
      echo "npx $*" >> "#{call_log}"
      out=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--outDir" ]; then out="$2"; shift 2; else shift; fi
      done
      mkdir -p "$out/harness" "$out/assets"
      printf '<!doctype html><html><head>  </head><body></body></html>' > "$out/index.html"
      printf '// worker\\n' > "$out/harness/worker-abc.js"
    SH

    toolchain_file = File.join(tools, "toolchain.env")
    File.write(toolchain_file, <<~ENV)
      TOOLS=#{tools}
      SPINEL_HOME=$TOOLS/spinel
      ROUNDHOUSE_BIN=$TOOLS/roundhouse
      WASI_SDK=$TOOLS/wasi-sdk
      SQLITE_SRC=$TOOLS/sqlite
      RAILS_GEMS=$TOOLS/rails_gems
      WEB_NODE_MODULES=$TOOLS/web_node_modules
      CACHE=$TOOLS/cache
    ENV

    { toolchain_file: toolchain_file, roundhouse: roundhouse, bin_dir: bin_dir, call_log: call_log }
  end

  def write_exec(path, content)
    File.write(path, content)
    File.chmod(0o755, path)
  end
end
