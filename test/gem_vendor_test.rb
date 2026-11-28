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
end
