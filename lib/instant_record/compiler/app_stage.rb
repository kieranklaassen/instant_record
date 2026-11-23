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
      module_function

      def copy_tree(source, target, ignore: [], visited: Set.new)
        source_path = Pathname(source)
        real = source_path.realpath
        return if visited.include?(real)

        next_visited = visited + [real]
        target_path = Pathname(target)
        FileUtils.mkdir_p(target_path)

        source_path.children.each do |entry|
          name = entry.basename.to_s
          next if ignore.include?(name)

          dest = target_path.join(name)
          if entry.directory?
            copy_tree(entry, dest, ignore: ignore, visited: next_visited)
          else
            FileUtils.cp(entry, dest)
          end
        end
      end
    end

    # Stage a Rails app (or one declared local-first island within a monolith)
    # for Roundhouse without touching the original checkout, and emit a
    # canonical `instant_record.manifest.json`.
    module AppStage
      STATIC_FOLDERS = %w[app/assets app/javascript config/locales].freeze

      FILES = %w[
        Gemfile config/application.rb config/routes.rb config/importmap.rb db/schema.rb
      ].freeze

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
        source_path = Pathname(source).realpath
        target_path = Pathname(target)
        analysis = analyze(
          source: source_path,
          native: native,
          island: island,
          overrides: overrides,
          models: models,
          migration_paths: migration_paths,
          overlay_dir: overlay_dir
        )

        FileUtils.rm_rf(target_path)
        FileUtils.mkdir_p(target_path)

        STATIC_FOLDERS.each do |rel|
          dir = source_path.join(rel)
          FileCopy.copy_tree(dir, target_path.join(rel)) if dir.directory?
        end

        static_files = analysis.route_analysis.has_local_first ? (FILES - ["config/routes.rb"]) : FILES
        static_files.each do |rel|
          copy_file_if_present(source_path, target_path, rel)
        end

        if analysis.route_analysis.has_local_first
          routes_dest = target_path.join("config/routes.rb")
          FileUtils.mkdir_p(routes_dest.dirname)
          File.write(routes_dest, analysis.route_analysis.local_routes_source)
        else
          routes_dir = source_path.join("config/routes")
          FileCopy.copy_tree(routes_dir, target_path.join("config/routes")) if routes_dir.directory?
        end

        traced_files = analysis.trace.controllers +
          analysis.trace.models +
          analysis.trace.views +
          analysis.trace.helpers +
          analysis.trace.screens +
          analysis.trace.extra_files

        traced_files.uniq.each do |rel|
          copy_file_if_present(source_path, target_path, rel)
        end

        if overlay_dir && File.directory?(overlay_dir)
          FileCopy.copy_tree(overlay_dir, target_path.join("app"))
        end

        unless target_path.join("db/schema.rb").file?
          raise BuildError, "The compiled app needs db/schema.rb. Run bin/rails db:migrate and db:schema:dump first."
        end

        if manifest_path
          FileUtils.mkdir_p(File.dirname(manifest_path))
          File.write(manifest_path, analysis.manifest.to_json)
        end

        analysis
      end

      def copy_file_if_present(source_path, target_path, rel)
        src_root = source_path.realpath.to_s
        dst_root = File.expand_path(target_path.to_s)
        path = File.expand_path(rel.to_s, src_root)
        dest = File.expand_path(rel.to_s, dst_root)
        unless path.start_with?("#{src_root}#{File::SEPARATOR}") && dest.start_with?("#{dst_root}#{File::SEPARATOR}")
          raise BuildError, "Refusing to stage path outside app root: #{rel.inspect}"
        end
        return unless File.file?(path)

        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(path, dest)
      end
      private_class_method :copy_file_if_present

      def build_manifest_models(trace, explicit_models:, island_mode:)
        discovered = trace.model_metadata.values.select { |meta| meta["syncable"] }
        by_name = discovered.each_with_object({}) do |meta, hash|
          hash[meta["name"]] = format_model_entry(meta)
        end

        if !island_mode && explicit_models
          Array(explicit_models).each do |name|
            next if by_name.key?(name)

            meta = trace.model_metadata[name]
            by_name[name] = meta ? format_model_entry(meta) : {
              "name" => name,
              "table" => ActiveSupport::Inflector.tableize(name),
              "file" => nil,
              "sync_window" => nil,
              "sync_scope" => nil,
              "sync_file" => false
            }
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
