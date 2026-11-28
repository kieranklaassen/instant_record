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

  test "a client definition in a file that never says server_only makes the constant shared" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), "class Job\n  server_only do\n    LIMIT = 1\n    RETRIES = 2\n  end\nend\n")
      File.write(File.join(dir, "b.rb"), "class Job\n  LIMIT = 3\nend\n")
      File.write(File.join(dir, "c.rb"), "Job::LIMIT\nJob::RETRIES\n")

      assert_equal({ "Job::RETRIES" => "a.rb:4" }, StaticLinter.collect_server_only_constants(dir))

      given = { "Job::LIMIT" => "a.rb:3", "Job::RETRIES" => "a.rb:4" }
      [nil, given].each do |server_only_constants|
        result = StaticLinter.lint(dir, staged: true, server_only_constants: server_only_constants)
        assert_equal ["c.rb:2"], result.diagnostics.map { |d| "#{d.file}:#{d.line}" }
      end
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

  test "a rescue or ensure on a Screen class or method changes no finding" do
    template = <<~RUBY
      class Guarded < Screen
        def blank
          {}
          METHOD_GUARD
        end

        def two
          b
          {}
          METHOD_GUARD
        end

        def empty
          METHOD_GUARD
        end

        def body
          row params: blank
          row params: two
          row params: empty
          row params: {}
          METHOD_GUARD
        end
        CLASS_GUARD
      end
      class Bare < Screen
        CLASS_GUARD
      end
    RUBY
    guards = ["", "rescue then nil", "ensure nil", "rescue then nil; else nil; ensure nil"]

    Dir.mktmpdir do |dir|
      guards.product(guards).each do |method_guard, class_guard|
        File.write(File.join(dir, "guarded.rb"), template.gsub("METHOD_GUARD", method_guard).gsub("CLASS_GUARD", class_guard))

        diagnostics = StaticLinter.lint(dir, staged: true).diagnostics
        assert_equal [[18, 17], [21, 17]], diagnostics.map { |d| [d.line, d.column] }, "method: #{method_guard.inspect}, class: #{class_guard.inspect}"
      end
    end
  end

  test "lints code inside rescue and ensure clauses" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "clauses.rb"), <<~RUBY)
        class Clauses < Screen
          def body
            row id: "1"
          rescue
            row params: {}
          ensure
            2**31
          end
        rescue
          def late = {}
          row params: late
        ensure
          InstantRecord::Engine
        end
      RUBY

      diagnostics = StaticLinter.lint(dir, staged: true).diagnostics
      assert_equal [[5, :untyped_screen_hash], [7, :integer_overflow], [13, :server_only_constant]], diagnostics.map { |d| [d.line, d.rule] }
    end
  end

  test "one linter instance carries nothing from file to file or from run to run" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/screens"))
      first = File.join(dir, "app/screens/first.rb")
      second = File.join(dir, "second.rb")
      File.write(first, <<~RUBY)
        BIG = 1.gigabyte
        empty = {}
        row params: empty
        server_only { SECRET = 1 }
      RUBY
      File.write(second, <<~RUBY)
        BIG * 2
        row params: {}
        class Second < Screen
          empty ||= param
          row params: empty
          SECRET
        end
      RUBY
      linter = StaticLinter.new(root: dir, staged: true)
      found = -> { linter.run.diagnostics.map { |d| [d.file, d.line, d.rule] } }

      expected = [["app/screens/first.rb", 3, :untyped_screen_hash], ["second.rb", 6, :server_only_constant]]
      assert_equal expected, found.call
      assert_equal expected, found.call

      File.write(first, "")
      assert_empty found.call
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

  test "catches integer overflow edge forms including non-decimal bases, dot calls, chains, =begin, and heredocs" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "edge_ints.rb"), <<~RUBY)
        module EdgeInts
          HEX_BAD = 0x8000_0000
          OCT_BAD = 020000000000
          OCT_O_BAD = 0o20000000000
          BIN_BAD = 0b1000_0000_0000_0000_0000_0000_0000_0000
          DEC_D_BAD = 0d2147483648
          DIV_MIN = (-2_147_483_648) / -1
          NEG_MIN = -(-2_147_483_648)
          DOT_ADD = 2_147_483_647.+(1)
          SAFE_BYTE = 3&.gigabytes
          A = 1 << 20
          B = A << 12
          INTERP = <<~TXT
            value: \#{2**31}
          TXT
        end
      RUBY

      # Isolated file with trailing dot + comment before operator (no other << or big literal).
      File.write(File.join(dir, "dot_shift.rb"), <<~RUBY)
        X = 1. # comment before operator
          <<(31)
      RUBY

      # Isolated file with =begin..=end splitting an expression whose literals are < 10 digits.
      File.write(File.join(dir, "begin_expr.rb"), <<~RUBY)
        X = 500_000_000 *
        =begin
        embedded doc comment inside expression
        =end
        5
      RUBY

      # Addition-only constant doubling chain from small literals (no *, **, <<, or large literals).
      chain_lines = ["A0 = 1"]
      (1..31).each { |i| chain_lines << "A#{i} = A#{i - 1} + A#{i - 1}" }
      File.write(File.join(dir, "add_chain.rb"), "#{chain_lines.join("\n")}\n")

      # Bitwise OR/XOR/AND + hybrid doubling chains using `-~x == x + 1` (no *, **, <<, or large literals).
      or_chain = ["A0 = 1"]
      (1..30).each { |i| or_chain << "A#{i} = A#{i - 1} | -~A#{i - 1}" }
      or_chain << "OVERFLOW = -~A30"
      File.write(File.join(dir, "or_chain.rb"), "#{or_chain.join("\n")}\n")

      xor_chain = ["A0 = 1"]
      (1..30).each { |i| xor_chain << "A#{i} = A#{i - 1} ^ -~A#{i - 1}" }
      xor_chain << "OVERFLOW = -~A30"
      File.write(File.join(dir, "xor_chain.rb"), "#{xor_chain.join("\n")}\n")

      and_chain = ["X0 = -2"]
      (1..30).each { |i| and_chain << "X#{i} = X#{i - 1} & ~(-X#{i - 1})" }
      and_chain << "OVERFLOW = -X30"
      File.write(File.join(dir, "and_chain.rb"), "#{and_chain.join("\n")}\n")

      hybrid_chain = ["A0 = 1"]
      (1..18).each { |i| hybrid_chain << "A#{i} = A#{i - 1} | -~A#{i - 1}" }
      (19..30).each { |i| hybrid_chain << "A#{i} = A#{i - 1} + A#{i - 1}" }
      hybrid_chain << "OVERFLOW = A30 + A30"
      File.write(File.join(dir, "hybrid_chain.rb"), "#{hybrid_chain.join("\n")}\n")

      result = StaticLinter.lint(dir, staged: true)
      refute result.ok?
      assert_equal 8, result.files_checked

      by_file = result.diagnostics.group_by(&:file)
      assert_equal [2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14], by_file["edge_ints.rb"].map(&:line), by_file["edge_ints.rb"].map(&:to_s).join("\n")
      assert_equal [1], by_file["dot_shift.rb"].map(&:line), by_file["dot_shift.rb"].map(&:to_s).join("\n")
      assert_equal [1], by_file["begin_expr.rb"].map(&:line), by_file["begin_expr.rb"].map(&:to_s).join("\n")
      assert_equal [32], by_file["add_chain.rb"].map(&:line), by_file["add_chain.rb"].map(&:to_s).join("\n")
      assert_equal [32], by_file["or_chain.rb"].map(&:line), by_file["or_chain.rb"].map(&:to_s).join("\n")
      assert_equal [32], by_file["xor_chain.rb"].map(&:line), by_file["xor_chain.rb"].map(&:to_s).join("\n")
      assert_equal [32], by_file["and_chain.rb"].map(&:line), by_file["and_chain.rb"].map(&:to_s).join("\n")
      assert_equal [32], by_file["hybrid_chain.rb"].map(&:line), by_file["hybrid_chain.rb"].map(&:to_s).join("\n")
    end
  end

  test "handles syntax errors, non-UTF-8/BOM/CRLF encodings, and skips clean files while preserving files_checked" do
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "broken.rb"), "class Broken\n  X = 1 << 31\n  def foo(\n")
      File.binwrite(File.join(dir, "clean.rb"), "class Clean\n  def greet(name)\n    \"hello \#{name}\"\n  end\nend\n")
      File.binwrite(File.join(dir, "latin1.rb"), "# encoding: iso-8859-1\n# caf\xE9\nX = 1 << 31\n".b)
      File.binwrite(File.join(dir, "shift_jis.rb"), "  # encoding: shift_jis\nY = 2**31\n".b)
      File.binwrite(File.join(dir, "utf8_bom.rb"), "\xEF\xBB\xBFZ = 3.gigabytes\n".b)
      File.binwrite(File.join(dir, "crlf.rb"), "class Crlf\r\n  server_only do\r\n    SECRET = 1\r\n  end\r\n  LEAK = SECRET\r\nend\r\n")

      result = StaticLinter.lint(dir, staged: true)
      assert_equal 6, result.files_checked
      assert_equal [
        ["crlf.rb", 5, :server_only_constant],
        ["latin1.rb", 3, :integer_overflow],
        ["shift_jis.rb", 2, :integer_overflow],
        ["utf8_bom.rb", 1, :integer_overflow]
      ], result.diagnostics.map { |d| [d.file, d.line, d.rule] }
    end
  end

  test "catches server_only variations, client constant-path redefinitions, and namespace prefix matches" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "defs.rb"), <<~RUBY)
        module App
          self.server_only do
            class HiddenMod; end
            SECRET_A = 1
          end
          server_only() { SECRET_B = 2 }
          server_only \\
          do
            REDEF_PATH = 3
            REDEF_OR = 4
          end
        end
      RUBY
      File.write(File.join(dir, "redef.rb"), <<~RUBY)
        class Setup
          ::App::REDEF_PATH = 4
          def define_client
            ::App::REDEF_OR ||= 5
          end
        end
      RUBY
      File.write(File.join(dir, "refs.rb"), <<~RUBY)
        module App
          a = SECRET_A
          b = SECRET_B
          c = REDEF_PATH
          d = REDEF_OR
          e = HiddenMod::NestedConst
        end
      RUBY

      collected = StaticLinter.collect_server_only_constants(dir)
      assert_equal %w[App::HiddenMod App::SECRET_A App::SECRET_B], collected.keys.sort

      result = StaticLinter.lint(dir, staged: true)
      assert_equal [
        ["refs.rb", 2, :server_only_constant],
        ["refs.rb", 3, :server_only_constant],
        ["refs.rb", 6, :server_only_constant]
      ], result.diagnostics.map { |d| [d.file, d.line, d.rule] }

      # Defining a child namespace under a server_only namespace still flags bare
      # constant reads inside that child via namespace prefix lookup.
      File.write(File.join(dir, "child_ns.rb"), "class App::HiddenMod::Child\n  X\nend\n")
      child_res = StaticLinter.lint(dir, staged: true)
      child_diags = child_res.diagnostics.select { |d| d.file == "child_ns.rb" }
      assert_equal [[2, :server_only_constant]], child_diags.map { |d| [d.line, d.rule] }
    end
  end

  test "catches untyped screen hashes in Screen subclasses outside app/screens and ignores non-inheriting classes" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "custom_screen.rb"), <<~RUBY)
        class CustomScreen < ::Screen
          def render
            row params: (Hash.new)
          end
        end
      RUBY
      File.write(File.join(dir, "mentions_screen_only.rb"), <<~RUBY)
        # Screen helper that does not inherit from Screen
        class PlainBuilder
          def render
            row params: {}
          end
        end
      RUBY

      result = StaticLinter.lint(dir, staged: true)
      assert_equal 2, result.files_checked
      assert_equal [["custom_screen.rb", 3, :untyped_screen_hash]], result.diagnostics.map { |d| [d.file, d.line, d.rule] }
    end
  end

  test "catches prefilter boundary forms: comment backslashes, string hashes, unary dot calls, compound op=~, spaced ::, shebang Shift_JIS, and unnormalized only_files" do
    Dir.mktmpdir do |dir|
      # 1. Trailing backslash inside a `#` comment or after `.` before comment/blank line
      File.write(File.join(dir, "comment_backslash_mul.rb"), "X = 100_000.\n# a\\\n*(30_000)\n")
      File.write(File.join(dir, "comment_backslash_shift.rb"), "X = 1.\n# a\\\n<<(31)\n")
      File.write(File.join(dir, "comment_backslash_dot.rb"), "X = 100_000\n# a\\\n.*(30_000)\n")
      File.write(File.join(dir, "dot_backslash_comment.rb"), "X = 100_000.\\\n  # comment\n  *(30_000)\n")
      File.write(File.join(dir, "dot_backslash_blank.rb"), "X = 100_000.\\\n\n  *(30_000)\n")

      # 2. `#` inside a string literal before a trailing call dot and inline comment
      File.write(File.join(dir, "string_hash_dot.rb"), "foo(\"#\"); 100_000. # comment\n  *(30_000)\n")
      File.write(File.join(dir, "string_hash_scope.rb"), "foo(\"#\"); 100_000:: # comment\n  *(30_000)\n")

      # 3. Compound op=~ constant definitions and client redefinitions
      File.write(File.join(dir, "compound_so.rb"), "server_only do\n  SECRET_OR ||=~1\n  SECRET_REDEF ||=~1\nend\n")
      File.write(File.join(dir, "compound_redef.rb"), "SECRET_REDEF ||=~1\n")
      File.write(File.join(dir, "compound_ref.rb"), "SECRET_OR\nSECRET_REDEF\n")

      # 4. Whitespace/comments after leading `::` in Screen inheritance and client class/module redefs
      File.write(File.join(dir, "spaced_screen.rb"), "class SpacedScreen < :: Screen\n  def render = row(params: {})\nend\n")
      File.write(File.join(dir, "spaced_ns_so.rb"), "server_only do\n  class SpacedShared; end\nend\n")
      File.write(File.join(dir, "spaced_ns_redef.rb"), "class :: # comment\n  SpacedShared\nend\n")
      File.write(File.join(dir, "spaced_ns_ref.rb"), "SpacedShared\n")

      # 5. Shebang with --encoding=utf-8, leading CR, and multi-coding Emacs Shift_JIS magic comments
      File.binwrite(
        File.join(dir, "shebang_sjis.rb"),
        "#!/usr/bin/env ruby --encoding=utf-8\n# encoding: shift_jis\nserver_only do\n  \x82\x60 = 1\nend\n".b
      )
      File.binwrite(File.join(dir, "shebang_sjis_ref.rb"), "# encoding: shift_jis\n\x82\x60\n".b)
      File.binwrite(File.join(dir, "cr_sjis.rb"), "\r# encoding: shift_jis\nX = 100_000.\n# a\x95\x5C\n*(30_000)\n".b)
      File.binwrite(
        File.join(dir, "emacs_decoding_sjis.rb"),
        "# -*- decoding: utf-8; coding: shift_jis -*-\nserver_only do\n  \x82\x61 = 1\nend\n".b
      )
      File.binwrite(File.join(dir, "emacs_decoding_sjis_ref.rb"), "# encoding: shift_jis\n\x82\x61\n".b)
      File.binwrite(
        File.join(dir, "emacs_multi_coding_sjis.rb"),
        "# -*- coding: utf-8; coding: shift_jis -*-\n\x82\x62 = 100_000\nY = \x82\x62 * 30_000\n".b
      )
      File.binwrite(
        File.join(dir, "quoted_sjis.rb"),
        "# coding: \"shift_jis\"\n\x82\x63 = 100_000\nY = \x82\x63 * 30_000\n".b
      )
      File.binwrite(
        File.join(dir, "vtab_sjis.rb"),
        "# coding:\vshift_jis\nserver_only do\n  \x82\x64 = 1\nend\n".b
      )
      File.binwrite(File.join(dir, "vtab_sjis_ref.rb"), "# encoding: shift_jis\n\x82\x64\n".b)
      File.binwrite(
        File.join(dir, "bang_line1_sjis.rb"),
        "#! coding: shift_jis\n\x82\x65 = 100_000\nY = \x82\x65 * 30_000\n".b
      )
      File.binwrite(
        File.join(dir, "spaced_bang_line1_sjis.rb"),
        " #! coding: shift_jis\nserver_only do\n  \x82\x66 = 1\nend\n\x82\x66\n".b
      )
      File.binwrite(
        File.join(dir, "bom_bang_line1_sjis.rb"),
        "\xEF\xBB\xBF#! coding: shift_jis\n\x82\x67 = 100_000\nY = \x82\x67 * 30_000\n".b
      )

      # 6. Dot-call unary operators (.+@, .-@, .~) as LHS of binary int ops
      File.write(File.join(dir, "unary_dot_plus.rb"), "X = 100_000.+@ * 30_000\n")
      File.write(File.join(dir, "unary_dot_minus.rb"), "X = 100_000.-@ * -30_000\n")
      File.write(File.join(dir, "unary_dot_tilde.rb"), "X = 100_000.~ * -30_000\n")

      # 7. Heredoc-split multi-token expressions across all three rules
      File.write(File.join(dir, "heredoc_split_mul.rb"), "foo(<<~TXT); X = 100_000.\nhello\nTXT\n  *(30_000)\n")
      File.write(File.join(dir, "heredoc_split_bytes.rb"), "foo(<<~TXT); X = 2.\nhello\nTXT\n  gigabytes\n")
      File.write(File.join(dir, "heredoc_split_screen.rb"), "class HScreen < Screen\n  def body\n    foo(<<~TXT); row(params: {\nhello\nTXT\n})\n  end\nend\n")
      File.write(File.join(dir, "heredoc_split_so.rb"), "server_only do\n  class HShared; end\nend\n")
      File.write(File.join(dir, "heredoc_split_redef.rb"), "foo(<<~TXT); class\nhello\nTXT\n  HShared\nend\n")
      File.write(File.join(dir, "heredoc_split_ref.rb"), "HShared\n")

      result = StaticLinter.lint(dir, staged: true)
      found = result.diagnostics.map { |d| [d.file, d.line, d.rule] }
      assert_equal [
        ["bang_line1_sjis.rb", 3, :integer_overflow],
        ["bom_bang_line1_sjis.rb", 3, :integer_overflow],
        ["comment_backslash_dot.rb", 1, :integer_overflow],
        ["comment_backslash_mul.rb", 1, :integer_overflow],
        ["comment_backslash_shift.rb", 1, :integer_overflow],
        ["compound_ref.rb", 1, :server_only_constant],
        ["cr_sjis.rb", 2, :integer_overflow],
        ["dot_backslash_blank.rb", 1, :integer_overflow],
        ["dot_backslash_comment.rb", 1, :integer_overflow],
        ["emacs_decoding_sjis_ref.rb", 2, :server_only_constant],
        ["emacs_multi_coding_sjis.rb", 3, :integer_overflow],
        ["heredoc_split_bytes.rb", 1, :integer_overflow],
        ["heredoc_split_mul.rb", 1, :integer_overflow],
        ["heredoc_split_screen.rb", 3, :untyped_screen_hash],
        ["quoted_sjis.rb", 3, :integer_overflow],
        ["shebang_sjis_ref.rb", 2, :server_only_constant],
        ["spaced_bang_line1_sjis.rb", 5, :server_only_constant],
        ["spaced_screen.rb", 2, :untyped_screen_hash],
        ["string_hash_dot.rb", 1, :integer_overflow],
        ["string_hash_scope.rb", 1, :integer_overflow],
        ["unary_dot_minus.rb", 1, :integer_overflow],
        ["unary_dot_plus.rb", 1, :integer_overflow],
        ["unary_dot_tilde.rb", 1, :integer_overflow],
        ["vtab_sjis_ref.rb", 2, :server_only_constant]
      ], found, result.diagnostics.map(&:to_s).join("\n")

      # 7. Unnormalized `only_files` path still recognizes `app/screens/` and normalizes Diagnostic#file
      FileUtils.mkdir_p(File.join(dir, "app/screens"))
      File.write(File.join(dir, "app/screens/my_screen.rb"), "def body\n  row params: {}\nend\n")
      only_res = StaticLinter.lint(dir, staged: true, only_files: ["./app/screens/my_screen.rb"])
      assert_equal [["app/screens/my_screen.rb", 2, :untyped_screen_hash]], only_res.diagnostics.map { |d| [d.file, d.line, d.rule] }
    end
  end

  test "FastVisitor visits every Prism child slot on overridden container nodes" do
    fast_visitor = StaticLinter.const_get(:FastVisitor)
    probe_code = <<~RUBY
      a = 1; @b = 2; c = "x \#{1 + 2}"; d = [1, { k: (3 && 4 || 5) }]
      def f(x, y = 1, k: 2)
        return y
      rescue StandardError => e
        e
      else
        x
      ensure
        nil
      end
      f(1, k: 2) { |p| p }
    RUBY
    root = Prism.parse(probe_code).value
    ignored = [
      Prism::RequiredParameterNode,
      Prism::BlockLocalVariableNode,
      Prism::RestParameterNode,
      Prism::KeywordRestParameterNode,
      Prism::BlockParameterNode
    ]

    record_visits = lambda do |klass|
      visited = []
      recorder = Class.new(klass) do
        Prism::Visitor.instance_methods(false).grep(/\Avisit_.*_node\z/).each do |meth|
          define_method(meth) do |node|
            visited << node.object_id unless ignored.any? { |type| node.is_a?(type) }
            super(node)
          end
        end
      end.new
      root.accept(recorder)
      visited
    end

    visited_by_base = record_visits.call(Prism::Visitor)
    visited_by_fast = record_visits.call(fast_visitor)

    assert_operator visited_by_fast.length, :>, 30
    assert_equal visited_by_base.sort, visited_by_fast.sort
  end
end
