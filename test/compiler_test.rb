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

  test "DemoCarver and GemVendor stage the real demo with all seams intact" do
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app-src")
      InstantRecord::Compiler::DemoCarver.carve(
        gem_src: GEM_ROOT,
        target: app,
        overlay_dir: File.join(PIPELINE_DIR, "demo"),
        native: false
      )

      refute File.exist?(File.join(app, "config/initializers/ruby_llm.rb"))
      refute File.exist?(File.join(app, "app/screens"))
      assert_includes File.read(File.join(app, "app/models/mail_entry.rb")), "include InstantRecord::Syncable"
      assert_includes File.read(File.join(app, "app/models/slack/seeds.rb")), "Browser build: the seeding routines"

      count = InstantRecord::Compiler::GemVendor.vendor(gem_src: GEM_ROOT, app_dir: app, demo: true)
      assert_equal 15, count
      assert File.file?(File.join(app, "lib/instant_record/read_tracker.rb"))
      assert_includes File.read(File.join(app, "lib/instant_record.rb")), "def browser? = true"
      refute File.exist?(File.join(app, "lib/instant_record/syncable.rb"))
      assert File.file?(File.join(app, "app/models/concerns/syncable.rb"))
      assert_includes File.read(File.join(app, "app/models/concerns/syncable.rb")), "self.id = SecureRandom.uuid if id.blank?"
      assert_includes File.read(File.join(app, "app/models/mail_entry.rb")), "include Syncable"
      assert File.file?(File.join(app, "sig/instant_record/native.rbs"))
      assert_includes File.read(File.join(app, "app/views/todo/issues/index.html.erb")), '<% content_for(:demo_scope, "todo") %>'

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

  test "GemVendor unwraps browser_only and client_only blocks and strips server_only blocks" do
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(app, "app/controllers"))
      FileUtils.mkdir_p(File.join(app, "app/screens"))
      FileUtils.mkdir_p(File.join(app, "app/models"))

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

      controller = File.read(File.join(app, "app/controllers/items_controller.rb"))
      refute_includes controller, "require_server_secret"
      refute_includes controller, "browser_only"
      assert_includes controller, "  skip_forgery_protection\n"

      screen = File.read(File.join(app, "app/screens/items_screen.rb"))
      refute_includes screen, "client_only"
      assert_includes screen, "  def fast_path\n    true\n  end\n"
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
      File.write(File.join(emit, "app/models/instant_record/client/transport.rb"), <<~RUBY)
        File.write(REQUEST, body)
        File.read(RESPONSE)
      RUBY
      File.write(File.join(emit, "app/models/instant_record/client/notifier.rb"), <<~RUBY)
        File.write("/host/notify", message)
      RUBY

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
        pipeline_dir: PIPELINE_DIR
      )

      wasm_main = File.read(File.join(emit, "main_wasm.rb"))
      assert_includes wasm_main, "module WasmBridge"
      assert_includes wasm_main, 'File.read("/host/in")'
      assert_includes wasm_main, "InstantRecord::ReadTracker.track"
      assert_includes wasm_main, "InstantRecord::Client.capture_local_changes"
      assert_includes wasm_main, "X-Instant-Record-Reads: "
      assert_includes wasm_main, 'if previous < "00000020261120000001"'
      assert_includes wasm_main, '\#{x}\#@y\#$z'
      assert_includes wasm_main, "InstantRecord.sync(Note)"
      assert_includes wasm_main, "InstantRecord::Client.streaming = true"

      screens = InstantRecord::Compiler::EntryBuilder.write_native_entry(
        tree_dir: emit,
        app_dir: app,
        demo: false,
        models: ["Note"],
        migration_plan: plan
      )

      assert_equal ["inbox_list"], screens
      native_main = File.read(File.join(emit, "main_native.rb"))
      assert_includes native_main, "module NativeBridge"
      assert_includes native_main, 'when "inbox_list" then InboxListScreen.new(params)'
      assert_includes native_main, 'NativeHost.ir_host_give("reads", InstantRecord::ReadTracker.serialize(reads))'
      assert_includes native_main, 'InstantRecord::SyncMetadata.set("schema_version", "00000020261120000001")'
      assert_includes native_main, "InstantRecord::Client.streaming = false"

      transport = File.read(File.join(emit, "app/models/instant_record/client/transport.rb"))
      assert_includes transport, 'NativeHost.ir_host_give("request", body)'
      assert_includes transport, 'NativeHost.ir_host_take("response")'
      notifier = File.read(File.join(emit, "app/models/instant_record/client/notifier.rb"))
      assert_includes notifier, 'NativeHost.ir_host_give("notify", message)'
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
      File.write(File.join(emit, "runtime/action_text.rb"), "line1\nline2\n")
      File.write(File.join(emit, "app/models/note.rb"), <<~RUBY)
        if name == "created_at"
          if respond_to?(:created_at=)
            self.created_at = value
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
      assert_includes File.read(File.join(tree, "app/views/slack/channels/_sidebar.rb")), "channel_row == channel"
      assert_includes File.read(File.join(tree, "runtime/action_text.rb")), "# Pruned for browser wasm"
    end
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
      assert File.file?(output.join("index.html"))
      assert File.file?(output.join("instant-record-release.json"))
      assert File.file?(output.join("service-worker.js"))
      assert File.file?(output.join("assets/turbo.min.js"))
      assert_equal 1, Dir.glob(output.join("app-*.wasm").to_s).size
      refute File.exist?(Pathname(app_root).join("tmp/instant_record/compiled/pipeline")), "pipeline scripts should not be copied into tmp/"

      index_html = output.join("index.html").read
      assert_includes index_html, '<link rel="modulepreload" href="/harness/worker-abc.js">'
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

      # Native host build runs end-to-end and outputs libinstant_record_app.a + host.
      native_out = with_path(fake[:bin_dir]) do
        InstantRecord::Compiler.build_native(
          root: app_root,
          models: ["Task"],
          toolchain: fake[:toolchain_file],
          endpoint: "/instant_record"
        )
      end
      assert File.file?(native_out.join("libinstant_record_app.a"))
      assert File.file?(native_out.join("host"))

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
    end
  end

  private

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
    File.write(File.join(app_root, "app/screens/tasks_screen.rb"), "class TasksScreen < InstantRecord::Native::Screen\n  def body; navigation(title: 'Tasks') {}; end\nend\n")
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
      printf 'File.write(REQUEST, body)\\nFile.read(RESPONSE)\\n' > "$out/app/models/instant_record/client/transport.rb"
      printf 'File.write("/host/notify", body)\\n' > "$out/app/models/instant_record/client/notifier.rb"
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
