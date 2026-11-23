require "test_helper"
require "instant_record/compiler"
require "tmpdir"

class AstLowererTest < ActiveSupport::TestCase
  AstLowerer = InstantRecord::Compiler::AstLowerer
  HostAdapters = InstantRecord::Compiler::HostAdapters
  GemVendor = InstantRecord::Compiler::GemVendor

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
end
