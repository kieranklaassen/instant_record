require "fileutils"
require_relative "ast_lowerer"
require_relative "host_adapters"
require_relative "runner"
require_relative "static_linter"

module InstantRecord
  class Compiler
    # Vendors the instant_record gem's Ruby into the staged app's lib/, installs
    # the target's swappable host-adapter module, and runs the Prism AST lowering
    # pass (stripping `server_only`, unwrapping `browser_only`/`client_only`,
    # folding `InstantRecord.browser?`, and unnesting `Syncable`).
    class GemVendor
      COPY = %w[
        lib/instant_record.rb
        lib/instant_record/version.rb
        lib/instant_record/host.rb
        lib/instant_record/configuration.rb
        lib/instant_record/runtime_scoped.rb
        lib/instant_record/sync_actions.rb
        lib/instant_record/syncable.rb
        lib/instant_record/outbox_mutation.rb
        lib/instant_record/sync_metadata.rb
        lib/instant_record/sync_notice.rb
        lib/instant_record/sync_window.rb
        lib/instant_record/client.rb
        lib/instant_record/client/rebaser.rb
        lib/instant_record/client/transport.rb
        lib/instant_record/client/notifier.rb
        lib/instant_record/branch.rb
        lib/instant_record/native/node.rb
        lib/instant_record/native/screen.rb
      ].freeze

      SQLITE_DATABASE_YML = <<~YAML
        default: &default
          adapter: sqlite3
          database: storage/development.sqlite3

        development:
          <<: *default

        production:
          <<: *default
      YAML

      attr_reader :adapter, :server_only_constants

      def self.vendor(gem_src:, app_dir:, demo: false, target: :wasm, adapter: nil)
        new(gem_src: gem_src, app_dir: app_dir, demo: demo, target: target, adapter: adapter).run
      end

      def initialize(gem_src:, app_dir:, demo: false, target: :wasm, adapter: nil)
        @gem = gem_src.to_s
        @app = app_dir.to_s
        @demo = demo
        @adapter = HostAdapters.for(adapter || target)
        @server_only_constants = {}
      end

      def run
        copy_gem_files
        @adapter.install(gem_src: @gem, app_dir: @app)
        unnest_syncable_concern
        write_sqlite_database_yml
        HostAdapters::Demo.apply(app_dir: @app) if @demo
        @server_only_constants = StaticLinter.collect_server_only_constants(@app, staged: true)
        lower_staged_ruby
        COPY.length + 1
      end

      private

      def copy_gem_files
        FileUtils.rm_rf(File.join(@app, "lib/instant_record"))
        COPY.each do |rel|
          target = File.join(@app, rel)
          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.cp(File.join(@gem, rel), target)
        end
        FileUtils.mkdir_p(File.join(@app, "app/models/instant_record"))
        FileUtils.cp(
          File.join(@gem, "app/models/instant_record/change.rb"),
          File.join(@app, "app/models/instant_record/change.rb")
        )
        copy_optional_gem_file("app/helpers/instant_record/sync_notices_helper.rb")
        copy_optional_gem_file("app/views/instant_record/sync_notices/_notices.html.erb")
      end

      def copy_optional_gem_file(rel)
        source = File.join(@gem, rel)
        return unless File.file?(source)

        target = File.join(@app, rel)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(source, target)
      end

      def unnest_syncable_concern
        path = File.join(@app, "lib/instant_record/syncable.rb")
        unnested = AstLowerer.unnest_syncable(File.read(path, encoding: Encoding::UTF_8))

        concerns_dir = File.join(@app, "app/models/concerns")
        FileUtils.mkdir_p(concerns_dir)
        FileUtils.rm_rf(File.join(concerns_dir, "instant_record"))
        File.write(File.join(concerns_dir, "syncable.rb"), unnested)
        File.delete(path)
      end

      def write_sqlite_database_yml
        config_dir = File.join(@app, "config")
        FileUtils.mkdir_p(config_dir)
        File.write(File.join(config_dir, "database.yml"), SQLITE_DATABASE_YML)
      end

      def lower_staged_ruby
        lower_directory("app/models", rewrite_syncable_include: true)
        %w[app/controllers app/helpers app/screens lib/instant_record].each do |subdir|
          lower_directory(subdir, rewrite_syncable_include: false)
        end
      end

      def lower_directory(subdir, rewrite_syncable_include:)
        root = File.join(@app, subdir)
        return unless File.directory?(root)

        Dir.glob("**/*.rb", base: root).sort.each do |rel|
          AstLowerer.lower_file(
            File.join(root, rel),
            runtime: :client,
            rewrite_syncable_include: rewrite_syncable_include
          )
        end
      end
    end
  end
end
