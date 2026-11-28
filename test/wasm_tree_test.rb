require "test_helper"
require "instant_record/compiler"
require "fileutils"
require "tmpdir"

class WasmTreeTest < ActiveSupport::TestCase
  WasmTree = InstantRecord::Compiler::WasmTree
  BuildError = InstantRecord::Compiler::BuildError

  test "WasmTree.build runs end-to-end for demo false and true, replaces stale targets, and filters ignored folders" do
    Dir.mktmpdir do |dir|
      source = File.join(dir, "emit")
      target = File.join(dir, "tree")

      write_tree(source, minimal_files.merge(
        "runtime/action_text.rb" => "class ActionTextStub\n  def run\n  end\nend\n",
        "app/views/slack/channels/_sidebar.rb" => sidebar_fixture,
        "build/artifact.rb" => "ignored\n",
        "storage/dev.sqlite3" => "ignored\n",
        "node_modules/pkg/index.js" => "ignored\n",
        "e2e/spec.rb" => "ignored\n",
        "test/unit_test.rb" => "ignored\n"
      ))
      FileUtils.mkdir_p(target)
      File.write(File.join(target, "stale.rb"), "stale\n")

      non_demo = WasmTree.build(source: source, target: target, demo: false)
      assert_equal({ touched: 1, pruned_lines: 0 }, non_demo)
      refute File.exist?(File.join(target, "stale.rb"))
      WasmTree::IGNORE_PATTERNS.each do |ignored|
        refute File.exist?(File.join(target, ignored)), "expected #{ignored} to be excluded"
      end
      assert_equal WasmTree::WASM_THREADS_RB, File.read(File.join(target, "runtime/wasm_threads.rb"))
      assert_equal(
        "require_relative \"runtime/wasm_threads\"\nrequire_relative \"runtime/db\"\n",
        File.read(File.join(target, "boot.rb"))
      )
      assert_equal "class ActionTextStub\n  def run\n  end\nend\n", File.read(File.join(target, "runtime/action_text.rb"))
      assert_equal sidebar_fixture, File.read(File.join(target, "app/views/slack/channels/_sidebar.rb"))

      demo_stats = WasmTree.build(source: source, target: target, demo: true)
      assert_equal({ touched: 1, pruned_lines: 4 }, demo_stats)
      assert_equal(
        "# Pruned for browser wasm (see WasmTree)\n#{WasmTree::PRUNED_STUBS.fetch('runtime/action_text.rb')}",
        File.read(File.join(target, "runtime/action_text.rb"))
      )
      assert_includes File.read(File.join(target, "app/views/slack/channels/_sidebar.rb")), "channels.each do |channel_row|"
    end
  end

  test "threading constant renaming and timeout commenting apply to boot, main_wasm, runtime, and config only" do
    stats, tree = build_tree({
      "boot.rb" => "Thread.current\nrequire \"timeout\"\nrequire_relative \"runtime/db\"\n",
      "main_wasm.rb" => "Mutex.new\nQueue.new\n",
      "runtime/nested/sync.rb" => "ConditionVariable.new\nFiber.yield\nThreadSafe = true\n",
      "runtime/timeout_only.rb" => "require \"timeout\"\n",
      "config/nested/workers.rb" => "Thread.new\nrequire \"timeout\"\n",
      "app/models/job.rb" => "Thread.new\nMutex.new\nrequire \"timeout\"\n",
      "app/controllers/jobs_controller.rb" => "Queue.new\nFiber.yield\n"
    })

    assert_equal({ touched: 4, pruned_lines: 0 }, stats)
    assert_equal(
      "WasmThread.current\n# require \"timeout\"  (wasm: see runtime/wasm_threads.rb)\n" \
      "require_relative \"runtime/wasm_threads\"\nrequire_relative \"runtime/db\"\n",
      tree["boot.rb"]
    )
    assert_equal "WasmMutex.new\nWasmQueue.new\n", tree["main_wasm.rb"]
    assert_equal "WasmConditionVariable.new\nWasmFiber.yield\nThreadSafe = true\n", tree["runtime/nested/sync.rb"]
    assert_equal "# require \"timeout\"  (wasm: see runtime/wasm_threads.rb)\n", tree["runtime/timeout_only.rb"]
    assert_equal "WasmThread.new\n# require \"timeout\"  (wasm: see runtime/wasm_threads.rb)\n", tree["config/nested/workers.rb"]
    assert_equal "Thread.new\nMutex.new\nrequire \"timeout\"\n", tree["app/models/job.rb"]
    assert_equal "Queue.new\nFiber.yield\n", tree["app/controllers/jobs_controller.rb"]
  end

  test "patch_message_digest replaces aes_256_gcm_encrypt with AES_STUB, comments openssl, and raises when anchor is missing" do
    original = <<~RUBY
      require "openssl"

      module MessageDigest
        def self.sha256(str)
          str
        end

        def self.aes_256_gcm_encrypt(key, iv, plain)
          OpenSSL::Cipher.new("aes-256-gcm")
        end
      end
    RUBY

    _stats, tree = build_tree({ "runtime/message_digest.rb" => original })
    expected = <<~RUBY + WasmTree::AES_STUB
      # require "openssl"  (wasm: no OpenSSL build)

      module MessageDigest
        def self.sha256(str)
          str
        end

    RUBY
    assert_equal expected, tree["runtime/message_digest.rb"]

    err = assert_raises(BuildError) do
      build_tree({ "runtime/message_digest.rb" => "module MessageDigest\nend\n" })
    end
    assert_match(/Expected aes_256_gcm_encrypt in .*runtime\/message_digest\.rb\z/, err.message)

    assert_raises(Errno::ENOENT) { build_tree({ "runtime/message_digest.rb" => nil }) }
  end

  test "patch_sqlite_shims renames sqlite3_bind_int64 and sqlite3_last_insert_rowid to rh_ shims" do
    db_src = <<~RUBY
      sqlite3_bind_int64(stmt, 1, val)
      sqlite3_last_insert_rowid(conn)
      sqlite3_step(stmt)
    RUBY

    _stats, tree = build_tree({ "runtime/db.rb" => db_src })
    assert_equal <<~RUBY, tree["runtime/db.rb"]
      rh_sqlite3_bind_int64(stmt, 1, val)
      rh_sqlite3_last_insert_rowid(conn)
      sqlite3_step(stmt)
    RUBY

    assert_raises(Errno::ENOENT) { build_tree({ "runtime/db.rb" => nil }) }
  end

  test "patch_read_tracking hooks all seven query methods, is idempotent, and skips when adapter is absent" do
    adapter = <<~RUBY
      module SqliteAdapter
        def self.each_row(sql, binds = [])
        end
        def select_all(sql)
        end
        def self.select_rows(sql, binds)
        end
        def select_value(sql)
        end
        def select_values(sql, name = nil)
        end
        def self.query(sql)
        end
        def exec_query(sql, name = "SQL")
        end
        def execute(sql)
        end
        def query_other(sql_text)
        end
      end
    RUBY

    _stats, tree = build_tree({ "runtime/sqlite_adapter.rb" => adapter })
    expected = <<~RUBY
      module SqliteAdapter
        def self.each_row(sql, binds = [])
          InstantRecord::ReadTracker.record_sql(sql)
        end
        def select_all(sql)
          InstantRecord::ReadTracker.record_sql(sql)
        end
        def self.select_rows(sql, binds)
          InstantRecord::ReadTracker.record_sql(sql)
        end
        def select_value(sql)
          InstantRecord::ReadTracker.record_sql(sql)
        end
        def select_values(sql, name = nil)
          InstantRecord::ReadTracker.record_sql(sql)
        end
        def self.query(sql)
          InstantRecord::ReadTracker.record_sql(sql)
        end
        def exec_query(sql, name = "SQL")
          InstantRecord::ReadTracker.record_sql(sql)
        end
        def execute(sql)
        end
        def query_other(sql_text)
        end
      end
    RUBY
    assert_equal expected, tree["runtime/sqlite_adapter.rb"]

    _stats_again, tree_again = build_tree({ "runtime/sqlite_adapter.rb" => tree["runtime/sqlite_adapter.rb"] })
    assert_equal expected, tree_again["runtime/sqlite_adapter.rb"]

    _stats_missing, tree_missing = build_tree
    refute_includes tree_missing, "runtime/sqlite_adapter.rb"
  end

  test "model patches apply datetime casts, remote timestamp preservation, and idempotent update! key symbolization" do
    model = <<~RUBY
      class Message
        def assign_field(name, value)
          if name == "published_at"
            if respond_to?(:published_at=)
              self.published_at = value
            end
          end
          if name == "title"
            if respond_to?(:title=)
              self.title = value
            end
          end
        end

        def fill_timestamps(creating)
          if !(creating) || @updated_at_raw.nil? || @updated_at_raw.empty?
            @updated_at_raw = now
          end
        end

        def update!(attrs)
          @attrs = attrs
        end
      end
    RUBY

    _stats, tree = build_tree({ "app/models/nested/message.rb" => model })
    expected = <<~RUBY
      class Message
        def assign_field(name, value)
          if name == "published_at"
            if respond_to?(:published_at=)
              self.published_at = ActiveSupport.cast_datetime(value)
            end
          end
          if name == "title"
            if respond_to?(:title=)
              self.title = value
            end
          end
        end

        def fill_timestamps(creating)
          if (!(creating) && !InstantRecord::Client.applying_remote?) || @updated_at_raw.nil? || @updated_at_raw.empty?
            @updated_at_raw = now
          end
        end

        def update!(attrs)
          #{WasmTree::SYMBOLIZE_ATTRS}
          @attrs = attrs
        end
      end
    RUBY

    assert_equal expected, tree["app/models/nested/message.rb"]

    _stats_again, tree_again = build_tree({ "app/models/nested/message.rb" => tree["app/models/nested/message.rb"] })
    assert_equal expected, tree_again["app/models/nested/message.rb"]
  end

  test "patch_active_record_changed inserts CHANGED_METHOD before has_changes_to_save? and raises when missing" do
    base = <<~RUBY
      module ActiveRecord
        class Base
          def has_changes_to_save?
            !changes_to_save.empty?
          end
        end
      end
    RUBY

    _stats, tree = build_tree({ "runtime/active_record/base.rb" => base })
    assert_equal(
      "module ActiveRecord\n  class Base\n#{WasmTree::CHANGED_METHOD}    def has_changes_to_save?\n      !changes_to_save.empty?\n    end\n  end\nend\n",
      tree["runtime/active_record/base.rb"]
    )

    err = assert_raises(BuildError) do
      build_tree({ "runtime/active_record/base.rb" => "module ActiveRecord\n  class Base\n  end\nend\n" })
    end
    assert_match(/Expected def has_changes_to_save\? in .*runtime\/active_record\/base\.rb\z/, err.message)

    assert_raises(Errno::ENOENT) { build_tree({ "runtime/active_record/base.rb" => nil }) }
  end

  test "patch_connection_quoting inserts QUOTING_METHODS, stays idempotent, and raises on missing file or invalid state" do
    connection = "module ActiveRecord\n  class Connection\n    def quote_string(str)\n      str\n    end\n  end\nend\n"
    _stats, tree = build_tree({ "runtime/active_record/connection.rb" => connection })
    expected = "module ActiveRecord\n  class Connection\n#{WasmTree::QUOTING_METHODS}    def quote_string(str)\n      str\n    end\n  end\nend\n"
    assert_equal expected, tree["runtime/active_record/connection.rb"]

    both_present = "class Connection\n  def quote_column_name(name)\n  end\n  def quote_table_name(name)\n  end\nend\n"
    assert_equal both_present, build_tree({ "runtime/active_record/connection.rb" => both_present }).last["runtime/active_record/connection.rb"]

    missing_err = assert_raises(BuildError) { build_tree({ "runtime/active_record/connection.rb" => nil }) }
    assert_match(/Expected .*runtime\/active_record\/connection\.rb\z/, missing_err.message)

    one_only = "class Connection\n  def quote_column_name(name)\n  end\n    def quote_string(str)\n  end\nend\n"
    partial_err = assert_raises(BuildError) { build_tree({ "runtime/active_record/connection.rb" => one_only }) }
    assert_match(/Expected def quote_string\(str\) and both or neither quoting method in /, partial_err.message)

    no_anchor_err = assert_raises(BuildError) { build_tree({ "runtime/active_record/connection.rb" => "class Connection\nend\n" }) }
    assert_match(/Expected def quote_string\(str\) and both or neither quoting method in /, no_anchor_err.message)
  end

  test "patch_emitted_views rewrites each_with_index raw captures and bogus button_to tag_attr only when matched" do
    bogus = '#{ActionView::ViewHelpers.tag_attr("form", { data: { turbo: false, action: "submit->issues#submit" } })}'
    button = 'class=\"#{"button_to"}\">'

    _stats, tree = build_tree({
      "app/views/items/index.rb" => "items.each_with_index do |i, idx|\n  ActionView::ViewHelpers.raw(_cap)\nend\n",
      "app/views/items/form.rb" => "<form #{bogus} #{button}</form>\n",
      "app/views/items/untouched.rb" => "ActionView::ViewHelpers.raw(_cap)\n#{button}\n"
    })

    assert_equal "items.each_with_index do |i, idx|\n  io << _cap\nend\n", tree["app/views/items/index.rb"]
    assert_equal(
      '<form  class=\"#{"button_to"}\" data-turbo=\"false\" data-action=\"submit-&gt;issues#submit\"></form>' + "\n",
      tree["app/views/items/form.rb"]
    )
    assert_equal "ActionView::ViewHelpers.raw(_cap)\n#{button}\n", tree["app/views/items/untouched.rb"]
  end

  test "patch_slack_sidebar rewrites channel loop in demo mode only and raises when loop markers are missing" do
    _stats, demo_tree = build_tree(
      { "app/views/slack/channels/_sidebar.rb" => sidebar_fixture },
      demo: true
    )
    assert_equal <<~RUBY, demo_tree["app/views/slack/channels/_sidebar.rb"]
      header = channel.name
      channels.each do |channel_row|
        label = channel_row.name
        active = channel_row == channel
      end
      dms.each do |dm|
        other = channel
      end
    RUBY

    _stats_non_demo, non_demo_tree = build_tree(
      { "app/views/slack/channels/_sidebar.rb" => "no loop here\n" },
      demo: false
    )
    assert_equal "no loop here\n", non_demo_tree["app/views/slack/channels/_sidebar.rb"]

    missing_start = assert_raises(BuildError) do
      build_tree({ "app/views/slack/channels/_sidebar.rb" => "dms.each do |dm|\nend\n" }, demo: true)
    end
    assert_match(/Expected channel loop in .*_sidebar\.rb\z/, missing_start.message)

    missing_stop = assert_raises(BuildError) do
      build_tree({ "app/views/slack/channels/_sidebar.rb" => "channels.each do |channel|\nend\n" }, demo: true)
    end
    assert_match(/Expected channel loop in .*_sidebar\.rb\z/, missing_stop.message)

    assert_raises(Errno::ENOENT) { build_tree({}, demo: true) }
  end

  test "prepend_wasm_threads_require inserts before first require or require_relative and raises when absent" do
    _stats, tree_rel = build_tree({ "boot.rb" => "# banner\n\nrequire_relative \"runtime/db\"\nrequire \"json\"\n" })
    assert_equal(
      "# banner\n\nrequire_relative \"runtime/wasm_threads\"\nrequire_relative \"runtime/db\"\nrequire \"json\"\n",
      tree_rel["boot.rb"]
    )

    _stats, tree_req = build_tree({ "boot.rb" => "# banner\nrequire \"json\"\n" })
    assert_equal(
      "# banner\nrequire_relative \"runtime/wasm_threads\"\nrequire \"json\"\n",
      tree_req["boot.rb"]
    )

    err = assert_raises(BuildError) { build_tree({ "boot.rb" => "# no requires\nputs :ok\n" }) }
    assert_match(/Expected require line in .*boot\.rb\z/, err.message)

    assert_raises(Errno::ENOENT) { build_tree({ "boot.rb" => nil }) }
  end

  test "prune_dead_subsystems stubs present PRUNED_STUBS files and counts removed newlines in demo mode only" do
    files = {
      "app/views/slack/channels/_sidebar.rb" => sidebar_fixture,
      "runtime/action_text.rb" => "a\nb\nc\n",
      "runtime/cable.rb" => "x\ny\n",
      "runtime/active_storage_disk.rb" => "only_one_line_without_trailing_newline",
      "runtime/custom_kept.rb" => "keep_me\n"
    }

    non_demo_stats, non_demo_tree = build_tree(files, demo: false)
    assert_equal 0, non_demo_stats[:pruned_lines]
    assert_equal "a\nb\nc\n", non_demo_tree["runtime/action_text.rb"]
    assert_equal "x\ny\n", non_demo_tree["runtime/cable.rb"]

    demo_stats, demo_tree = build_tree(files, demo: true)
    assert_equal 5, demo_stats[:pruned_lines]
    assert_equal "# Pruned for browser wasm (see WasmTree)\n#{WasmTree::PRUNED_STUBS.fetch('runtime/action_text.rb')}", demo_tree["runtime/action_text.rb"]
    assert_equal "# Pruned for browser wasm (see WasmTree)\n#{WasmTree::PRUNED_STUBS.fetch('runtime/cable.rb')}", demo_tree["runtime/cable.rb"]
    assert_equal "# Pruned for browser wasm (see WasmTree)\n", demo_tree["runtime/active_storage_disk.rb"]
    assert_equal "keep_me\n", demo_tree["runtime/custom_kept.rb"]
    refute_includes demo_tree, "runtime/sidekiq_redis.rb"
  end

  private

  def minimal_files
    {
      "boot.rb" => "require_relative \"runtime/db\"\n",
      "main_wasm.rb" => "Mutex.new\n",
      "runtime/message_digest.rb" => "  def self.aes_256_gcm_encrypt\n",
      "runtime/db.rb" => "",
      "runtime/active_record/base.rb" => "    def has_changes_to_save?\n",
      "runtime/active_record/connection.rb" => "    def quote_string(str)\n"
    }
  end

  def sidebar_fixture
    <<~RUBY
      header = channel.name
      channels.each do |channel|
        label = channel.name
        active = channel == channel
      end
      dms.each do |dm|
        other = channel
      end
    RUBY
  end

  def write_tree(root, files)
    files.compact.each do |rel, content|
      path = File.join(root, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
  end

  def build_tree(files = {}, demo: false)
    Dir.mktmpdir do |dir|
      source = File.join(dir, "emit")
      target = File.join(dir, "tree")
      write_tree(source, minimal_files.merge(files))
      stats = WasmTree.build(source: source, target: target, demo: demo)
      tree = Dir.glob("**/*.rb", base: target).sort.to_h { |rel| [rel, File.read(File.join(target, rel))] }
      [stats, tree]
    end
  end
end
