require "test_helper"
require "instant_record/compiler"
require "fileutils"
require "tmpdir"

class StaticLinterTest < ActiveSupport::TestCase
  StaticLinter = InstantRecord::Compiler::StaticLinter
  GEM_ROOT = File.expand_path("..", __dir__)

  test "flags >31-bit integer literals, constant arithmetic, shifts, powers, byte helpers, and constant propagation" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/models"))
      File.write(File.join(dir, "app/models/media.rb"), <<~RUBY)
        class Media < ApplicationRecord
          OK_MAX = 2_147_483_647
          OK_MIN = -2_147_483_648
          OK_ONE_GB = 1024 * 1024 * 1024
          OK_NEG_POW = (-2)**31

          BAD_LITERAL = 2_147_483_648
          BAD_NEGATIVE = -2_147_483_649
          BAD_PRODUCT = 2 * 1024 * 1024 * 1024
          BAD_INTERMEDIATE = (2 * 1024 * 1024 * 1024) / 2
          BAD_SHIFT = 1 << 31
          BAD_POWER = 2**31
          BAD_BYTES = 2.gigabytes
          BAD_PROPAGATED = 2 * OK_ONE_GB

          server_only do
            SERVER_OK = 4 * 1024 * 1024 * 1024
          end
        end
      RUBY

      result = StaticLinter.lint(dir, staged: true)
      refute result.ok?

      overflows = result.diagnostics.select { |d| d.rule == :integer_overflow }
      lines = overflows.map(&:line)

      assert_equal [7, 8, 9, 10, 11, 12, 13, 14], lines, overflows.map(&:to_s).join("\n")
    end
  end

  test "ignores db/schema.rb timestamps and config/initializers during doctor lint" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/models"))
      FileUtils.mkdir_p(File.join(dir, "config/initializers"))
      FileUtils.mkdir_p(File.join(dir, "db"))

      File.write(File.join(dir, "app/models/task.rb"), "class Task < ApplicationRecord; MAX = 100; end\n")
      File.write(File.join(dir, "config/initializers/instant_record.rb"), "InstantRecord.config.max_file_size = 4 * 1024 * 1024 * 1024\n")
      File.write(File.join(dir, "db/schema.rb"), "ActiveRecord::Schema[8.1].define(version: 2026_11_21_000001) {}\n")

      assert StaticLinter.lint(dir, staged: false).ok?

      # In a staged tree, db/schema.rb is still ignored, while any Ruby file
      # actually left in the staged tree (like an uncarved initializer) is checked.
      FileUtils.rm_rf(File.join(dir, "config/initializers"))
      assert StaticLinter.lint(dir, staged: true).ok?
    end
  end

  test "discovers the files that enter compilation" do
    Dir.mktmpdir do |dir|
      files = %w[
        Rakefile.rb app/controllers/c.rb app/helpers/h.rb app/jobs/j.rb app/models/a/b.rb app/models/m.rb app/screens/s.rb
        config/application.rb config/importmap.rb config/initializers/i.rb config/routes.rb config/routes/r.rb
        db/schema.rb lib/l.rb lib/tasks/t.rb test/t.rb
      ]
      files.each do |file|
        FileUtils.mkdir_p(File.dirname(File.join(dir, file)))
        File.write(File.join(dir, file), "")
      end
      discover = ->(**options) { StaticLinter.new(root: dir, **options).discover_files.map { |path| path.delete_prefix("#{dir}/") } }

      compiled = files - %w[Rakefile.rb app/jobs/j.rb config/initializers/i.rb db/schema.rb lib/l.rb lib/tasks/t.rb test/t.rb]
      assert_equal compiled.sort, discover.call(staged: false)
      assert_equal (files - %w[db/schema.rb lib/tasks/t.rb test/t.rb]).sort, discover.call(staged: true)
      assert_equal (compiled - %w[app/models/a/b.rb app/models/m.rb config/routes.rb]).sort, discover.call(exclude: ["/app/models/", "config/routes.rb"])
      assert_equal %w[app/models/m.rb lib/l.rb], discover.call(only_files: ["lib/l.rb", "/app/models/m.rb", "gone.rb", "db/schema.rb"], exclude: "db")
      assert_empty StaticLinter.new(root: File.join(dir, "missing")).discover_files

      FileUtils.rm_rf([File.join(dir, "app"), File.join(dir, "config")])
      assert_equal %w[Rakefile.rb lib/l.rb], discover.call(staged: false)
    end
  end

  test "flags untyped {} hashes in Native::Screen params:, args:, props:, defaults, locals, helpers, and setters" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/screens"))
      FileUtils.mkdir_p(File.join(dir, "app/controllers"))

      File.write(File.join(dir, "app/screens/broken_screen.rb"), <<~RUBY)
        class BrokenScreen < InstantRecord::Native::Screen
          def initialize(params = {})
            super(params)
          end

          def body
            empty = {}
            typed = {}
            typed["ok"] = "1"

            row id: "1", link: "next", params: {} do
              swipe "Go", action: "go", args: Hash.new
              button "Edit", action: "edit", args: empty
              item "Good", link: "next", params: typed
              item "GoodStrings", link: "next", params: InstantRecord::Native::Node.strings
              item "Ternary", link: "next", params: param("a").empty? ? {} : { "a" => "1" }
              item "Helper", link: "next", params: blank_map
              swift "Card", props: {}
            end
          end

          def helper_with_default(args: {})
            args
          end

          def blank_map = {}

          def mutate(node)
            node.link_params = {}
          end

          server_only do
            def server_helper(params: {}) = params
          end
        end
      RUBY

      # Controllers using `props: {}` for Inertia are NOT Native::Screen and must not be flagged.
      File.write(File.join(dir, "app/controllers/pages_controller.rb"), <<~RUBY)
        class PagesController < ApplicationController
          def index
            render inertia: "Home", props: {}
          end
        end
      RUBY

      result = StaticLinter.lint(dir, staged: true)
      refute result.ok?

      hash_issues = result.diagnostics.select { |d| d.rule == :untyped_screen_hash }
      assert_equal ["app/screens/broken_screen.rb"], hash_issues.map(&:file).uniq
      assert_equal [2, 11, 12, 13, 16, 17, 18, 22, 29], hash_issues.map(&:line), hash_issues.map(&:to_s).join("\n")
    end
  end

  test "flags server_only constant references from shared and client code across files" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/models"))
      FileUtils.mkdir_p(File.join(dir, "app/controllers"))

      File.write(File.join(dir, "app/models/secret_doc.rb"), <<~RUBY)
        class SecretDoc < ApplicationRecord
          include InstantRecord::Syncable

          server_only do
            SIGNING_KEY = "top-secret"
            MODE = "server"
            class Policy; end
          end

          browser_only do
            MODE = "browser"
          end

          def safe_mode
            MODE
          end

          def safe_defined_check
            defined?(SIGNING_KEY)
          end

          def dead_server_branch
            unless InstantRecord.browser?
              SIGNING_KEY
            end
          end

          def leaked_intra_file
            SIGNING_KEY
          end
        end
      RUBY

      File.write(File.join(dir, "app/controllers/docs_controller.rb"), <<~RUBY)
        class DocsController < ApplicationController
          def index
            @policy = SecretDoc::Policy.new
            @applier = InstantRecord::MutationApplier
          end
        end
      RUBY

      result = StaticLinter.lint(dir, staged: true)
      refute result.ok?

      const_issues = result.diagnostics.select { |d| d.rule == :server_only_constant }
      found = const_issues.map { |d| [d.file, d.line] }
      assert_equal [
        ["app/controllers/docs_controller.rb", 3],
        ["app/controllers/docs_controller.rb", 4],
        ["app/models/secret_doc.rb", 29]
      ], found, const_issues.map(&:to_s).join("\n")
    end
  end

  test "reports the tightest overflowing expression once" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "sizes.rb"), <<~RUBY)
        module Sizes
          GB = 1.gigabyte
          INNER = (2**31) / 2
          OUTER = ((2**31) / 2) * 1000
          HUGE = 1 << 64
          OTHER_CALL = (1 << 64).foo(1)
          PATH = Sizes::GB * 2
          NEGATED = ~4_294_967_295
          FINE = [1 / 0, 1 % 0, 0 << 99, (2**-1) * 2_147_483_647 * 4, (1 << -1) - 2_147_483_647 - 2, 2_147_483_647 >> -1]
          BITS = [
            (6 & 3) * 2_147_483_647,
            (6 | 3) * 2_147_483_647,
            (6 ^ 3) * 2_147_483_647,
            (4 >> 1) * 2_147_483_647,
            ~2_147_483_647 * 2
          ]
        end
      RUBY

      diagnostics = StaticLinter.lint(dir, staged: true).diagnostics
      assert_equal [
        [3, 12], [4, 11], [5, 10], [6, 17], [7, 10], [8, 14], [11, 5], [12, 5], [13, 5], [14, 5], [15, 5]
      ], diagnostics.map { |d| [d.line, d.column] }, diagnostics.map(&:to_s).join("\n")
      assert_equal %w[4294967294 15032385529 10737418235 4294967294 -4294967296], diagnostics.last(5).map { |d| d.message[/evaluates to (-?\d+)/, 1] }
      assert_includes diagnostics[1].message, "Integer \"((2**31) / 2) * 1000\" evaluates to 1073741824000, outside"
      assert_includes diagnostics[2].message, "Integer \"1 << 64\" exceeds 32-bit signed integer range;"
    end
  end

  test "flags untyped hashes in ivars, branches, and parentheses, and not in typed or nested forms" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "forms.rb"), <<~RUBY)
        class Forms < Screen
          def blank = {}
          def optional(a = 1) = {}
          def body
            @props = ({})
            @other = {}
            row params: (if a then b elsif c then {} end)
            row params: (unless a then b else {} end)
            row params: (if a then {}; b end)
            row params: optional, args: self.blank, props: { a: 1 }
            local = {}
            local = param
            row params: local
            merged = {}
            merged.merge!(param)
            row params: merged
            row args: ((blank))
          end
        end
      RUBY

      diagnostics = StaticLinter.lint(dir, staged: true).diagnostics
      assert_equal [5, 7, 8, 17], diagnostics.map(&:line), diagnostics.map(&:to_s).join("\n")
    end
  end

  test "server_only references follow browser? branches, constant paths, and lookup order" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "doc.rb"), <<~RUBY)
        class Doc
          server_only do
            KEY = 1
            Policy = 2
          end
          if !InstantRecord.browser? then KEY else Policy end
          if InstantRecord.browser? then KEY else Policy end
          unless (InstantRecord.browser?) then KEY else Policy end
          [::KEY, ::Doc::KEY]
          KEY::LIMIT = 1
          Policy.call::DYNAMIC
          Policy::LIMIT ||= KEY
          Policy::SUB
        end
      RUBY
      File.write(File.join(dir, "order.rb"), <<~RUBY)
        server_only { RANK = 1 }
        class Order
          server_only { RANK = 2 }
          RANK
        end
      RUBY

      order, diagnostics = StaticLinter.lint(dir, staged: true).diagnostics.partition { |d| d.file == "order.rb" }
      assert_equal ["Order::RANK"], order.map { |d| d.message[/`(.+?)`/, 1] }
      assert_equal [
        [6, "Policy"], [7, "KEY"], [8, "Policy"], [9, "KEY"], [10, "KEY"], [11, "Policy"], [12, "Policy"], [12, "KEY"], [13, "Policy"]
      ], diagnostics.map { |d| [d.line, d.message[/`Doc::(\w+)` \(defined inside server_only at doc\.rb:/, 1]] }
    end
  end

  test "real demo passes static lint cleanly" do
    result = InstantRecord::Compiler.lint(File.join(GEM_ROOT, "demo"), staged: false)
    assert result.ok?, result.to_s
    assert_operator result.files_checked, :>, 10
  end

  test "Compiler.doctor includes static lint results and fails on lint errors" do
    Dir.mktmpdir do |dir|
      tools = File.join(dir, "tools")
      spinel = File.join(tools, "spinel")
      wasi = File.join(tools, "wasi-sdk")
      sqlite = File.join(tools, "sqlite")
      rails_gems = File.join(tools, "rails_gems")
      node_modules = File.join(tools, "web_node_modules")
      cache = File.join(tools, "cache")
      [
        File.join(spinel, "bin"), File.join(spinel, "lib/wasm32-wasi"),
        File.join(wasi, "bin"), sqlite, rails_gems, node_modules, cache
      ].each { |p| FileUtils.mkdir_p(p) }

      %w[bin/spinel bin/spin].each do |rel|
        p = File.join(spinel, rel)
        File.write(p, "#!/bin/sh\n")
        File.chmod(0o755, p)
      end
      %w[bin/clang bin/llvm-ar bin/llvm-strip].each do |rel|
        p = File.join(wasi, rel)
        File.write(p, "#!/bin/sh\n")
        File.chmod(0o755, p)
      end
      rh = File.join(tools, "roundhouse")
      File.write(rh, "#!/bin/sh\n")
      File.chmod(0o755, rh)
      File.write(File.join(spinel, "lib/wasm32-wasi/libspinel_rt.a"), "rt")
      File.write(File.join(sqlite, "sqlite3.c"), "/* sqlite */\n")

      tc_file = File.join(tools, "toolchain.env")
      File.write(tc_file, <<~ENV)
        SPINEL_HOME=#{spinel}
        ROUNDHOUSE_BIN=#{rh}
        WASI_SDK=#{wasi}
        SQLITE_SRC=#{sqlite}
        RAILS_GEMS=#{rails_gems}
        WEB_NODE_MODULES=#{node_modules}
        CACHE=#{cache}
      ENV

      app_root = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(app_root, "app/models"))
      File.write(File.join(app_root, "app/models/good.rb"), "class Good < ApplicationRecord; MAX = 100; end\n")

      ok_report = InstantRecord::Compiler.doctor(toolchain: tc_file, target: :wasm, app_root: app_root)
      assert ok_report.ok?, ok_report.to_s
      assert_match(/\[OK\s+\] static lint/, ok_report.to_s)

      File.write(File.join(app_root, "app/models/bad.rb"), "class Bad < ApplicationRecord; MAX = 2 * 1024 * 1024 * 1024; end\n")
      bad_report = InstantRecord::Compiler.doctor(toolchain: tc_file, target: :wasm, app_root: app_root)
      refute bad_report.ok?
      assert_match(/\[FAIL\s+\] static lint/, bad_report.to_s)
      assert_match(/integer_overflow/, bad_report.to_s)
      assert_match(/app\/models\/bad\.rb:1/, bad_report.to_s)
    end
  end

  test "compiler pre-flight fails before Roundhouse runs when staged code fails static lint" do
    Dir.mktmpdir do |dir|
      app_root = File.join(dir, "bad_app")
      FileUtils.mkdir_p(File.join(app_root, "app/models"))
      FileUtils.mkdir_p(File.join(app_root, "app/screens"))
      FileUtils.mkdir_p(File.join(app_root, "db/migrate"))
      File.write(File.join(app_root, "db/schema.rb"), "ActiveRecord::Schema[8.1].define(version: 2026_11_20_000001) {}\n")
      File.write(File.join(app_root, "app/models/clip.rb"), <<~RUBY)
        class Clip < ApplicationRecord
          include InstantRecord::Syncable
          server_only do
            SERVER_SECRET = "nope"
          end
          def bad_size = 2 * 1024 * 1024 * 1024
          def bad_const = SERVER_SECRET
        end
      RUBY
      File.write(File.join(app_root, "app/screens/clips_screen.rb"), <<~RUBY)
        class ClipsScreen < InstantRecord::Native::Screen
          def body
            row id: "1", link: "clip", params: {} do
              text "hi"
            end
          end
        end
      RUBY

      marker_log = File.join(dir, "roundhouse.called")
      rh = File.join(dir, "roundhouse")
      File.write(rh, "#!/bin/sh\necho called > #{marker_log}\n")
      File.chmod(0o755, rh)

      tc_file = File.join(dir, "toolchain.env")
      File.write(tc_file, "ROUNDHOUSE_BIN=#{rh}\nCACHE=#{File.join(dir, 'cache')}\n")

      build = InstantRecord::Compiler::WasmBuild.new(
        workspace: File.join(dir, "ws"),
        gem_root: GEM_ROOT,
        toolchain: tc_file,
        app_source: app_root,
        models: ["Clip"],
        endpoint: "/instant_record"
      )

      error = assert_raises(InstantRecord::Compiler::BuildError) { build.emit_tree(native: true) }
      assert_match(/integer_overflow/, error.message)
      assert_match(/server_only_constant/, error.message)
      assert_match(/untyped_screen_hash/, error.message)
      refute File.exist?(marker_log), "StaticLinter pre-flight must abort before Roundhouse runs"
    end
  end
end
