# frozen_string_literal: true

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
        parsed = JSON.parse(json_text)
        raise BuildError, "Manifest JSON must be a JSON object" unless parsed.is_a?(Hash)

        new(parsed)
      rescue JSON::ParserError => e
        raise BuildError, "Invalid manifest JSON: #{e.message}"
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

        raw = YAML.safe_load_file(path, permitted_classes: [Symbol])
        raw = {} if raw.nil?
        raise BuildError, "#{CONFIG_FILE} must be a YAML mapping" unless raw.is_a?(Hash)

        base = normalize_overrides(raw)
        if island
          islands =
            if raw.key?("islands") && !raw["islands"].nil?
              raw["islands"]
            elsif raw.key?(:islands)
              raw[:islands]
            end

          unless islands.nil?
            raise BuildError, "#{CONFIG_FILE} islands must be a YAML mapping" unless islands.is_a?(Hash)

            island_key = island.to_s
            island_sym = island.to_sym
            island_section =
              if islands.key?(island_key) && !islands[island_key].nil?
                islands[island_key]
              elsif islands.key?(island_sym)
                islands[island_sym]
              end

            unless island_section.nil?
              unless island_section.is_a?(Hash)
                raise BuildError, "#{CONFIG_FILE} islands.#{island_key} must be a YAML mapping"
              end

              base = merge_overrides(base, normalize_overrides(island_section))
            end
          end
        end
        base
      rescue Psych::Exception => e
        raise BuildError, "Invalid YAML in #{CONFIG_FILE}: #{e.message}"
      end

      def self.normalize_overrides(raw)
        result = { include: empty_includes, server_routes: [] }
        return result unless raw.is_a?(Hash)

        explicit_inc =
          if raw.key?("include") && !raw["include"].nil?
            raw["include"]
          elsif raw.key?(:include)
            raw[:include]
          end

        if !explicit_inc.nil? && !explicit_inc.is_a?(Hash)
          raise BuildError, "include overrides must be a mapping (got #{explicit_inc.class})"
        end

        inc = explicit_inc
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
        return [] if routes.is_a?(Array) && routes.empty?

        seen_by_method = {}
        acc = []
        routes.each do |route|
          method_seen = (seen_by_method[route["method"]] ||= {})
          path = route["path"]
          next if method_seen[path]

          method_seen[path] = true
          acc << route
        end
        acc
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
        if path.is_a?(String) && path.encoding.ascii_compatible?
          len = path.bytesize
          if len == 1 && path.getbyte(0) == 47
            return "/"
          elsif len > 1 && path.getbyte(0) == 47
            last = path.getbyte(-1)
            return path if last > 32 && last != 47 && !path.include?("//")
          end
        end

        cleaned = path.to_s.strip
        cleaned = "/#{cleaned}" unless cleaned.start_with?("/")
        cleaned = cleaned.squeeze("/") if cleaned.include?("//")
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
