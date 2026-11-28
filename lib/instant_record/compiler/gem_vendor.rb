require "fileutils"
require "prism"
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
        lib/instant_record/inertia.rb
        lib/instant_record/read_tracker.rb
        lib/instant_record/sync_actions.rb
        lib/instant_record/syncable.rb
        lib/instant_record/outbox_mutation.rb
        lib/instant_record/sync_metadata.rb
        lib/instant_record/sync_partition.rb
        lib/instant_record/hlc.rb
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

      COPY_DIRS = COPY.map { |rel| File.dirname(rel) }.uniq.freeze

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

      def self.excluded_dirs_by_prefix(prefixes = StaticLinter::NON_COMPILED_PREFIXES)
        prefixes.each_with_object({}) do |prefix, map|
          trimmed = prefix.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
          next if trimmed.empty?

          slash = trimmed.byterindex("/")
          parent = slash ? trimmed.byteslice(0, slash + 1).freeze : "".freeze
          child = slash ? trimmed.byteslice(slash + 1, trimmed.bytesize - slash - 1).freeze : trimmed.freeze
          (map[parent] ||= {})[child] = true
        end.transform_values(&:freeze).freeze
      end
      private_class_method :excluded_dirs_by_prefix

      EXCLUDED_DIRS_BY_PREFIX = excluded_dirs_by_prefix
      TOP_LEVEL_EXCLUDED_DIRS = (EXCLUDED_DIRS_BY_PREFIX[""] || {}.freeze)
      LIB_EXCLUDED_DIRS = (EXCLUDED_DIRS_BY_PREFIX["lib/"] || {}.freeze)
      CONTRACT_MARKER = "contract".freeze
      NUL_BYTE = "\0".freeze
      private_constant :EXCLUDED_DIRS_BY_PREFIX, :TOP_LEVEL_EXCLUDED_DIRS, :LIB_EXCLUDED_DIRS, :CONTRACT_MARKER, :NUL_BYTE

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
        if standard_base_adapter?
          run_standard_pipeline
        else
          run_custom_adapter_pipeline
        end
        COPY.length + 1
      end

      private

      def standard_base_adapter?
        @adapter.is_a?(HostAdapters::Base) &&
          @adapter.method(:install).owner == HostAdapters::Base &&
          @adapter.method(:adapt_compiled_mutate_signatures).owner == HostAdapters::Base &&
          @adapter.method(:adapt_sync_actions).owner == HostAdapters::Base
      rescue NameError
        false
      end

      def run_standard_pipeline
        prepare_staged_directories
        write_sqlite_database_yml

        # Load, adapt, and unnest gem Ruby files in memory once so each file is
        # read from `@gem`, inspected by StaticLinter, lowered, and written to
        # `@app` exactly once without intermediate disk round-trips.
        gem_sources = load_adapted_gem_sources
        install_signatures_and_non_ruby_gem_files

        demo_ruby = nil
        skip_app_views = false
        view_rb_files = nil
        if @demo
          demo_ruby, view_rb_files = HostAdapters::Demo.apply_staged(app_dir: @app, defer_ruby_writes: true)
          skip_app_views = !view_rb_files.nil?
        end

        overridden = demo_ruby && !demo_ruby.empty? ? gem_sources.merge(demo_ruby) : gem_sources
        app_sources = scan_app_ruby_sources(skip_ir_lib: true, skip_app_views: skip_app_views, overridden: overridden)
        if view_rb_files && !view_rb_files.empty?
          view_rb_files.each { |rel, bytes| app_sources[rel] = bytes unless overridden.key?(rel) }
        end
        if demo_ruby && !demo_ruby.empty?
          demo_ruby.each { |rel, src| app_sources[rel] = src }
        end

        collect_server_only_constants_in_memory(gem_sources, app_sources)

        lower_and_write_gem_sources(gem_sources)
        lower_and_write_app_sources(app_sources, dirty_rels: demo_ruby)
      end

      def run_custom_adapter_pipeline
        copy_gem_files
        @adapter.install(gem_src: @gem, app_dir: @app)
        unnest_syncable_concern
        write_sqlite_database_yml
        HostAdapters::Demo.apply(app_dir: @app) if @demo

        all_sources = scan_app_ruby_sources(skip_ir_lib: false, skip_app_views: false, overridden: nil)
        collect_server_only_constants_in_memory(nil, all_sources)
        lower_and_write_app_sources(all_sources, include_ir_lib: true)
      end

      def ensure_dir(path)
        return if File.directory?(path)

        parent = File.dirname(path)
        ensure_dir(parent) if parent != path
        Dir.mkdir(path)
      rescue Errno::EEXIST
        raise unless File.directory?(path)
      end

      def prepare_staged_directories
        ir_lib = "#{@app}/lib/instant_record"
        FileUtils.rm_rf(ir_lib) if File.exist?(ir_lib) || File.symlink?(ir_lib)

        ir_concerns = "#{@app}/app/models/concerns/instant_record"
        FileUtils.rm_rf(ir_concerns) if File.exist?(ir_concerns) || File.symlink?(ir_concerns)

        COPY_DIRS.each { |dir| ensure_dir("#{@app}/#{dir}") }
        ensure_dir("#{@app}/app/models/concerns")
        ensure_dir("#{@app}/app/models/instant_record")
        ensure_dir("#{@app}/config")
      end

      def load_adapted_gem_sources
        sources = {}

        COPY.each do |rel|
          src_path = "#{@gem}/#{rel}"
          case rel
          when "lib/instant_record/host.rb"
            File.stat(src_path)
            sources[rel] = @adapter.host_source
          when "lib/instant_record/runtime_scoped.rb"
            File.stat(src_path)
            sources[rel] = HostAdapters::RUNTIME_SCOPED_SEAM
          when "lib/instant_record/syncable.rb"
            raw = File.binread(src_path).force_encoding(Encoding::UTF_8)
            sources["app/models/concerns/syncable.rb"] = AstLowerer.unnest_syncable(raw)
          when "lib/instant_record.rb"
            raw = File.binread(src_path).force_encoding(Encoding::UTF_8)
            sources[rel] = @adapter.adapt_compiled_mutate_source(raw)
          when "lib/instant_record/sync_actions.rb"
            raw = File.binread(src_path).force_encoding(Encoding::UTF_8)
            sources[rel] = @adapter.adapt_sync_actions_source(raw, rel: rel)
          else
            sources[rel] = File.binread(src_path)
          end
        end

        sources["lib/instant_record/native.rb"] = HostAdapters::NATIVE_SEAM
        sources["app/models/instant_record/change.rb"] =
          File.binread("#{@gem}/app/models/instant_record/change.rb")

        %w[sync_notices_helper native_helper].each do |helper|
          helper_rel = "app/helpers/instant_record/#{helper}.rb"
          helper_src = "#{@gem}/#{helper_rel}"
          next unless File.file?(helper_src)

          ensure_dir("#{@app}/app/helpers/instant_record")
          sources[helper_rel] = File.binread(helper_src)
        end

        sources
      end

      def install_signatures_and_non_ruby_gem_files
        sig_dir = "#{@app}/sig/instant_record"
        ensure_dir(sig_dir)
        @adapter.signatures.each do |rbs|
          File.binwrite(
            "#{sig_dir}/#{rbs}",
            File.binread("#{@gem}/sig/instant_record/#{rbs}")
          )
        end

        copy_optional_gem_file("app/views/instant_record/sync_notices/_notices.html.erb")
      end

      def copy_gem_files
        ir_lib = "#{@app}/lib/instant_record"
        FileUtils.rm_rf(ir_lib) if File.exist?(ir_lib) || File.symlink?(ir_lib)

        COPY_DIRS.each { |dir| ensure_dir("#{@app}/#{dir}") }
        ensure_dir("#{@app}/app/models/instant_record")

        COPY.each do |rel|
          File.binwrite("#{@app}/#{rel}", File.binread("#{@gem}/#{rel}"))
        end
        File.binwrite(
          "#{@app}/app/models/instant_record/change.rb",
          File.binread("#{@gem}/app/models/instant_record/change.rb")
        )
        copy_optional_gem_file("app/helpers/instant_record/sync_notices_helper.rb")
        copy_optional_gem_file("app/helpers/instant_record/native_helper.rb")
        copy_optional_gem_file("app/views/instant_record/sync_notices/_notices.html.erb")
      end

      def copy_optional_gem_file(rel)
        source = "#{@gem}/#{rel}"
        return unless File.file?(source)

        target = "#{@app}/#{rel}"
        ensure_dir(File.dirname(target))
        File.binwrite(target, File.binread(source))
      end

      def unnest_syncable_concern
        path = "#{@app}/lib/instant_record/syncable.rb"
        unnested = AstLowerer.unnest_syncable(File.read(path, encoding: Encoding::UTF_8))

        concerns_dir = "#{@app}/app/models/concerns"
        ensure_dir(concerns_dir)
        ir_concerns = "#{concerns_dir}/instant_record"
        FileUtils.rm_rf(ir_concerns) if File.exist?(ir_concerns) || File.symlink?(ir_concerns)
        File.binwrite("#{concerns_dir}/syncable.rb", unnested)
        File.delete(path)
      end

      def write_sqlite_database_yml
        config_dir = "#{@app}/config"
        ensure_dir(config_dir)
        File.binwrite("#{config_dir}/database.yml", SQLITE_DATABASE_YML)
      end

      def scan_app_ruby_sources(skip_ir_lib:, skip_app_views:, overridden:)
        sources = {}
        return sources unless File.directory?(@app)

        walk_staged_ruby(
          @app, "",
          skip_ir_lib: skip_ir_lib,
          skip_app_views: skip_app_views,
          overridden: overridden,
          out: sources
        )
        sources
      end

      def walk_staged_ruby(dir, prefix, skip_ir_lib:, skip_app_views:, overridden:, out:)
        excluded_dirs = EXCLUDED_DIRS_BY_PREFIX[prefix]
        skip_ir_here = skip_ir_lib && prefix == "lib/"
        skip_views_here = skip_app_views && prefix == "app/"

        Dir.each_child(dir) do |entry|
          next if entry.start_with?(".")
          next if excluded_dirs && excluded_dirs[entry]
          next if skip_ir_here && entry == "instant_record"
          next if skip_views_here && entry == "views"

          full = "#{dir}/#{entry}"
          st = File.lstat(full)
          if st.directory?
            walk_staged_ruby(
              full, "#{prefix}#{entry}/",
              skip_ir_lib: skip_ir_lib,
              skip_app_views: skip_app_views,
              overridden: overridden,
              out: out
            )
          elsif entry.end_with?(".rb") && (st.file? || (st.symlink? && File.file?(full)))
            rel = prefix.empty? ? entry : "#{prefix}#{entry}"
            next if overridden && overridden.key?(rel)

            out[rel] = File.binread(full)
          end
        end
      end

      def collect_server_only_constants_in_memory(gem_sources, app_sources)
        combined = []
        gem_sources&.each { |rel, src| combined << [rel, src] }
        app_sources.each { |rel, src| combined << [rel, src] }
        combined.sort_by!(&:first)
        @server_only_constants = StaticLinter.collect_server_only_constants_from_sources(combined)
      end

      def lower_and_write_gem_sources(gem_sources)
        gem_sources.each do |rel, raw|
          output =
            if rel == "lib/instant_record.rb"
              raw
            else
              AstLowerer.lower(
                normalize_source_encoding(raw),
                runtime: :client,
                rewrite_syncable_include: rel.start_with?("app/models/")
              )
            end
          File.binwrite("#{@app}/#{rel}", output)
        end
      end

      def lower_and_write_app_sources(app_sources, include_ir_lib: false, dirty_rels: nil)
        app_sources.each do |rel, raw_bytes|
          rewrite_syncable =
            if rel.start_with?("app/models/")
              true
            elsif rel.start_with?("app/controllers/", "app/helpers/", "app/screens/") ||
                  (include_ir_lib && rel.start_with?("lib/instant_record/"))
              false
            else
              if dirty_rels && dirty_rels.key?(rel)
                target = "#{@app}/#{rel}"
                ensure_dir(File.dirname(target))
                File.binwrite(target, raw_bytes)
              end
              next
            end

          source = normalize_source_encoding(raw_bytes)
          output = AstLowerer.lower(
            source,
            runtime: :client,
            rewrite_syncable_include: rewrite_syncable
          )
          output = strip_native_contracts(output) if rel.start_with?("app/screens/")

          if (dirty_rels && dirty_rels.key?(rel)) || (!output.equal?(source) && output != source)
            File.binwrite("#{@app}/#{rel}", output)
          end
        end
      end

      def normalize_source_encoding(raw)
        return raw if raw.encoding == Encoding::UTF_8 && raw.valid_encoding?

        utf8 = raw.frozen? ? raw.dup : raw
        utf8.force_encoding(Encoding::UTF_8)
        return utf8 if utf8.valid_encoding?

        utf8.force_encoding(Encoding::BINARY)
      end

      # Remove class-level `contract ... do ... end` declarations from staged
      # app/screens files before Roundhouse/Spinel compile them, preserving line
      # counts so `#line` diagnostics in generated C remain exact.
      def strip_native_contracts(source)
        if source.encoding.ascii_compatible? && !source.include?(NUL_BYTE) && !source.include?(CONTRACT_MARKER)
          return source
        end

        parsed = Prism.parse(source)
        return source unless parsed.success?

        calls = contract_calls(parsed.value)
        return source if calls.empty?

        edits = calls.map do |call|
          location = call.location
          AstLowerer::Edit.new(
            start_offset: location.start_offset,
            end_offset: location.end_offset,
            replacement: "\n" * location.slice.b.count("\n")
          )
        end
        AstLowerer.apply_edits(source, edits)
      end

      # The `contract` calls standing directly in a class body, in source order.
      # A call anywhere else (top level, module body, method) is not one.
      def contract_calls(node)
        case node
        when Prism::ProgramNode
          contract_calls(node.statements)
        when Prism::StatementsNode
          node.body.flat_map { |stmt| contract_calls(stmt) }
        when Prism::ModuleNode
          contract_calls(node.body)
        when Prism::ClassNode
          return [] unless node.body.is_a?(Prism::StatementsNode)

          node.body.body.flat_map { |stmt| contract_call?(stmt) ? [stmt] : contract_calls(stmt) }
        else
          []
        end
      end

      def contract_call?(node)
        node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :contract
      end
    end
  end
end
