require "fileutils"
require "pathname"
require "set"
require_relative "manifest"
require_relative "reachability_tracer"
require_relative "route_analyzer"
require_relative "runner"

module InstantRecord
  class Compiler
    module FileCopy
      EMPTY_ARRAY = [].freeze
      EMPTY_SET = Set.new.freeze
      SMALL_FILE_THRESHOLD = 262_144
      CREATE_EXCL_MODE = File::WRONLY | File::CREAT | File::EXCL | File::BINARY
      CREATE_TRUNC_MODE = File::WRONLY | File::CREAT | File::TRUNC | File::BINARY

      module_function

      def copy_tree(source, target, ignore: EMPTY_ARRAY, visited: EMPTY_SET)
        source_str = File.path(source)
        source_str = source_str.chomp(File::SEPARATOR) while source_str.length > 1 && source_str.end_with?(File::SEPARATOR)
        target_str = File.path(target)
        target_str = target_str.chomp(File::SEPARATOR) while target_str.length > 1 && target_str.end_with?(File::SEPARATOR)

        root_stat = File.stat(source_str)
        seen = {}
        unless visited.empty?
          visited.each do |entry|
            st = File.stat(entry)
            (seen[st.dev] ||= {})[st.ino] = true
          rescue SystemCallError
            next
          end
        end

        ignored = if ignore.is_a?(Array)
          ignore.empty? ? nil : ignore.to_h { |name| [name, true] }
        elsif ignore.respond_to?(:empty?) && ignore.empty?
          nil
        else
          ignore
        end

        copy_tree_dir(source_str, target_str, root_stat, ignored, seen, top: true)
      end

      def copy_tree_dir(source_str, target_str, dir_stat, ignored, seen, top:)
        dev_seen = (seen[dir_stat.dev] ||= {})
        ino = dir_stat.ino
        return if dev_seen.key?(ino)

        dev_seen[ino] = true
        begin
          begin
            Dir.mkdir(target_str)
          rescue Errno::ENOENT
            raise unless top

            FileUtils.mkdir_p(target_str)
          rescue Errno::EEXIST
            raise unless File.directory?(target_str)
          end

          Dir.each_child(source_str) do |name|
            next if ignored&.include?(name)

            src = "#{source_str}/#{name}"
            dest = "#{target_str}/#{name}"
            stat = File.stat(src)
            if stat.directory?
              copy_tree_dir(src, dest, stat, ignored, seen, top: false)
            else
              copy_file(src, dest, stat)
            end
          end
        ensure
          dev_seen.delete(ino)
        end
      end
      private_class_method :copy_tree_dir

      def copy_file(src, dest, stat)
        mode = stat.mode & 0o777
        if stat.file? && stat.size <= SMALL_FILE_THRESHOLD
          data = File.binread(src)
          begin
            File.binwrite(dest, data, mode: CREATE_EXCL_MODE, perm: mode)
          rescue Errno::EEXIST
            check_not_same_file!(src, dest, stat)
            File.binwrite(dest, data, perm: mode)
          end
        else
          File.open(src, File::RDONLY | File::BINARY) do |in_f|
            begin
              File.open(dest, CREATE_EXCL_MODE, mode) { |out_f| IO.copy_stream(in_f, out_f) }
            rescue Errno::EEXIST
              check_not_same_file!(src, dest, stat)
              File.open(dest, CREATE_TRUNC_MODE, mode) { |out_f| IO.copy_stream(in_f, out_f) }
            end
          end
        end
      end

      def check_not_same_file!(src, dest, stat)
        dest_stat = begin
          File.stat(dest)
        rescue SystemCallError
          nil
        end
        if dest_stat && dest_stat.dev == stat.dev && dest_stat.ino == stat.ino
          raise ArgumentError, "same file: #{src} and #{dest}"
        end
      end
      private_class_method :check_not_same_file!
    end

    # Stage a Rails app (or one declared local-first island within a monolith)
    # for Roundhouse without touching the original checkout, and emit a
    # canonical `instant_record.manifest.json`.
    module AppStage
      STATIC_FOLDERS = %w[app/assets app/javascript config/locales].freeze

      FILES = %w[
        Gemfile config/application.rb config/routes.rb config/importmap.rb db/schema.rb
      ].freeze

      FOREIGN_KEY = /^[ \t]*add_foreign_key\s+["'](\w+)["'],\s*["'](\w+)["'].*\n?/

      StageResult = Struct.new(:manifest, :route_analysis, :trace, :overrides, keyword_init: true)

      module_function

      def analyze(source:, native: false, island: nil, overrides: nil, models: nil, migration_paths: nil, overlay_dir: nil)
        source_path = File.expand_path(source.to_s)
        route_analysis = RouteAnalyzer.analyze(source_root: source_path, island: island)
        file_config = Manifest.load_config(source_path, island: island)
        merged_overrides = Manifest.merge_overrides(file_config, route_analysis.overrides, overrides)

        trace = ReachabilityTracer.trace(
          source_root: source_path,
          route_analysis: route_analysis,
          overrides: merged_overrides,
          native: native,
          migration_paths: migration_paths,
          overlay_dir: overlay_dir
        )

        manifest_models = build_manifest_models(trace, explicit_models: models, island_mode: route_analysis.has_local_first)
        server_routes = Manifest.deduplicate_routes(route_analysis.server_routes + merged_overrides[:server_routes])

        manifest = Manifest.new(
          "schema_version" => Manifest::SCHEMA_VERSION,
          "mode" => route_analysis.has_local_first ? "island" : "full",
          "island" => route_analysis.island,
          "models" => manifest_models,
          "local_routes" => route_analysis.local_routes,
          "server_routes" => server_routes,
          "staged" => {
            "controllers" => trace.controllers,
            "models" => trace.models,
            "views" => trace.views,
            "helpers" => trace.helpers,
            "migrations" => trace.manifest_migrations,
            "screens" => trace.screens
          },
          "includes" => merged_overrides[:include],
          "diagnostics" => trace.diagnostics
        )

        StageResult.new(
          manifest: manifest,
          route_analysis: route_analysis,
          trace: trace,
          overrides: merged_overrides
        )
      end

      def stage(source:, target:, native: false, island: nil, overrides: nil, models: nil, migration_paths: nil, overlay_dir: nil, manifest_path: nil)
        src_root = File.realpath(source)
        dst_root = File.expand_path(target.to_s)
        analysis = analyze(
          source: src_root,
          native: native,
          island: island,
          overrides: overrides,
          models: models,
          migration_paths: migration_paths,
          overlay_dir: overlay_dir
        )

        remove_if_present(dst_root)
        mkdir_or_mkpath(dst_root)

        src_prefix = "#{src_root}#{File::SEPARATOR}"
        dst_prefix = "#{dst_root}#{File::SEPARATOR}"
        created_dirs = { dst_root => true }

        STATIC_FOLDERS.each do |rel|
          dir = "#{src_root}/#{rel}"
          next unless File.directory?(dir)

          dest_dir = "#{dst_root}/#{rel}"
          ensure_dir(File.dirname(dest_dir), created_dirs)
          FileCopy.copy_tree(dir, dest_dir)
          created_dirs[dest_dir] = true
        end

        has_local_first = analysis.route_analysis.has_local_first
        FILES.each do |rel|
          next if has_local_first && rel == "config/routes.rb"

          stage_file_if_present(src_root, dst_root, src_prefix, dst_prefix, rel, created_dirs)
        end

        if has_local_first
          routes_dest = "#{dst_root}/config/routes.rb"
          ensure_dir("#{dst_root}/config", created_dirs)
          File.write(routes_dest, analysis.route_analysis.local_routes_source)
        else
          routes_dir = "#{src_root}/config/routes"
          if File.directory?(routes_dir)
            ensure_dir("#{dst_root}/config", created_dirs)
            FileCopy.copy_tree(routes_dir, "#{dst_root}/config/routes")
            created_dirs["#{dst_root}/config/routes"] = true
          end
        end

        staged = {}
        trace = analysis.trace
        [
          trace.controllers,
          trace.models,
          trace.views,
          trace.helpers,
          trace.screens,
          trace.extra_files
        ].each do |group|
          group.each do |rel|
            next if staged.key?(rel)

            staged[rel] = true
            stage_file_if_present(src_root, dst_root, src_prefix, dst_prefix, rel, created_dirs)
          end
        end

        if overlay_dir && File.directory?(overlay_dir)
          FileCopy.copy_tree(overlay_dir, "#{dst_root}/app")
        end

        schema_path = "#{dst_root}/db/schema.rb"
        unless File.file?(schema_path)
          raise BuildError, "The compiled app needs db/schema.rb. Run bin/rails db:migrate and db:schema:dump first."
        end
        drop_foreign_keys_to_unsynced_tables(schema_path, analysis.manifest)

        if manifest_path
          manifest_dir = File.dirname(manifest_path.to_s)
          FileUtils.mkdir_p(manifest_dir) unless created_dirs[manifest_dir] || File.directory?(manifest_dir)
          File.write(manifest_path, analysis.manifest.to_json)
        end

        analysis
      end

      # SQLite on the device enforces foreign keys, but only synced tables are filled
      # there: a synced row that names a row of another table would be refused. The
      # server keeps every constraint.
      def drop_foreign_keys_to_unsynced_tables(schema, manifest)
        source = File.read(schema)
        return unless source.include?("add_foreign_key")

        synced = manifest.models.to_h { |entry| [entry["table"], true] }
        kept = source.gsub(FOREIGN_KEY) do |line|
          from = Regexp.last_match(1)
          to = Regexp.last_match(2)
          synced[from] && !synced[to] ? "" : line
        end
        File.write(schema, kept) unless kept == source
      end
      private_class_method :drop_foreign_keys_to_unsynced_tables

      def copy_file_if_present(source_path, target_path, rel)
        src_root = File.realpath(source_path)
        dst_root = File.expand_path(target_path.to_s)
        stage_file_if_present(
          src_root,
          dst_root,
          "#{src_root}#{File::SEPARATOR}",
          "#{dst_root}#{File::SEPARATOR}",
          rel,
          {}
        )
      end
      private_class_method :copy_file_if_present

      def stage_file_if_present(src_root, dst_root, src_prefix, dst_prefix, rel, created_dirs)
        rel_str = rel.to_s
        if File.absolute_path?(rel_str)
          raise BuildError, "Refusing to stage path outside app root: #{rel.inspect}"
        end

        path = File.expand_path(rel_str, src_root)
        dest = File.expand_path(rel_str, dst_root)
        unless path.start_with?(src_prefix) && dest.start_with?(dst_prefix)
          raise BuildError, "Refusing to stage path outside app root: #{rel.inspect}"
        end

        stat = begin
          File.stat(path)
        rescue SystemCallError
          return
        end
        return unless stat.file?

        ensure_dir(File.dirname(dest), created_dirs)
        FileCopy.copy_file(path, dest, stat)
      end
      private_class_method :stage_file_if_present

      def remove_if_present(path)
        File.lstat(path)
        FileUtils.rm_rf(path)
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end
      private_class_method :remove_if_present

      def mkdir_or_mkpath(path)
        Dir.mkdir(path)
      rescue Errno::ENOENT
        FileUtils.mkdir_p(path)
      end
      private_class_method :mkdir_or_mkpath

      def ensure_dir(dir, created_dirs)
        return if created_dirs[dir]

        begin
          Dir.mkdir(dir)
        rescue Errno::ENOENT
          parent = File.dirname(dir)
          raise if parent == dir

          ensure_dir(parent, created_dirs)
          begin
            Dir.mkdir(dir)
          rescue Errno::EEXIST
            raise unless File.directory?(dir)
          end
        rescue Errno::EEXIST
          raise unless File.directory?(dir)
        end
        created_dirs[dir] = true
      end
      private_class_method :ensure_dir

      def build_manifest_models(trace, explicit_models:, island_mode:)
        discovered = trace.model_metadata.values.select { |meta| meta["syncable"] }
        by_name = discovered.to_h { |meta| [meta["name"], format_model_entry(meta)] }

        if !island_mode && explicit_models
          Array(explicit_models).each do |name|
            by_name[name] ||= format_model_entry(
              trace.model_metadata[name] || { "name" => name, "table" => ActiveSupport::Inflector.tableize(name) }
            )
          end
        end

        by_name.keys.sort.map { |name| by_name[name] }
      end
      private_class_method :build_manifest_models

      def format_model_entry(meta)
        {
          "name" => meta["name"],
          "table" => meta["table"],
          "file" => meta["file"],
          "sync_window" => meta["sync_window"],
          "sync_scope" => meta["sync_scope"],
          "sync_file" => meta["sync_file"] == true
        }
      end
      private_class_method :format_model_entry
    end
  end
end
