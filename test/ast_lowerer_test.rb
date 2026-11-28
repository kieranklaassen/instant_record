require "test_helper"
require "instant_record/compiler"
require "tmpdir"

class AstLowererTest < ActiveSupport::TestCase
  AstLowerer = InstantRecord::Compiler::AstLowerer
  HostAdapters = InstantRecord::Compiler::HostAdapters
  GemVendor = InstantRecord::Compiler::GemVendor

  # A source, then what the client and the server runtime make of it.
  LOWERINGS = <<~'CASES'
    x = InstantRecord.browser? ? a : b
    --
    x = a
    --
    x = b
    ====
    x = (InstantRecord.browser? ? (a; b) : b)
    --
    x = ((a; b))
    --
    x = (b)
    ====
    a = InstantRecord.browser? && b
    a = InstantRecord.browser? || b
    --
    a = b
    a = true
    --
    a = false
    a = b
    ====
    a = b && InstantRecord.browser?
    a = b || InstantRecord.browser?
    --
    a = b && true
    a = b || true
    --
    a = b && false
    a = b || false
    ====
    a = !InstantRecord.browser? && (InstantRecord.browser? ? c : d)
    --
    a = false
    --
    a = (d)
    ====
    a = (::InstantRecord.browser?)
    b = not(InstantRecord.browser?)
    c = !(x; InstantRecord.browser?)
    --
    a = (true)
    b = false
    c = !(x; true)
    --
    a = (false)
    b = true
    c = !(x; false)
    ====
    a = InstantRecord.browser?(1)
    b = Other.browser?
    c = InstantRecord.browser? { 1 }
    --
    a = InstantRecord.browser?(1)
    b = Other.browser?
    c = InstantRecord.browser? { 1 }
    --
    a = InstantRecord.browser?(1)
    b = Other.browser?
    c = InstantRecord.browser? { 1 }
    ====
    a if InstantRecord.browser? && InstantRecord.browser?
    b if InstantRecord.browser? || x
    c if InstantRecord.browser? && x
    d unless InstantRecord.browser? && x
    e if x && InstantRecord.browser?
    --
    a
    b
    c if x
    d unless x
    e if x && true
    --
    b if x
    d
    e if x && false
    ====
    a if InstantRecord.browser? # note
    b unless InstantRecord.browser?
    --
    a # note
    --
    b
    ====
    x = (a if InstantRecord.browser?)
    y = (b unless InstantRecord.browser?)
    --
    x = (a)
    y = (nil)
    --
    x = (nil)
    y = (b)
    ====
    a; b if InstantRecord.browser?; c unless InstantRecord.browser?
    --
    a; b; nil
    --
    a; nil; c
    ====
    def m
      a
      b if InstantRecord.browser?
    end
    def n
      b unless InstantRecord.browser?
    end
    --
    def m
      a
      b
    end
    def n
    end
    --
    def m
      a
      nil
    end
    def n
      b
    end
    ====
    x { |y|
      a
      b if InstantRecord.browser?
    }
    -> {
      a
      b unless InstantRecord.browser?
    }
    (
      a
      b if InstantRecord.browser?
    )
    --
    x { |y|
      a
      b
    }
    -> {
      a
      nil
    }
    (
      a
      b
    )
    --
    x { |y|
      a
      nil
    }
    -> {
      a
      b
    }
    (
      a
      nil
    )
    ====
    def m
      a
      b if InstantRecord.browser?
    rescue E
      c
      d if InstantRecord.browser?
    end
    --
    def m
      a
      b
    rescue E
      c
      d
    end
    --
    def m
      a
    rescue E
      c
    end
    ====
    class C
      if InstantRecord.browser?
          a

          b if InstantRecord.browser?
      else
        c
      end
      z
    end
    --
    class C
      a

      b
      z
    end
    --
    class C
      c
      z
    end
    ====
    class C
      unless InstantRecord.browser?
        a
      else
        c
        d unless InstantRecord.browser?
      end
      z
    end
    --
    class C
      c
      z
    end
    --
    class C
      a
      z
    end
    ====
    if InstantRecord.browser?
      a
    end
    unless InstantRecord.browser?
      a
    end
    z
    --
    a
    z
    --
    a
    z
    ====
    if InstantRecord.browser?
    else
      a
    end
    unless InstantRecord.browser?
      b
    else
    end
    z
    --
    z
    --
    a
    b
    z
    ====
    if InstantRecord.browser? then a else b end
    unless InstantRecord.browser? then c else d end
    --
    a
    d
    --
    b
    c
    ====
    x = if InstantRecord.browser?
      a
    else
      b
    end
    y = unless InstantRecord.browser?
      a
    end
    --
    x = a
    y = nil
    --
    x = b
    y = a
    ====
    if InstantRecord.browser? then
      a
    else
      b
    end
    --
    a
    --
    b
    ====
    if InstantRecord.browser? then a
    else b
    end
    --
    a
    --
    b
    ====
    if InstantRecord.browser?
      a
    elsif x
      b if InstantRecord.browser?
    else
      c
    end
    --
    a
    --
    if x
    else
      c
    end
    ====
    if InstantRecord.browser?
      a
    elsif InstantRecord.browser?
      b
    end
    --
    a
    --

    ====
    if x
      a
    elsif InstantRecord.browser?
      b if InstantRecord.browser?
    elsif y
      c
    else
      d
    end
    --
    if x
      a
    else
      b
    end
    --
    if x
      a
    elsif y
      c
    else
      d
    end
    ====
    if x
      a
    elsif InstantRecord.browser? then b
    end
    --
    if x
      a
    else b
    end
    --
    if x
      a
    end
    ====
    if x
      a
    elsif !InstantRecord.browser?
      b
    end
    --
    if x
      a
    end
    --
    if x
      a
    else
      b
    end
    ====
    if x
      a
    elsif InstantRecord.browser?
      b
    end
    --
    if x
      a
    else
      b
    end
    --
    if x
      a
    end
    ====
    if x
      a
    elsif y
      InstantRecord.browser?
    else
      b unless InstantRecord.browser?
    end
    --
    if x
      a
    elsif y
      true
    else
    end
    --
    if x
      a
    elsif y
      false
    else
      b
    end
    ====
    class C
      browser_only do
          a
          server_only { b }
      end # end
      server_only do
        c
        client_only { d }
      end
    end
    --
    class C
      a
    end
    --
    class C
      c
    end
    ====
    browser_only { a if InstantRecord.browser? }
    server_only { b }
    self.client_only { c }
    other.server_only { d }
    server_only(1) { e }
    server_only
    server_only(&f)
    --
    a
    c
    other.server_only { d }
    server_only(1) { e }
    server_only
    server_only(&f)
    --
    b
    other.server_only { d }
    server_only(1) { e }
    server_only
    server_only(&f)
    ====
    browser_only { }
    server_only do
    end
    client_only do
      # only a comment
    end
    z
    --
    z
    --
    z
    ====
    client_only do
      server_only { a }
    end
    server_only do
      client_only { b }
    end
    z
    --
    z
    --
    z
    ====
    x = browser_only do
      a
    end
    y = server_only { b }
    z(client_only { c })
    --
    x = a
    y = nil
    z(c)
    --
    x = nil
    y = b
    z(nil)
    ====
    def m
      a
      server_only { b }
    end
    --
    def m
      a
      nil
    end
    --
    def m
      a
      b
    end
    ====
    include InstantRecord::Syncable
    include ::InstantRecord::Syncable
    include InstantRecord::Syncable, Other
    Base.include InstantRecord::Syncable
    include Syncable
    include
    --
    include Syncable
    include Syncable
    include InstantRecord::Syncable, Other
    Base.include InstantRecord::Syncable
    include Syncable
    include
    --
    include Syncable
    include Syncable
    include InstantRecord::Syncable, Other
    Base.include InstantRecord::Syncable
    include Syncable
    include
    ====
    if InstantRecord.browser?; a; end; b
    --
    a; b
    --
    nil; b
    ====
    def (
    --
    def (
    --
    def (
    ====
    def m
      a if InstantRecord.browser?
      b unless InstantRecord.browser?
      c
    end
    --
    def m
      a
      c
    end
    --
    def m
      b
      c
    end
    ====
    f(InstantRecord.browser?) if InstantRecord.browser?
    g(InstantRecord.browser?) unless InstantRecord.browser?
    --
    f(true)
    --
    g(false)
    ====
    class C
      if x
        a
      elsif InstantRecord.browser?
        b
      end
    end
    --
    class C
      if x
        a
      else
        b
      end
    end
    --
    class C
      if x
        a
      end
    end
    ====
    if x then a; elsif InstantRecord.browser? && y
      b
    end
    --
    if x then a; elsif y
      b
    end
    --
    if x then a; end
    ====
    a if (InstantRecord.browser?; x)
    b if x || InstantRecord.browser?
    --
    a if (true; x)
    b if x || true
    --
    a if (false; x)
    b if x || false
    ====
    if InstantRecord.browser?
      server_only { a }
    else
      client_only { b }
    end
    z
    --
    z
    --
    z
    ====
    def m
      a
      if InstantRecord.browser?
        server_only { b }
      else
        client_only { c }
      end
    end
    --
    def m
      a
      nil
    end
    --
    def m
      a
      nil
    end
    ====
    def m
      a
      if InstantRecord.browser?
        b
      end
    end
    --
    def m
      a
      b
    end
    --
    def m
      a
      nil
    end
    ====
    def m
      a
      unless InstantRecord.browser?
        b
      end
    end
    --
    def m
      a
      nil
    end
    --
    def m
      a
      b
    end
    ====
    def m
      a
      if InstantRecord.browser?
      else
        b
      end
    end
    --
    def m
      a
      nil
    end
    --
    def m
      a
      b
    end
    ====
    def m
      a
      browser_only { }
    end
    --
    def m
      a
      nil
    end
    --
    def m
      a
      nil
    end
    ====
    def m
      a
      client_only do
        server_only { b }
      end
    end
    --
    def m
      a
      nil
    end
    --
    def m
      a
      nil
    end
    ====
    x = InstantRecord.browser? ? f(InstantRecord.browser?) : g(InstantRecord.browser?)
    --
    x = f(true)
    --
    x = g(false)
  CASES

  test "lowers each form to exactly this, for both runtimes" do
    LOWERINGS.split("====\n").each do |lowering|
      source, client, server = lowering.split("--\n", -1)
      { client: client, server: server }.each do |runtime, expected|
        assert_equal expected, AstLowerer.lower(source, runtime: runtime, rewrite_syncable_include: true), "#{runtime}:\n#{source}"
      end
    end
  end

  test "refuses to write a lowering that is not Ruby" do
    error = assert_raises(InstantRecord::Compiler::BuildError) { AstLowerer.lower("if x then a; elsif !InstantRecord.browser? then b; end\n") }
    assert_match(/\AAST lowering produced invalid Ruby: /, error.message)
  end

  test "strips server_only and unwraps browser_only and client_only for both do/end and brace blocks" do
    source = <<~RUBY
      class SampleController < ApplicationController
        extend InstantRecord::RuntimeScoped

        # Comment mentioning server_only do ... end stays untouched.
        NOTE = "server_only do\\n  keep_this_string\\nend"

        server_only do
          before_action :require_server_secret
        end

        server_only { validates :only_on_server }

        browser_only do
          # Comment inside client block is preserved
          skip_forgery_protection
        end

        client_only { def fast_path = "ok" }
      end
    RUBY

    lowered = AstLowerer.lower(source)

    assert_includes lowered, "# Comment mentioning server_only do ... end stays untouched."
    assert_includes lowered, 'NOTE = "server_only do\n  keep_this_string\nend"'
    refute_includes lowered, "require_server_secret"
    refute_includes lowered, "only_on_server"
    refute_includes lowered, "browser_only"
    refute_includes lowered, "client_only"
    assert_includes lowered, "  # Comment inside client block is preserved\n  skip_forgery_protection\n"
    assert_includes lowered, "  def fast_path = \"ok\"\n"
    assert Prism.parse(lowered).success?
  end

  test "handles empty and nested scoped blocks cleanly" do
    source = <<~RUBY
      class Nested
        server_only do
        end

        browser_only do
          def greet
            InstantRecord.browser? ? "browser" : "server"
          end

          server_only do
            SECRET = 1
          end
        end
      end
    RUBY

    lowered = AstLowerer.lower(source)

    refute_includes lowered, "server_only"
    refute_includes lowered, "browser_only"
    refute_includes lowered, "SECRET"
    assert_includes lowered, '    "browser"'
    assert Prism.parse(lowered).success?
  end

  test "folds InstantRecord.browser? across ternaries, booleans, modifiers, and if/elsif/unless" do
    source = <<~RUBY
      class Folder
        def counts
          pending = InstantRecord.browser? ? InstantRecord.pending_count : 0
          has_more = InstantRecord.browser? || expensive_server_check
          local = InstantRecord.browser? && !applying_remote?
          server = !InstantRecord.browser? && !applying_client?
          scope = base_scope
          scope = scope.limit(200) unless InstantRecord.browser?
          scope = scope.where(local: true) if InstantRecord.browser?

          unless InstantRecord.browser?
            return :server_early_return
          end

          if InstantRecord.browser?
            :client_branch
          else
            :server_branch
          end
        end

        def elsif_chain(flag)
          if flag
            :flagged
          elsif InstantRecord.browser?
            :always_here
          else
            :unreachable
          end
        end

        def dead_elsif(flag)
          if flag
            :flagged
          elsif !InstantRecord.browser?
            :dead
          else
            :fallback
          end
        end

        def trailing_dead_elsif(flag)
          if flag
            :flagged
          elsif !InstantRecord.browser?
            :dropped
          end
        end

        def chained_elsif(flag)
          if flag
            :flagged
          elsif !InstantRecord.browser?
            :skipped
          elsif InstantRecord.browser?
            :chosen
          else
            :unreachable2
          end
        end
      end
    RUBY

    lowered = AstLowerer.lower(source)

    assert_includes lowered, "pending = InstantRecord.pending_count"
    assert_includes lowered, "has_more = true"
    assert_includes lowered, "local = !applying_remote?"
    assert_includes lowered, "server = false"
    refute_includes lowered, "scope.limit(200)"
    assert_includes lowered, "scope = scope.where(local: true)"
    refute_includes lowered, ":server_early_return"
    assert_includes lowered, ":client_branch"
    refute_includes lowered, ":server_branch"
    assert_includes lowered, "else\n      :always_here"
    refute_includes lowered, ":unreachable"
    refute_includes lowered, ":dead"
    assert_includes lowered, ":fallback"
    refute_includes lowered, ":dropped"
    refute_includes lowered, ":skipped"
    assert_includes lowered, ":chosen"
    refute_includes lowered, ":unreachable2"
    assert Prism.parse(lowered).success?
  end

  test "preserves nil return value when a dead modifier branch is the last statement of a method" do
    source = <<~RUBY
      class ReturnSemantics
        def maybe_server
          _setup = 42
          run_server(_setup) unless InstantRecord.browser?
        end
      end
    RUBY

    lowered = AstLowerer.lower(source)
    assert Prism.parse(lowered).success?

    klass = Class.new
    klass.class_eval(lowered)
    assert_nil klass.const_get(:ReturnSemantics).new.maybe_server
  end

  test "handles multi-byte UTF-8 comments and strings without corrupting byte offsets" do
    source = <<~RUBY
      # Em-dash — and café ☕ before the scoped block
      class UnicodeModel
        include InstantRecord::Syncable

        server_only do
          # More UTF-8 — résumé
          validates :name, presence: true
        end

        def label
          InstantRecord.browser? ? "café — local" : "café — server"
        end
      end
    RUBY

    lowered = AstLowerer.lower(source, rewrite_syncable_include: true)

    assert_includes lowered, "# Em-dash — and café ☕ before the scoped block"
    assert_includes lowered, "include Syncable"
    refute_includes lowered, "InstantRecord::Syncable"
    refute_includes lowered, "validates :name"
    assert_includes lowered, '"café — local"'
    assert Prism.parse(lowered).success?
  end

  test "rewrites include InstantRecord::Syncable only as an include call, not inside strings or comments" do
    source = <<~RUBY
      # Example: include InstantRecord::Syncable
      class Note < ApplicationRecord
        include InstantRecord::Syncable
        DOC = "include InstantRecord::Syncable"
      end
    RUBY

    lowered = AstLowerer.lower(source, rewrite_syncable_include: true)

    assert_includes lowered, "# Example: include InstantRecord::Syncable"
    assert_includes lowered, 'DOC = "include InstantRecord::Syncable"'
    assert_includes lowered, "  include Syncable\n"
    assert_equal source, AstLowerer.lower(source)
    assert Prism.parse(lowered).success?
  end

  test "unnest_syncable extracts module Syncable cleanly using Prism AST" do
    syncable_path = File.expand_path("../lib/instant_record/syncable.rb", __dir__)
    unnested = AstLowerer.unnest_syncable(File.read(syncable_path, encoding: Encoding::UTF_8))

    assert_includes unnested, 'require "securerandom"'
    assert_match(/^module Syncable$/, unnested)
    refute_match(/^module InstantRecord$/, unnested)
    assert Prism.parse(unnested).success?
  end

  test "GemVendor supports swappable host adapters for wasm, native, and custom adapters" do
    gem_root = File.expand_path("..", __dir__)

    Dir.mktmpdir do |dir|
      wasm_app = File.join(dir, "wasm_app")
      native_app = File.join(dir, "native_app")
      custom_app = File.join(dir, "custom_app")

      GemVendor.vendor(gem_src: gem_root, app_dir: wasm_app, target: :wasm)
      wasm_host = File.read(File.join(wasm_app, "lib/instant_record/host.rb"))
      assert_includes wasm_host, 'File.read("/host/#{name}")'
      assert_includes wasm_host, "def browser? = true"

      GemVendor.vendor(gem_src: gem_root, app_dir: native_app, target: :native)
      native_host = File.read(File.join(native_app, "lib/instant_record/host.rb"))
      assert_includes native_host, "NativeHost.ir_host_take(name)"
      assert_includes native_host, "NativeHost.ir_host_give(name, body)"

      custom_adapter = Module.new do
        extend HostAdapters::Base

        def self.target = :custom
        def self.host_source
          "module InstantRecord\n  module Host\n    def self.browser? = true\n    def self.custom? = true\n  end\nend\n"
        end
      end

      GemVendor.vendor(gem_src: gem_root, app_dir: custom_app, adapter: custom_adapter)
      assert_includes File.read(File.join(custom_app, "lib/instant_record/host.rb")), "def self.custom? = true"
    end
  end

  test "lowers edge syntax forms including empty parens, line continuations, heredocs, and spaced calls" do
    assert_equal "a\n", AstLowerer.lower("browser_only() { a }\n")
    assert_equal "a\n", AstLowerer.lower("browser_only(\n  # comment\n) { a }\n")
    assert_equal "a\n", AstLowerer.lower("browser_only \\\n  do\n  a\nend\n")
    assert_equal "true\n", AstLowerer.lower("InstantRecord . browser?\n")
    assert_equal "true\n", AstLowerer.lower("InstantRecord\n  # comment\n  .browser?\n")
    assert_equal "true\n", AstLowerer.lower("InstantRecord&.browser?\n")
    assert_equal "true\n", AstLowerer.lower("InstantRecord::browser?\n")
    assert_equal "include Syncable\n", AstLowerer.lower("include InstantRecord::\n  Syncable\n", rewrite_syncable_include: true)
    assert_equal "include( Syncable )\n", AstLowerer.lower("include( ::InstantRecord::Syncable )\n", rewrite_syncable_include: true)
    assert_equal "include(\n  # comment\n  Syncable\n)\n", AstLowerer.lower("include(\n  # comment\n  ::InstantRecord::\n  Syncable\n)\n", rewrite_syncable_include: true)

    heredoc_def = ("# " + "x" * 80 + "\n") * 20 + "def foo = <<~EOF\n  \#{InstantRecord.browser? ? 1 : 2}\nEOF\n"
    assert_equal ("# " + "x" * 80 + "\n") * 20 + "def foo = <<~EOF\n  \#{1}\nEOF\n", AstLowerer.lower(heredoc_def)

    unicode_heredoc = ("# " + "x" * 80 + "\n") * 20 + "def foo = <<~日本語\n  \#{InstantRecord.browser? ? 1 : 2}\n日本語\n"
    assert_equal ("# " + "x" * 80 + "\n") * 20 + "def foo = <<~日本語\n  \#{1}\n日本語\n", AstLowerer.lower(unicode_heredoc)

    digit_heredoc = ("# " + "x" * 80 + "\n") * 20 + "puts(<<0)\n  \#{server_only { 1 }}\n0\n"
    assert_equal ("# " + "x" * 80 + "\n") * 20 + "puts(<<0)\n  \#{nil}\n0\n", AstLowerer.lower(digit_heredoc)

    digit_heredoc_def = ("# " + "x" * 80 + "\n") * 20 + "def foo = <<0\n  \#{InstantRecord.browser?}\n0\n"
    assert_equal ("# " + "x" * 80 + "\n") * 20 + "def foo = <<0\n  \#{true}\n0\n", AstLowerer.lower(digit_heredoc_def)

    begin_comment = "InstantRecord.\n=begin\nnote\n=end\nbrowser?\n"
    assert_equal "true\n", AstLowerer.lower(begin_comment)

    scoped_begin_comment = "server_only \\\n=begin\nnote\n=end\n do\n  x\nend\n"
    assert_equal "", AstLowerer.lower(scoped_begin_comment)

    browser_begin_comment = "browser_only \\\n=begin\nnote\n=end\n { x }\n"
    assert_equal "x\n", AstLowerer.lower(browser_begin_comment)

    combined_begin_comment = "InstantRecord.browser?\nserver_only \\\n=begin\nnote\n=end\n do\n  x\nend\n"
    assert_equal "true\n", AstLowerer.lower(combined_begin_comment)
  end

  test "reindent_block handles fast-path and general-path boundary inputs" do
    assert_equal "  a\n  b\n", AstLowerer.reindent_block("    a\n    b\n", target_indent: "  ")
    assert_equal "\\1a\n\\1b\n", AstLowerer.reindent_block("    a\n    b\n", target_indent: "\\1")
    assert_equal "\\&a\n\\&b\n", AstLowerer.reindent_block("    a\n    b\n", target_indent: "\\&")
    assert_equal "  a\n\n  b\n", AstLowerer.reindent_block("    a\n   \n    b\n", target_indent: "  ")
    assert_equal "  a \n  b\n", AstLowerer.reindent_block("    a \n    b\n", target_indent: "  ")
    assert_equal "  a\n  b\n", AstLowerer.reindent_block("\t\ta\n\t\tb\n", target_indent: "  ")

    deep = (" " * 40) + "a\n" + (" " * 42) + "b\n"
    assert_equal "  a\n    b\n", AstLowerer.reindent_block(deep, target_indent: "  ")
  end

  test "handles binary, invalid UTF-8, CRLF, BOM, and non-ASCII-compatible encodings safely" do
    binary = "# \xFF\xFE\nInstantRecord.browser?\n".b
    lowered_binary = AstLowerer.lower(binary)
    assert_equal Encoding::BINARY, lowered_binary.encoding
    assert_equal "# \xFF\xFE\ntrue\n".b, lowered_binary

    invalid_utf8 = "# \xFF\xFE\nInstantRecord.browser?\n".dup.force_encoding(Encoding::UTF_8)
    lowered_invalid = AstLowerer.lower(invalid_utf8)
    assert_equal Encoding::UTF_8, lowered_invalid.encoding
    assert_equal "# \xFF\xFE\ntrue\n".b, lowered_invalid.b

    invalid_utf8_noop = "# \xFF\xFE\nx = 1\n".dup.force_encoding(Encoding::UTF_8)
    assert_same invalid_utf8_noop, AstLowerer.lower(invalid_utf8_noop)

    crlf = "class A\r\n  server_only do\r\n    x = 1\r\n  end\r\n  browser_only do\r\n    y = 2\r\n  end\r\nend\r\n"
    assert_equal "class A\r\n  y = 2\r\nend\r\n", AstLowerer.lower(crlf)

    bom = "\xEF\xBB\xBFInstantRecord.browser? ? :a : :b\n"
    assert_equal "\xEF\xBB\xBF:a\n", AstLowerer.lower(bom)

    utf16 = "InstantRecord.browser?\n".encode(Encoding::UTF_16LE)
    assert_same utf16, AstLowerer.lower(utf16)
  end
end
