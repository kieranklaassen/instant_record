require "test_helper"
require "instant_record/compiler"
require "fileutils"
require "tmpdir"

class GemVendorTest < ActiveSupport::TestCase
  GEM_ROOT = File.expand_path("..", __dir__)
  PIPELINE_DIR = File.join(GEM_ROOT, "compiled/pipeline")
  GemVendor = InstantRecord::Compiler::GemVendor
  HostAdapters = InstantRecord::Compiler::HostAdapters
  StaticLinter = InstantRecord::Compiler::StaticLinter
  BuildError = InstantRecord::Compiler::BuildError

  test "vendors wasm and native targets with expected return count, adapter, sqlite config, and stale cleanup" do
    Dir.mktmpdir do |dir|
      %i[wasm native].each do |target|
        app = File.join(dir, target.to_s)
        FileUtils.mkdir_p(File.join(app, "lib/instant_record"))
        FileUtils.mkdir_p(File.join(app, "app/models/concerns/instant_record"))
        File.write(File.join(app, "lib/instant_record/stale.rb"), "STALE = 1\n")
        File.write(File.join(app, "app/models/concerns/instant_record/old.rb"), "OLD = 1\n")

        gv = GemVendor.new(gem_src: GEM_ROOT, app_dir: app, demo: false, target: target)
        expected_adapter = target == :wasm ? HostAdapters::Wasm : HostAdapters::Native
        assert_same expected_adapter, gv.adapter

        count = gv.run
        assert_equal GemVendor::COPY.length + 1, count
        assert_equal({}, gv.server_only_constants)

        refute File.exist?(File.join(app, "lib/instant_record/stale.rb"))
        refute File.exist?(File.join(app, "lib/instant_record/syncable.rb"))
        refute File.exist?(File.join(app, "app/models/concerns/instant_record"))

        assert File.file?(File.join(app, "app/models/concerns/syncable.rb"))
        assert File.file?(File.join(app, "app/models/instant_record/change.rb"))
        assert File.file?(File.join(app, "lib/instant_record/native.rb"))
        assert_equal GemVendor::SQLITE_DATABASE_YML, File.read(File.join(app, "config/database.yml"))

        syncable = File.read(File.join(app, "app/models/concerns/syncable.rb"))
        assert_match(/^module Syncable$/, syncable)
        refute_match(/^module InstantRecord$/, syncable)
        refute_includes syncable, "server_only do"

        host = File.read(File.join(app, "lib/instant_record/host.rb"))
        if target == :wasm
          assert_includes host, 'File.read("/host/#{name}")'
          refute File.exist?(File.join(app, "sig/instant_record/native_host.rbs"))
        else
          assert_includes host, "NativeHost.ir_host_take(name)"
          assert File.file?(File.join(app, "sig/instant_record/native_host.rbs"))
        end
      end
    end
  end

  test "collects server_only_constants across app, lib, and config while excluding non-compiled dirs and client defs" do
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app")
      %w[
        app/models
        app/controllers
        app/helpers
        app/screens
        config
        lib/custom
        lib/tasks
        lib/generators
        db/migrate
        test
        tmp
        vendor
      ].each { |rel| FileUtils.mkdir_p(File.join(app, rel)) }

      File.write(File.join(app, "app/models/widget.rb"), <<~RUBY)
        class Widget < ApplicationRecord
          include InstantRecord::Syncable
          server_only do
            MODEL_SECRET = 1
            BOTH_SIDES = 1
          end
        end
      RUBY
      File.write(File.join(app, "app/models/widget_client.rb"), <<~RUBY)
        class Widget
          BOTH_SIDES = 2
        end
      RUBY
      File.write(File.join(app, "app/controllers/widgets_controller.rb"), <<~RUBY)
        class WidgetsController < ApplicationController
          server_only do
            CTRL_SECRET = 1
          end
        end
      RUBY
      File.write(File.join(app, "app/helpers/widgets_helper.rb"), <<~RUBY)
        module WidgetsHelper
          server_only do
            HELPER_SECRET = 1
          end
        end
      RUBY
      File.write(File.join(app, "app/screens/widgets_screen.rb"), <<~RUBY)
        class WidgetsScreen < InstantRecord::Native::Screen
          server_only do
            SCREEN_SECRET = 1
          end
        end
      RUBY
      File.write(File.join(app, "config/application.rb"), <<~RUBY)
        module DemoApp
          class Application
            server_only do
              CONFIG_SECRET = 1
            end
          end
        end
      RUBY
      File.write(File.join(app, "lib/custom/util.rb"), <<~RUBY)
        module Custom
          server_only do
            CUSTOM_LIB_SECRET = 1
          end
        end
      RUBY

      # Excluded directories/files must not appear in server_only_constants
      File.write(File.join(app, "db/migrate/1_init.rb"), "server_only { DB_IGNORED = 1 }\n")
      File.write(File.join(app, "lib/tasks/work.rb"), "server_only { TASK_IGNORED = 1 }\n")
      File.write(File.join(app, "lib/generators/gen.rb"), "server_only { GEN_IGNORED = 1 }\n")
      File.write(File.join(app, "test/sample.rb"), "server_only { TEST_IGNORED = 1 }\n")
      File.write(File.join(app, "tmp/scratch.rb"), "server_only { TMP_IGNORED = 1 }\n")
      File.write(File.join(app, "vendor/dep.rb"), "server_only { VENDOR_IGNORED = 1 }\n")

      gv = GemVendor.new(gem_src: GEM_ROOT, app_dir: app, demo: false, target: :native)
      gv.run

      expected = {
        "Widget::MODEL_SECRET" => "app/models/widget.rb:4",
        "WidgetsController::CTRL_SECRET" => "app/controllers/widgets_controller.rb:3",
        "WidgetsHelper::HELPER_SECRET" => "app/helpers/widgets_helper.rb:3",
        "WidgetsScreen::SCREEN_SECRET" => "app/screens/widgets_screen.rb:3",
        "DemoApp::Application::CONFIG_SECRET" => "config/application.rb:4",
        "Custom::CUSTOM_LIB_SECRET" => "lib/custom/util.rb:3"
      }
      assert_equal expected, gv.server_only_constants

      # Lowered app files have server_only stripped; config/ and custom lib/ are untouched.
      refute_includes File.read(File.join(app, "app/models/widget.rb")), "MODEL_SECRET"
      assert_includes File.read(File.join(app, "app/models/widget.rb")), "include Syncable"
      assert_includes File.read(File.join(app, "config/application.rb")), "CONFIG_SECRET"
      assert_includes File.read(File.join(app, "lib/custom/util.rb")), "CUSTOM_LIB_SECRET"
    end
  end

  test "strips class-level contract blocks in app/screens while preserving line numbers and untouched screens" do
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(app, "app/screens"))

      with_contract = <<~RUBY
        class CardScreen < InstantRecord::Native::Screen
          contract "CardView" do |c|
            c.string :title
            c.action :open do |a|
              a.arg :id, :string
            end
          end

          client_only do
            def fast_title = "local"
          end

          def body
            contract_label = "contract"
            swift("CardView") { prop "title", contract_label }
          end
        end
      RUBY
      without_contract = <<~RUBY
        class PlainScreen < InstantRecord::Native::Screen
          def body
            navigation(title: "Plain") { text("ok") }
          end
        end
      RUBY
      comment_only_contract = <<~RUBY
        class CommentScreen < InstantRecord::Native::Screen
          # contract is mentioned only in comments and a method call
          def body
            contract("not_class_level")
          end
        end
      RUBY

      File.write(File.join(app, "app/screens/card_screen.rb"), with_contract)
      File.write(File.join(app, "app/screens/plain_screen.rb"), without_contract)
      File.write(File.join(app, "app/screens/comment_screen.rb"), comment_only_contract)

      GemVendor.vendor(gem_src: GEM_ROOT, app_dir: app, demo: false, target: :native)

      staged_card = File.read(File.join(app, "app/screens/card_screen.rb"))
      refute_includes staged_card, 'contract "CardView"'
      refute_includes staged_card, "client_only"
      assert_includes staged_card, 'def fast_title = "local"'
      assert_includes staged_card, 'contract_label = "contract"'
      # Removing contract preserves lines; unwrapping `client_only do ... end` removes 2 wrapper lines.
      assert_equal with_contract.lines.count - 2, staged_card.lines.count

      assert_equal without_contract, File.read(File.join(app, "app/screens/plain_screen.rb"))
      assert_equal comment_only_contract, File.read(File.join(app, "app/screens/comment_screen.rb"))
    end
  end

  test "supports standalone custom adapters that modify vendored files and models during install" do
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(app, "app/models"))
      File.write(File.join(app, "app/models/task.rb"), "class Task < ApplicationRecord\n  include InstantRecord::Syncable\nend\n")

      custom_adapter = Object.new
      custom_adapter.define_singleton_method(:host_source) do
        "module InstantRecord\n  module Host\n    def self.browser? = true\n  end\nend\n"
      end
      custom_adapter.define_singleton_method(:install) do |gem_src:, app_dir:|
        File.write(File.join(app_dir, "lib/instant_record/host.rb"), host_source)
        File.write(File.join(app_dir, "lib/instant_record/custom_ext.rb"), <<~RUBY)
          module InstantRecord
            server_only do
              CUSTOM_ADAPTER_SECRET = 99
            end
            browser_only do
              def self.custom_ext? = true
            end
          end
        RUBY
        syncable_path = File.join(app_dir, "lib/instant_record/syncable.rb")
        File.write(syncable_path, File.read(syncable_path).sub("module Syncable\n", "module Syncable\n    # custom marker\n"))
      end

      gv = GemVendor.new(gem_src: GEM_ROOT, app_dir: app, demo: false, adapter: custom_adapter)
      assert_same custom_adapter, gv.adapter
      assert_equal GemVendor::COPY.length + 1, gv.run

      assert_equal({ "InstantRecord::CUSTOM_ADAPTER_SECRET" => "lib/instant_record/custom_ext.rb:3" }, gv.server_only_constants)
      ext = File.read(File.join(app, "lib/instant_record/custom_ext.rb"))
      refute_includes ext, "CUSTOM_ADAPTER_SECRET"
      assert_includes ext, "def self.custom_ext? = true"
      assert_includes File.read(File.join(app, "app/models/concerns/syncable.rb")), "# custom marker"
      assert_includes File.read(File.join(app, "app/models/task.rb")), "include Syncable"
    end
  end

  test "demo vendoring applies demo seams and lowers staged demo files cleanly" do
    Dir.mktmpdir do |dir|
      app = File.join(dir, "demo_app")
      InstantRecord::Compiler::AppStage.stage(
        source: File.join(GEM_ROOT, "demo"),
        target: app,
        native: false,
        overlay_dir: File.join(PIPELINE_DIR, "demo"),
        manifest_path: File.join(dir, "manifest.json")
      )

      gv = GemVendor.new(gem_src: GEM_ROOT, app_dir: app, demo: true, target: :wasm)
      assert_equal GemVendor::COPY.length + 1, gv.run
      assert_equal({}, gv.server_only_constants)
      assert_includes File.read(File.join(app, "app/helpers/slack_helper.rb")), '"/slack/reset?instant_record_network=1"'
      assert_includes File.read(File.join(app, "app/controllers/slack/channels_controller.rb")), ".to_a : []"
      refute_includes File.read(File.join(app, "app/controllers/slack/channels_controller.rb")), "InstantRecord.browser?"
      assert StaticLinter.lint(app, staged: true).ok?
    end
  end

  test "raises cleanly on unknown target, missing gem source, or malformed syncable/sync_actions" do
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app")
      assert_raises(ArgumentError) { GemVendor.new(gem_src: GEM_ROOT, app_dir: app, target: :unknown) }

      empty_gem = File.join(dir, "empty_gem")
      FileUtils.mkdir_p(empty_gem)
      assert_raises(Errno::ENOENT) { GemVendor.vendor(gem_src: empty_gem, app_dir: app) }

      broken_gem = File.join(dir, "broken_gem")
      GemVendor::COPY.each do |rel|
        dst = File.join(broken_gem, rel)
        FileUtils.mkdir_p(File.dirname(dst))
        FileUtils.cp(File.join(GEM_ROOT, rel), dst)
      end
      FileUtils.mkdir_p(File.join(broken_gem, "app/models/instant_record"))
      FileUtils.cp(File.join(GEM_ROOT, "app/models/instant_record/change.rb"), File.join(broken_gem, "app/models/instant_record/change.rb"))
      FileUtils.mkdir_p(File.join(broken_gem, "sig/instant_record"))
      HostAdapters::Wasm.signatures.each do |rbs|
        FileUtils.cp(File.join(GEM_ROOT, "sig/instant_record", rbs), File.join(broken_gem, "sig/instant_record", rbs))
      end

      File.write(File.join(broken_gem, "lib/instant_record/syncable.rb"), "def (\n")
      assert_raises(BuildError) { GemVendor.vendor(gem_src: broken_gem, app_dir: File.join(dir, "bad_syncable")) }

      FileUtils.cp(File.join(GEM_ROOT, "lib/instant_record/syncable.rb"), File.join(broken_gem, "lib/instant_record/syncable.rb"))
      File.write(File.join(broken_gem, "lib/instant_record/sync_actions.rb"), "def (\n")
      assert_raises(BuildError) { GemVendor.vendor(gem_src: broken_gem, app_dir: File.join(dir, "bad_actions")) }
    end
  end

  test "COPY_DIRS covers every directory in COPY and excluded dirs match StaticLinter::NON_COMPILED_PREFIXES" do
    assert GemVendor::COPY_DIRS.frozen?
    expected_copy_dirs = GemVendor::COPY.map { |rel| File.dirname(rel) }.uniq
    assert_equal expected_copy_dirs, GemVendor::COPY_DIRS
    GemVendor::COPY.each do |rel|
      assert_includes GemVendor::COPY_DIRS, File.dirname(rel)
    end

    excluded_by_prefix = GemVendor.const_get(:EXCLUDED_DIRS_BY_PREFIX)
    reconstructed = excluded_by_prefix.flat_map do |parent, dirs|
      dirs.keys.map { |dir| "#{parent}#{dir}/" }
    end.sort
    assert_equal StaticLinter::NON_COMPILED_PREFIXES.sort, reconstructed

    top_level = GemVendor.const_get(:TOP_LEVEL_EXCLUDED_DIRS)
    lib_level = GemVendor.const_get(:LIB_EXCLUDED_DIRS)
    expected_top = StaticLinter::NON_COMPILED_PREFIXES.select { |p| p.count("/") == 1 }.map { |p| p.delete_suffix("/") }.sort
    expected_lib = StaticLinter::NON_COMPILED_PREFIXES.select { |p| p.start_with?("lib/") }.map { |p| p.delete_prefix("lib/").delete_suffix("/") }.sort
    assert_equal expected_top, top_level.keys.sort
    assert_equal expected_lib, lib_level.keys.sort

    deep = GemVendor.send(:excluded_dirs_by_prefix, %w[spec/ app/assets/ config/locales/custom/])
    assert_equal({ "" => { "spec" => true }, "app/" => { "assets" => true }, "config/locales/" => { "custom" => true } }, deep)

    utf8 = GemVendor.send(:excluded_dirs_by_prefix, ["café/assets/", "café/résumé/dossiers/", "日本語/"])
    assert_equal(
      {
        "café/" => { "assets" => true },
        "café/résumé/" => { "dossiers" => true },
        "" => { "日本語" => true }
      },
      utf8
    )
  end

  test "HostAdapters::Base overrides and stubbed install take the disk fallback cleanly" do
    base_class = Class.new do
      include HostAdapters::Base

      def host_source
        HostAdapters::Wasm.host_source
      end
    end

    install_override_class = Class.new(base_class) do
      attr_reader :called

      def install(gem_src:, app_dir:)
        @called = true
        super
        File.write(File.join(app_dir, "lib/instant_record/override_install.rb"), <<~RUBY)
          module InstantRecord
            server_only do
              INSTALL_OVERRIDE_SECRET = 1
            end
          end
        RUBY
      end
    end

    sync_actions_override_class = Class.new(base_class) do
      attr_reader :called

      private

      def adapt_sync_actions(app_dir)
        @called = true
        super
        path = File.join(app_dir, "lib/instant_record/sync_actions.rb")
        File.write(path, File.read(path) + "# custom_sync_actions_override\n")
      end
    end

    mutate_override_class = Class.new(base_class) do
      attr_reader :called

      private

      def adapt_compiled_mutate_signatures(app_dir)
        @called = true
        super
        path = File.join(app_dir, "lib/instant_record.rb")
        File.write(path, File.read(path) + "# custom_mutate_override\n")
      end
    end

    Dir.mktmpdir do |dir|
      # Unmodified Base includer uses the standard in-memory pipeline.
      plain_adapter = base_class.new
      plain_gv = GemVendor.new(gem_src: GEM_ROOT, app_dir: File.join(dir, "plain"), adapter: plain_adapter)
      assert plain_gv.send(:standard_base_adapter?)
      assert_equal GemVendor::COPY.length + 1, plain_gv.run

      # Overriding #install falls back to the disk pipeline.
      install_adapter = install_override_class.new
      install_app = File.join(dir, "install_override")
      install_gv = GemVendor.new(gem_src: GEM_ROOT, app_dir: install_app, adapter: install_adapter)
      refute install_gv.send(:standard_base_adapter?)
      install_gv.run
      assert install_adapter.called
      assert_equal({ "InstantRecord::INSTALL_OVERRIDE_SECRET" => "lib/instant_record/override_install.rb:3" }, install_gv.server_only_constants)
      refute_includes File.read(File.join(install_app, "lib/instant_record/override_install.rb")), "INSTALL_OVERRIDE_SECRET"

      # Overriding private #adapt_sync_actions falls back to the disk pipeline.
      sync_adapter = sync_actions_override_class.new
      sync_app = File.join(dir, "sync_override")
      sync_gv = GemVendor.new(gem_src: GEM_ROOT, app_dir: sync_app, adapter: sync_adapter)
      refute sync_gv.send(:standard_base_adapter?)
      sync_gv.run
      assert sync_adapter.called
      assert_includes File.read(File.join(sync_app, "lib/instant_record/sync_actions.rb")), "# custom_sync_actions_override"

      # Overriding private #adapt_compiled_mutate_signatures falls back to the disk pipeline.
      mutate_adapter = mutate_override_class.new
      mutate_app = File.join(dir, "mutate_override")
      mutate_gv = GemVendor.new(gem_src: GEM_ROOT, app_dir: mutate_app, adapter: mutate_adapter)
      refute mutate_gv.send(:standard_base_adapter?)
      mutate_gv.run
      assert mutate_adapter.called
      assert_includes File.read(File.join(mutate_app, "lib/instant_record.rb")), "# custom_mutate_override"

      # Runtime stubbing of #install on a built-in adapter also falls back safely.
      stub_app = File.join(dir, "stubbed_wasm")
      stub_called = false
      HostAdapters::Wasm.define_singleton_method(:install) do |gem_src:, app_dir:|
        stub_called = true
        super(gem_src: gem_src, app_dir: app_dir)
      end
      begin
        stub_gv = GemVendor.new(gem_src: GEM_ROOT, app_dir: stub_app, target: :wasm)
        refute stub_gv.send(:standard_base_adapter?)
        stub_gv.run
        assert stub_called
      ensure
        HostAdapters::Wasm.singleton_class.send(:remove_method, :install)
      end
    end
  end

  test "handles symlinked files and dirs, hidden ruby files and dirs, and iso-8859-1 sources" do
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app")
      external = File.join(dir, "external")
      FileUtils.mkdir_p(File.join(app, "app/models/.hidden_dir"))
      FileUtils.mkdir_p(File.join(app, "app/screens"))
      FileUtils.mkdir_p(File.join(app, "spec"))
      FileUtils.mkdir_p(File.join(app, "node_modules/pkg"))
      FileUtils.mkdir_p(File.join(external, "linked_dir"))

      # Symlinked regular .rb file should be scanned and lowered.
      linked_target = File.join(external, "linked_item.rb")
      File.write(linked_target, <<~RUBY)
        class LinkedItem < ApplicationRecord
          include InstantRecord::Syncable
          server_only do
            LINKED_FILE_SECRET = 1
          end
        end
      RUBY
      File.symlink(linked_target, File.join(app, "app/models/linked_item.rb"))

      # Symlinked directory must not be traversed (matches Dir.glob("**/*.rb")).
      linked_dir_file = File.join(external, "linked_dir/nested.rb")
      File.write(linked_dir_file, "class LinkedDirModel\n  server_only { LINKED_DIR_SECRET = 1 }\nend\n")
      File.symlink(File.join(external, "linked_dir"), File.join(app, "app/models/linked_dir"))

      # Dangling symlink must be skipped safely without raising ENOENT.
      File.symlink(File.join(external, "does_not_exist.rb"), File.join(app, "app/models/dangling.rb"))

      # Hidden .rb files and hidden directories must be ignored.
      hidden_file = File.join(app, "app/models/.hidden.rb")
      hidden_dir_file = File.join(app, "app/models/.hidden_dir/nested.rb")
      File.write(hidden_file, "class HiddenFile\n  server_only { HIDDEN_FILE_SECRET = 1 }\nend\n")
      File.write(hidden_dir_file, "class HiddenDir\n  server_only { HIDDEN_DIR_SECRET = 1 }\nend\n")

      # Additional non-compiled prefixes (spec/, node_modules/) must be excluded.
      File.write(File.join(app, "spec/sample_spec.rb"), "server_only { SPEC_SECRET = 1 }\n")
      File.write(File.join(app, "node_modules/pkg/tool.rb"), "server_only { NODE_SECRET = 1 }\n")

      # Non-UTF-8 (# coding: iso-8859-1) model and screens with Latin-1 bytes (\xE9).
      latin_model = (
        "# coding: iso-8859-1\n" \
        "class LatinModel < ApplicationRecord\n" \
        "  include InstantRecord::Syncable\n" \
        "  LABEL = \"caf\xE9\"\n" \
        "  server_only do\n" \
        "    LATIN_MODEL_SECRET = \"caf\xE9\"\n" \
        "  end\n" \
        "  client_only do\n" \
        "    def label = \"caf\xE9\"\n" \
        "  end\n" \
        "end\n"
      ).b
      latin_screen = (
        "# coding: iso-8859-1\n" \
        "class LatinScreen < InstantRecord::Native::Screen\n" \
        "  TITLE = \"caf\xE9\"\n" \
        "  contract \"LatinView\" do |c|\n" \
        "    c.string :title\n" \
        "  end\n" \
        "  server_only do\n" \
        "    LATIN_SCREEN_SECRET = \"caf\xE9\"\n" \
        "  end\n" \
        "  def body\n" \
        "    swift(\"LatinView\") { prop \"title\", TITLE }\n" \
        "  end\n" \
        "end\n"
      ).b
      plain_latin_screen = (
        "# coding: iso-8859-1\n" \
        "class PlainLatinScreen < InstantRecord::Native::Screen\n" \
        "  def body\n" \
        "    text(\"caf\xE9\")\n" \
        "  end\n" \
        "end\n"
      ).b

      File.binwrite(File.join(app, "app/models/latin_model.rb"), latin_model)
      File.binwrite(File.join(app, "app/screens/latin_screen.rb"), latin_screen)
      File.binwrite(File.join(app, "app/screens/plain_latin_screen.rb"), plain_latin_screen)

      gv = GemVendor.new(gem_src: GEM_ROOT, app_dir: app, demo: false, target: :native)
      gv.run

      assert_equal(
        {
          "LatinModel::LATIN_MODEL_SECRET" => "app/models/latin_model.rb:6",
          "LinkedItem::LINKED_FILE_SECRET" => "app/models/linked_item.rb:4",
          "LatinScreen::LATIN_SCREEN_SECRET" => "app/screens/latin_screen.rb:8"
        },
        gv.server_only_constants
      )

      staged_linked = File.read(linked_target)
      assert_includes staged_linked, "include Syncable"
      refute_includes staged_linked, "LINKED_FILE_SECRET"

      assert_includes File.read(linked_dir_file), "LINKED_DIR_SECRET"
      assert_includes File.read(hidden_file), "HIDDEN_FILE_SECRET"
      assert_includes File.read(hidden_dir_file), "HIDDEN_DIR_SECRET"

      staged_latin_model = File.binread(File.join(app, "app/models/latin_model.rb"))
      assert_includes staged_latin_model, "include Syncable".b
      assert_includes staged_latin_model, "def label = \"caf\xE9\"".b
      refute_includes staged_latin_model, "LATIN_MODEL_SECRET".b
      refute_includes staged_latin_model, "client_only".b

      staged_latin_screen = File.binread(File.join(app, "app/screens/latin_screen.rb"))
      assert_includes staged_latin_screen, "TITLE = \"caf\xE9\"".b
      refute_includes staged_latin_screen, "contract \"LatinView\"".b
      refute_includes staged_latin_screen, "LATIN_SCREEN_SECRET".b
      # Stripping the 3-line server_only block removes 3 lines; stripping contract preserves its lines.
      assert_equal latin_screen.count("\n") - 3, staged_latin_screen.count("\n")

      # Direct strip_native_contracts on an iso-8859-1 screen preserves exact line count and bytes.
      contract_only_latin = (
        "# coding: iso-8859-1\n" \
        "class ContractLatinScreen < InstantRecord::Native::Screen\n" \
        "  contract \"Latin\" do |c|\n" \
        "    c.string :label\n" \
        "  end\n" \
        "  def body = text(\"caf\xE9\")\n" \
        "end\n"
      ).b
      stripped_latin = gv.send(:strip_native_contracts, contract_only_latin)
      refute_includes stripped_latin, "contract \"Latin\"".b
      assert_includes stripped_latin, "text(\"caf\xE9\")".b
      assert_equal contract_only_latin.count("\n"), stripped_latin.count("\n")

      assert_equal plain_latin_screen, File.binread(File.join(app, "app/screens/plain_latin_screen.rb"))
    end
  end

  test "lower_and_write_app_sources writes deferred dirty_rels outside lowered app directories" do
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(app, "config"))
      config_path = File.join(app, "config/demo_override.rb")
      File.write(config_path, "OLD = 1\n")

      gv = GemVendor.new(gem_src: GEM_ROOT, app_dir: app, target: :wasm)
      dirty = { "config/demo_override.rb" => "NEW = 2\n" }
      gv.send(:lower_and_write_app_sources, dirty, dirty_rels: dirty)

      assert_equal "NEW = 2\n", File.read(config_path)
    end
  end
end
