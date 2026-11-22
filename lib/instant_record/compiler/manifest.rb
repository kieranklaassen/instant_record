require "json"
require "yaml"
require_relative "runner"

module InstantRecord
  class Compiler
    # Canonical manifest (`instant_record.manifest.json`) emitted during staging
    # and consumed by EntryBuilder, WasmBuild, NativeBuild, worker.js, and main.js.
    class Manifest
      SCHEMA_VERSION = 1
      FILENAME = "instant_record.manifest.json".freeze
      CONFIG_FILE = "config/instant_record.yml".freeze
      INCLUDE_KEYS = %w[models controllers views partials helpers migrations files].freeze

      attr_reader :data

      def self.from_json(json_text)
        new(JSON.parse(json_text))
      end

      def self.read(path)
        from_json(File.read(path))
      end

      def self.empty_includes
        INCLUDE_KEYS.to_h { |key| [key, []] }
      end

      # Load optional declarative overrides from config/instant_record.yml.
      def self.load_config(source_root, island: nil)
        path = File.join(source_root.to_s, CONFIG_FILE)
        return { include: empty_includes, server_routes: [] } unless File.file?(path)

        raw = YAML.safe_load_file(path, permitted_classes: [Symbol]) || {}
        raise BuildError, "#{CONFIG_FILE} must be a YAML mapping" unless raw.is_a?(Hash)

        base = normalize_overrides(raw)
        if island && raw["islands"].is_a?(Hash)
          island_section = raw["islands"][island.to_s] || raw["islands"][island.to_sym]
          base = merge_overrides(base, normalize_overrides(island_section)) if island_section.is_a?(Hash)
        end
        base
      rescue Psych::SyntaxError => e
        raise BuildError, "Invalid YAML in #{CONFIG_FILE}: #{e.message}"
      end

      def self.normalize_overrides(raw)
        result = { include: empty_includes, server_routes: [] }
        return result unless raw.is_a?(Hash)

        inc = raw["include"] || raw[:include]
        if inc.nil? && (raw.keys.map(&:to_s) & INCLUDE_KEYS).any?
          inc = raw
        end

        if inc.is_a?(Hash)
          INCLUDE_KEYS.each do |key|
            values = inc[key] || inc[key.to_sym]
            result[:include][key] = Array(values).map(&:to_s).reject(&:empty?).uniq
          end
        end

        routes = raw["server_routes"] || raw[:server_routes]
        if routes
          result[:server_routes] = Array(routes).map { |spec| parse_server_route_spec(spec) }
        end

        result
      end

      def self.merge_overrides(*list)
        merged = { include: empty_includes, server_routes: [] }
        list.compact.each do |entry|
          norm = normalize_overrides(entry)
          INCLUDE_KEYS.each do |key|
            merged[:include][key] = (merged[:include][key] + Array(norm[:include][key])).uniq
          end
          merged[:server_routes] = deduplicate_routes(merged[:server_routes] + Array(norm[:server_routes]))
        end
        merged
      end

      def self.deduplicate_routes(routes)
        seen = {}
        routes.each_with_object([]) do |route, acc|
          key = [route["method"], route["path"]]
          next if seen[key]

          seen[key] = true
          acc << route
        end
      end

      def self.parse_server_route_spec(spec)
        case spec
        when String
          trimmed = spec.strip
          raise BuildError, "server_routes entry must not be blank" if trimmed.empty?

          parts = trimmed.split(/\s+/, 2)
          if parts.length == 2
            method_name, path = parts
          else
            method_name = "GET"
            path = parts.first
          end
          {
            "method" => method_name.upcase,
            "path" => normalize_route_path(path),
            "controller" => nil,
            "action" => nil
          }
        when Hash
          method_name = (spec["method"] || spec[:method] || "GET").to_s.upcase
          path = (spec["path"] || spec[:path]).to_s.strip
          raise BuildError, "server_routes entry must include a path: #{spec.inspect}" if path.empty?

          {
            "method" => method_name,
            "path" => normalize_route_path(path),
            "controller" => (spec["controller"] || spec[:controller])&.to_s,
            "action" => (spec["action"] || spec[:action])&.to_s
          }
        else
          raise BuildError, "Unsupported server_routes entry: #{spec.inspect}"
        end
      end

      def self.normalize_route_path(path)
        cleaned = path.to_s.strip
        cleaned = "/#{cleaned}" unless cleaned.start_with?("/")
        cleaned = cleaned.gsub(%r{/+}, "/")
        cleaned.length > 1 ? cleaned.delete_suffix("/") : cleaned
      end

      def initialize(data)
        @data = data
      end

      def schema_version = @data["schema_version"]
      def mode = @data["mode"]
      def island = @data["island"]
      def island? = mode == "island"
      def models = Array(@data["models"])
      def local_routes = Array(@data["local_routes"])
      def server_routes = Array(@data["server_routes"])
      def staged = @data["staged"] || {}
      def includes = @data["includes"] || {}
      def diagnostics = Array(@data["diagnostics"])

      def synced_model_names
        models.map { |entry| entry["name"] }
      end

      def sync_windows
        models.each_with_object({}) do |entry, map|
          map[entry["name"]] = entry["sync_window"] if entry["sync_window"]
        end
      end

      def sync_scopes
        models.each_with_object({}) do |entry, map|
          map[entry["name"]] = entry["sync_scope"] if entry["sync_scope"]
        end
      end

      def to_h = @data

      def to_json(pretty: true)
        pretty ? "#{JSON.pretty_generate(@data)}\n" : JSON.generate(@data)
      end

      def to_compact_json
        JSON.generate(@data)
      end
    end
  end
end
