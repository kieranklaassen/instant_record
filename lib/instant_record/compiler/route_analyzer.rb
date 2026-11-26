require "active_support/inflector"
require "prism"
require_relative "manifest"
require_relative "runner"

module InstantRecord
  class Compiler
    # Static Prism parser for config/routes.rb (and draw'n config/routes/*.rb).
    # Extracts local_first route subtrees, server routes, inline include overrides,
    # and emits a rewritten local-only config/routes.rb without executing app Ruby.
    class RouteAnalyzer
      HTTP_VERBS = %i[get post put patch delete].freeze
      CONTAINER_CALLS = %i[namespace scope resources resource member collection constraints defaults].freeze

      RESOURCE_ROUTES = [
        ["index", "GET", :collection, ""],
        ["new", "GET", :collection, "/new"],
        ["create", "POST", :collection, ""],
        ["show", "GET", :member, ""],
        ["edit", "GET", :member, "/edit"],
        ["update", "PATCH", :member, ""],
        ["update", "PUT", :member, ""],
        ["destroy", "DELETE", :member, ""]
      ].freeze
      PLURAL_ACTIONS = RESOURCE_ROUTES.map(&:first).uniq.freeze
      SINGULAR_ACTIONS = (PLURAL_ACTIONS - ["index"]).freeze

      Result = Struct.new(
        :has_local_first,
        :island,
        :declared_islands,
        :local_routes,
        :server_routes,
        :overrides,
        :local_routes_source,
        keyword_init: true
      )

      Context = Struct.new(
        :path_prefix,
        :module_prefix,
        :controller,
        :in_local_first,
        :island_name,
        :resource_member_prefix,
        :resource_collection_prefix,
        :resource_controller,
        :active_draws,
        keyword_init: true
      ) do
        def with(**changes)
          self.class.new(**to_h, **changes)
        end
      end

      def self.analyze(source_root:, island: nil)
        new(source_root: source_root, island: island).analyze
      end

      def initialize(source_root:, island: nil)
        @source_root = File.expand_path(source_root.to_s)
        @island = island.nil? || island.to_s.empty? ? nil : island.to_s
        @has_local_first = false
        @declared_islands = []
        @local_routes = []
        @server_routes = []
        @overrides = Manifest.normalize_overrides(nil)
        @drawn_statements = {}
      end

      def analyze
        body = routes_body
        walk_statements(body, Context.new(path_prefix: "", in_local_first: false, active_draws: []))
        check_island_declared!

        if @has_local_first
          local = @local_routes
          server = @server_routes + @overrides[:server_routes]
          local_source = "Rails.application.routes.draw do\n#{indent_lines(emit_statements(body, false), 2)}end\n"
        else
          # Whole-app fallback mode: all non-internal routes are local routes.
          local = @server_routes
          server = @overrides[:server_routes]
        end

        Result.new(
          has_local_first: @has_local_first,
          island: @island,
          declared_islands: @declared_islands.uniq.sort,
          local_routes: Manifest.deduplicate_routes(local),
          server_routes: Manifest.deduplicate_routes(server),
          overrides: @overrides,
          local_routes_source: local_source
        )
      end

      private

      def routes_body
        routes_path = File.join(@source_root, "config/routes.rb")
        unless File.file?(routes_path)
          raise BuildError, "Missing config/routes.rb in #{@source_root}" if @island

          return []
        end

        statements = parse_ruby!(File.read(routes_path), routes_path)
        draw_call = statements.find { |stmt| stmt.is_a?(Prism::CallNode) && stmt.name == :draw && stmt.block }
        draw_call ? statements_of(draw_call.block.body) : statements
      end

      def check_island_declared!
        return if @island.nil? || @declared_islands.include?(@island)

        available = @declared_islands.empty? ? "none declared" : @declared_islands.uniq.sort.join(", ")
        raise BuildError, "Unknown local_first island #{@island.inspect} in config/routes.rb (declared islands: #{available})."
      end

      def parse_ruby!(source, path)
        parsed = Prism.parse(source)
        unless parsed.success?
          errors = parsed.errors.map { |e| "line #{e.location.start_line}: #{e.message}" }.join("; ")
          raise BuildError, "Syntax error parsing #{path}: #{errors}"
        end
        statements_of(parsed.value.statements)
      end

      def statements_of(node)
        return [] unless node

        node.is_a?(Prism::StatementsNode) ? node.body : [node]
      end

      def walk_statements(stmts, ctx)
        stmts.each { |stmt| walk_node(stmt, ctx) }
      end

      def walk_block(node, ctx)
        walk_statements(statements_of(node.block.body), ctx) if node.block
      end

      def walk_node(node, ctx)
        return unless node.is_a?(Prism::CallNode) && node.receiver.nil?

        # mount is left out: a server-side engine (e.g. InstantRecord::Engine) is not a local controller.
        case node.name
        when :local_first then walk_local_first(node, ctx)
        when :draw then walk_draw(node, ctx)
        when :namespace then walk_namespace(node, ctx)
        when :scope then walk_scope(node, ctx)
        when :resources then walk_resources(node, ctx, singular: false)
        when :resource then walk_resources(node, ctx, singular: true)
        when :member, :collection then walk_block(node, resource_context(ctx, node.name))
        when :constraints, :defaults then walk_block(node, ctx)
        when :root then record_root(node, ctx)
        when *HTTP_VERBS then record_http_verb(node, ctx, [node.name.to_s.upcase])
        when :match then record_match(node, ctx)
        end
      end

      def walk_local_first(node, ctx)
        @has_local_first = true
        _, opts = extract_args(node)
        declared_name = declared_island(node)
        @declared_islands << declared_name if declared_name

        active = active_island?(declared_name)
        @overrides = Manifest.merge_overrides(@overrides, Manifest.normalize_overrides(opts)) if active

        walk_block(node, ctx.with(in_local_first: active, island_name: declared_name || ctx.island_name))
      end

      def declared_island(node)
        pos, = extract_args(node)
        pos.first.to_s if pos.first
      end

      def active_island?(declared_name)
        @island.nil? || declared_name == @island
      end

      def walk_draw(node, ctx)
        name = first_name(node)
        return unless name

        sub_path = resolve_draw_path!(name)
        raise BuildError, "Cyclic route draw detected for config/routes/#{name}.rb" if ctx.active_draws.include?(sub_path)

        walk_statements(drawn_statements(sub_path), ctx.with(active_draws: ctx.active_draws + [sub_path]))
      end

      def resolve_draw_path!(name)
        routes_dir = File.expand_path(File.join(@source_root, "config/routes"))
        sub_path = File.expand_path("#{name}.rb", routes_dir)
        unless sub_path.start_with?("#{routes_dir}#{File::SEPARATOR}")
          raise BuildError, "Invalid route draw name #{name.inspect}: escapes config/routes/"
        end
        unless File.file?(sub_path)
          raise BuildError, "Route file config/routes/#{name}.rb referenced by draw(:#{name}) does not exist"
        end
        sub_path
      end

      def drawn_statements(sub_path)
        @drawn_statements[sub_path] ||= parse_ruby!(File.read(sub_path), sub_path)
      end

      def walk_namespace(node, ctx)
        name = first_name(node)
        return unless name && node.block

        _, opts = extract_args(node)
        walk_block(node, scoped_context(ctx, opts, path: opts.fetch(:path, name), mod: opts.fetch(:module, name)))
      end

      def walk_scope(node, ctx)
        return unless node.block

        pos, opts = extract_args(node)
        walk_block(node, scoped_context(ctx, opts, path: opts.fetch(:path, pos.first), mod: opts[:module]))
      end

      def scoped_context(ctx, opts, path:, mod:)
        module_prefix = join_module(ctx.module_prefix, mod)
        controller = opts[:controller] ? qualify_controller(opts[:controller].to_s, module_prefix) : ctx.controller
        ctx.with(path_prefix: join_path(ctx.path_prefix, path), module_prefix: module_prefix, controller: controller)
      end

      def walk_resources(node, ctx, singular:)
        pos, opts = extract_args(node)
        return if pos.empty?

        actions = filter_actions(singular ? SINGULAR_ACTIONS : PLURAL_ACTIONS, only: opts[:only], except: opts[:except])
        module_prefix = opts[:module] ? join_module(ctx.module_prefix, opts[:module]) : ctx.module_prefix

        pos.map(&:to_s).each do |name|
          base = join_path(ctx.path_prefix, opts.fetch(:path, name))
          controller = opts[:controller] || (singular ? ActiveSupport::Inflector.pluralize(name) : name)
          controller = qualify_controller(controller.to_s, module_prefix)

          param = opts[:param] || "id"
          member = singular ? base : "#{base}/:#{param}"
          record_resource_routes(base, member, controller, actions, ctx)

          nested = singular ? base : "#{base}/:#{ActiveSupport::Inflector.singularize(name)}_#{param}"
          walk_block(node, ctx.with(
            path_prefix: nested,
            module_prefix: module_prefix,
            controller: controller,
            resource_member_prefix: member,
            resource_collection_prefix: base,
            resource_controller: controller
          ))
        end
      end

      def record_resource_routes(base, member, controller, actions, ctx)
        RESOURCE_ROUTES.each do |action, verb, on, suffix|
          next unless actions.include?(action)

          record_route(verb, "#{on == :member ? member : base}#{suffix}", controller, action, ctx)
        end
      end

      def resource_context(ctx, on)
        prefix =
          case on
          when :member then ctx.resource_member_prefix
          when :collection then ctx.resource_collection_prefix
          else return ctx
          end

        ctx.with(path_prefix: prefix || ctx.path_prefix, controller: ctx.resource_controller || ctx.controller)
      end

      def record_root(node, ctx)
        pos, opts = extract_args(node)
        target = (opts[:to] || pos.first)&.to_s
        return unless target

        controller, action = split_target(target, ctx)
        path = ctx.path_prefix.empty? ? "/" : ctx.path_prefix
        record_route("GET", path, controller, action, ctx)
      end

      def record_http_verb(node, ctx, verbs)
        pos, opts, string_mapping = extract_args_and_mapping(node)
        raw_path, raw_target = string_mapping || [pos.first&.to_s, opts[:to]&.to_s]
        return unless raw_path

        on_ctx = resource_context(ctx, opts[:on]&.to_sym)
        path = join_path(on_ctx.path_prefix, raw_path)
        controller, action =
          raw_target ? split_target(raw_target, ctx) : infer_endpoint(raw_path, opts, on_ctx)

        verbs.each { |verb| record_route(verb, path, controller, action, ctx) }
      end

      def infer_endpoint(raw_path, opts, ctx)
        # Dynamic `to:` (e.g. redirect("/new") or Rack app): keep the route path without guessing a controller.
        return [nil, nil] if opts.key?(:to)

        if opts[:controller] || opts[:action]
          controller = opts[:controller] ? qualify_controller(opts[:controller].to_s, ctx.module_prefix) : ctx.controller
          [controller, (opts[:action] || raw_path.split("/").last).to_s]
        elsif ctx.controller
          [ctx.controller, raw_path.delete_prefix("/").tr("-", "_")]
        elsif raw_path.include?("/")
          *parts, action = raw_path.delete_prefix("/").split("/")
          [qualify_controller(parts.join("/"), ctx.module_prefix), action]
        else
          [nil, nil]
        end
      end

      def record_match(node, ctx)
        _, opts = extract_args(node)
        via = opts[:via]
        verbs =
          case via
          when Array then via.map { |v| v.to_s.upcase }
          when Symbol, String
            via.to_s == "all" ? %w[GET POST PATCH PUT DELETE OPTIONS] : [via.to_s.upcase]
          else
            %w[GET POST]
          end
        record_http_verb(node, ctx, verbs)
      end

      def record_route(method_name, path, controller, action, ctx)
        # Skip Rails internal framework endpoints (e.g. rails/health, rails/pwa).
        return if controller&.start_with?("rails/")

        entry = {
          "method" => method_name,
          "path" => Manifest.normalize_route_path(path),
          "controller" => controller,
          "action" => action
        }
        entry["island"] = ctx.island_name if ctx.in_local_first && ctx.island_name

        (ctx.in_local_first ? @local_routes : @server_routes) << entry
      end

      # --- AST-preserving local config/routes.rb emitter ---

      def emit_statements(stmts, local)
        stmts.flat_map { |stmt| emit_node(stmt, local) }
      end

      def emit_node(node, local)
        return [] unless node.is_a?(Prism::CallNode) && node.receiver.nil?

        case node.name
        when :local_first
          return [] unless active_island?(declared_island(node)) && node.block

          emit_statements(statements_of(node.block.body), true)
        when :draw
          name = first_name(node)
          name ? emit_statements(drawn_statements(resolve_draw_path!(name)), local) : []
        when *CONTAINER_CALLS
          node.block ? emit_container(node, local) : emit_call(node, local)
        when :root, *HTTP_VERBS, :match
          emit_call(node, local)
        else
          []
        end
      end

      def emit_call(node, local)
        local ? reindent_slice(node.location.slice) : []
      end

      def emit_container(node, local)
        inner = emit_statements(statements_of(node.block.body), local)
        return [] if inner.empty? && !local
        return emit_call(node, local) if local && !subtree_has_special_calls?(node.block.body)

        [container_header(node), *inner.map { |line| "  #{line}" }, node.block.closing_loc.slice]
      end

      def subtree_has_special_calls?(node)
        return false unless node

        !node.breadth_first_search { |child|
          child.is_a?(Prism::CallNode) && child.receiver.nil? && %i[local_first draw].include?(child.name)
        }.nil?
      end

      def container_header(node)
        header_end = (node.block.parameters&.location || node.block.opening_loc).end_offset
        node.location.slice[0...(header_end - node.location.start_offset)].strip
      end

      def reindent_slice(slice)
        lines = slice.lines(chomp: true)
        return [] if lines.empty?

        # First line starts at the AST node column; trim common indent of subsequent lines.
        first = lines.first.lstrip
        rest = lines[1..]
        return [first] if rest.empty?

        non_empty = rest.reject { |l| l.strip.empty? }
        min_indent = non_empty.map { |l| l[/\A */].length }.min || 0
        [first, *rest.map { |l| l.strip.empty? ? "" : l[min_indent..] }]
      end

      def indent_lines(lines, spaces)
        prefix = " " * spaces
        lines.map { |line| line.empty? ? "\n" : "#{prefix}#{line}\n" }.join
      end

      # --- Helpers ---

      def split_target(target, ctx)
        if target.include?("#")
          ctrl, action = target.split("#", 2)
          [qualify_controller(ctrl, ctx.module_prefix), action]
        else
          [ctx.controller, target]
        end
      end

      def qualify_controller(controller, module_prefix)
        return controller.delete_prefix("/") if controller.start_with?("/")
        return controller if module_prefix.nil? || module_prefix.empty?
        return controller if controller.start_with?("#{module_prefix}/")

        "#{module_prefix}/#{controller}"
      end

      def join_path(prefix, segment)
        seg = segment.to_s.delete_prefix("/")
        return prefix if seg.empty?

        prefix.to_s.empty? ? "/#{seg}" : "#{prefix.delete_suffix("/")}/#{seg}"
      end

      def join_module(prefix, segment)
        seg = segment.to_s.delete_prefix("/").delete_suffix("/")
        return prefix if seg.empty?

        prefix.to_s.empty? ? seg : "#{prefix}/#{seg}"
      end

      def filter_actions(defaults, only:, except:)
        list = defaults.dup
        if only
          allowed = Array(only).map(&:to_s)
          list &= allowed
        end
        if except
          denied = Array(except).map(&:to_s)
          list -= denied
        end
        list
      end

      ROUTE_OPTION_KEYS = %i[to controller action via as on only except path module param constraints defaults format].freeze

      def first_name(call)
        pos, = extract_args(call)
        pos.first&.to_s
      end

      def extract_args(call)
        pos, pairs = split_args(call)
        [pos, options_from(pairs)]
      end

      def extract_args_and_mapping(call)
        pos, pairs = split_args(call)
        mapping = pairs.find { |key, value| string_mapping?(key, value) }
        [pos, options_from(pairs.reject { |pair| pair.equal?(mapping) }), mapping && [mapping[0].to_s, mapping[1]]]
      end

      def string_mapping?(key, value)
        return false unless value.is_a?(String) && value.include?("#")

        key.is_a?(String) || (key.is_a?(Symbol) && !ROUTE_OPTION_KEYS.include?(key))
      end

      def split_args(call)
        hashes, positional = Array(call.arguments&.arguments).partition { |arg| hash_node?(arg) }
        [positional.map { |arg| literal_value(arg) }, hashes.flat_map { |hash| literal_pairs(hash) }]
      end

      def hash_node?(node)
        node.is_a?(Prism::KeywordHashNode) || node.is_a?(Prism::HashNode)
      end

      def literal_pairs(hash_node)
        hash_node.elements.grep(Prism::AssocNode).map { |assoc| [literal_value(assoc.key), literal_value(assoc.value)] }
      end

      def options_from(pairs)
        pairs.each_with_object({}) do |(key, value), opts|
          opts[key.to_sym] = value if key.is_a?(Symbol) || key.is_a?(String)
        end
      end

      def literal_value(node)
        case node
        when Prism::SymbolNode then node.unescaped.to_sym
        when Prism::StringNode then node.unescaped
        when Prism::IntegerNode, Prism::FloatNode then node.value
        when Prism::TrueNode then true
        when Prism::FalseNode then false
        when Prism::NilNode then nil
        when Prism::ArrayNode then node.elements.map { |el| literal_value(el) }
        when Prism::HashNode, Prism::KeywordHashNode
          # A value is read only under a literal key.
          node.elements.grep(Prism::AssocNode).each_with_object({}) do |assoc, hash|
            key = literal_value(assoc.key)
            hash[key] = literal_value(assoc.value) unless key.nil?
          end
        end
      end
    end
  end
end
