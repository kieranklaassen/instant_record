require "active_support/inflector"
require "prism"
require "set"
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
      PLURAL_ACTIONS = %w[index new create show edit update destroy].freeze
      SINGULAR_ACTIONS = %w[new create show edit update destroy].freeze

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
        keyword_init: true
      )

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
        @drawn_asts = {}
      end

      def analyze
        routes_path = File.join(@source_root, "config/routes.rb")
        unless File.file?(routes_path)
          raise BuildError, "Missing config/routes.rb in #{@source_root}" if @island

          return Result.new(
            has_local_first: false,
            declared_islands: [],
            local_routes: [],
            server_routes: [],
            overrides: @overrides,
            local_routes_source: nil
          )
        end

        source = File.read(routes_path)
        parsed = parse_ruby!(source, routes_path)
        draw_call = find_routes_draw(parsed.value)
        body = draw_call ? statements_of(draw_call.block&.body) : statements_of(parsed.value.statements)

        root_ctx = Context.new(
          path_prefix: "",
          module_prefix: nil,
          controller: nil,
          in_local_first: false,
          island_name: nil
        )

        walk_statements(body, root_ctx)

        if @island && !@declared_islands.include?(@island)
          available = @declared_islands.empty? ? "none declared" : @declared_islands.uniq.sort.join(", ")
          raise BuildError, "Unknown local_first island #{@island.inspect} in config/routes.rb (declared islands: #{available})."
        end

        if @has_local_first
          emitted_lines = emit_statements(body, root_ctx)
          local_source = "Rails.application.routes.draw do\n#{indent_lines(emitted_lines, 2)}end\n"
          local = Manifest.deduplicate_routes(@local_routes)
          server = Manifest.deduplicate_routes(@server_routes + @overrides[:server_routes])
        else
          # Whole-app fallback mode: all non-internal routes are local routes.
          local = Manifest.deduplicate_routes(@server_routes)
          server = Manifest.deduplicate_routes(@overrides[:server_routes])
          local_source = nil
        end

        Result.new(
          has_local_first: @has_local_first,
          island: @island,
          declared_islands: @declared_islands.uniq.sort,
          local_routes: local,
          server_routes: server,
          overrides: @overrides,
          local_routes_source: local_source
        )
      end

      private

      def parse_ruby!(source, path)
        parsed = Prism.parse(source)
        unless parsed.success?
          errors = parsed.errors.map { |e| "line #{e.location.start_line}: #{e.message}" }.join("; ")
          raise BuildError, "Syntax error parsing #{path}: #{errors}"
        end
        parsed
      end

      def find_routes_draw(program)
        statements_of(program.statements).each do |stmt|
          next unless stmt.is_a?(Prism::CallNode) && stmt.name == :draw && stmt.block

          return stmt
        end
        nil
      end

      def statements_of(node)
        return [] unless node

        node.is_a?(Prism::StatementsNode) ? node.body : [node]
      end

      def walk_statements(stmts, ctx, active_draws = Set.new)
        stmts.each { |stmt| walk_node(stmt, ctx, active_draws) }
      end

      def walk_node(node, ctx, active_draws = Set.new)
        return unless node.is_a?(Prism::CallNode) && node.receiver.nil?

        case node.name
        when :local_first
          walk_local_first(node, ctx, active_draws)
        when :draw
          walk_draw(node, ctx, active_draws)
        when :namespace
          walk_namespace(node, ctx, active_draws)
        when :scope
          walk_scope(node, ctx, active_draws)
        when :resources
          walk_resources(node, ctx, singular: false, active_draws: active_draws)
        when :resource
          walk_resources(node, ctx, singular: true, active_draws: active_draws)
        when :member
          walk_member_or_collection(node, ctx, member: true, active_draws: active_draws)
        when :collection
          walk_member_or_collection(node, ctx, member: false, active_draws: active_draws)
        when :constraints, :defaults
          walk_statements(statements_of(node.block&.body), ctx, active_draws) if node.block
        when :root
          record_root(node, ctx)
        when *HTTP_VERBS
          record_http_verb(node, ctx, [node.name.to_s.upcase])
        when :match
          record_match(node, ctx)
        when :mount
          # Server-side engine mount (e.g. InstantRecord::Engine); not a local controller.
          nil
        end
      end

      def walk_local_first(node, ctx, active_draws = Set.new)
        @has_local_first = true
        pos, opts = extract_args(node)
        declared_name = pos.first ? pos.first.to_s : nil
        @declared_islands << declared_name if declared_name

        active = @island.nil? || declared_name == @island
        if active
          inline_overrides = Manifest.normalize_overrides(opts)
          @overrides = Manifest.merge_overrides(@overrides, inline_overrides)
        end

        child_ctx = ctx.dup
        child_ctx.in_local_first = active
        child_ctx.island_name = declared_name || ctx.island_name
        walk_statements(statements_of(node.block&.body), child_ctx, active_draws) if node.block
      end

      def walk_draw(node, ctx, active_draws = Set.new)
        pos, = extract_args(node)
        name = pos.first&.to_s
        return unless name

        sub_path = resolve_draw_path!(name)
        raise BuildError, "Cyclic route draw detected for config/routes/#{name}.rb" if active_draws.include?(sub_path)

        parsed = load_drawn_ast!(sub_path)
        walk_statements(statements_of(parsed.value.statements), ctx, active_draws + [sub_path])
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

      def load_drawn_ast!(sub_path)
        @drawn_asts[sub_path] ||= parse_ruby!(File.read(sub_path), sub_path)
      end

      def walk_namespace(node, ctx, active_draws = Set.new)
        pos, opts = extract_args(node)
        name = pos.first&.to_s
        return unless name && node.block

        path_seg = opts.key?(:path) ? opts[:path]&.to_s : name
        mod_seg = opts.key?(:module) ? opts[:module]&.to_s : name

        child_ctx = ctx.dup
        child_ctx.path_prefix = join_path(ctx.path_prefix, path_seg) if path_seg && !path_seg.empty?
        child_ctx.module_prefix = join_module(ctx.module_prefix, mod_seg) if mod_seg && !mod_seg.empty?
        child_ctx.controller = qualify_controller(opts[:controller].to_s, child_ctx.module_prefix) if opts[:controller]
        walk_statements(statements_of(node.block.body), child_ctx, active_draws)
      end

      def walk_scope(node, ctx, active_draws = Set.new)
        return unless node.block

        pos, opts = extract_args(node)
        path_seg = opts.key?(:path) ? opts[:path]&.to_s : pos.first&.to_s
        mod_seg = opts[:module]&.to_s

        child_ctx = ctx.dup
        child_ctx.path_prefix = join_path(ctx.path_prefix, path_seg) if path_seg && !path_seg.empty?
        child_ctx.module_prefix = join_module(ctx.module_prefix, mod_seg) if mod_seg && !mod_seg.empty?
        child_ctx.controller = qualify_controller(opts[:controller].to_s, child_ctx.module_prefix) if opts[:controller]
        walk_statements(statements_of(node.block.body), child_ctx, active_draws)
      end

      def walk_resources(node, ctx, singular:, active_draws: Set.new)
        pos, opts = extract_args(node)
        names = pos.map(&:to_s)
        return if names.empty?

        default_actions = singular ? SINGULAR_ACTIONS : PLURAL_ACTIONS
        actions = filter_actions(default_actions, only: opts[:only], except: opts[:except])

        names.each do |name|
          path_seg = opts.key?(:path) ? opts[:path]&.to_s : name
          base_path = join_path(ctx.path_prefix, path_seg)
          controller = resolve_resource_controller(name, opts, ctx, singular: singular)
          param = (opts[:param] || "id").to_s

          if singular
            emit_singular_resource_routes(base_path, controller, actions, ctx)
            member_prefix = base_path
            nested_prefix = base_path
          else
            emit_plural_resource_routes(base_path, param, controller, actions, ctx)
            member_prefix = "#{base_path}/:#{param}"
            nested_prefix = "#{base_path}/:#{ActiveSupport::Inflector.singularize(name)}_#{param}"
          end

          next unless node.block

          child_ctx = ctx.dup
          child_ctx.path_prefix = nested_prefix
          child_ctx.module_prefix = join_module(ctx.module_prefix, opts[:module].to_s) if opts[:module]
          child_ctx.controller = controller
          child_ctx.resource_member_prefix = member_prefix
          child_ctx.resource_collection_prefix = base_path
          child_ctx.resource_controller = controller
          walk_statements(statements_of(node.block.body), child_ctx, active_draws)
        end
      end

      def walk_member_or_collection(node, ctx, member:, active_draws: Set.new)
        return unless node.block

        child_ctx = ctx.dup
        child_ctx.path_prefix = member ? (ctx.resource_member_prefix || ctx.path_prefix) : (ctx.resource_collection_prefix || ctx.path_prefix)
        child_ctx.controller = ctx.resource_controller || ctx.controller
        walk_statements(statements_of(node.block.body), child_ctx, active_draws)
      end

      def emit_plural_resource_routes(base, param, controller, actions, ctx)
        member = "#{base}/:#{param}"
        record_route("GET", base, controller, "index", ctx) if actions.include?("index")
        record_route("GET", "#{base}/new", controller, "new", ctx) if actions.include?("new")
        record_route("POST", base, controller, "create", ctx) if actions.include?("create")
        record_route("GET", member, controller, "show", ctx) if actions.include?("show")
        record_route("GET", "#{member}/edit", controller, "edit", ctx) if actions.include?("edit")
        if actions.include?("update")
          record_route("PATCH", member, controller, "update", ctx)
          record_route("PUT", member, controller, "update", ctx)
        end
        record_route("DELETE", member, controller, "destroy", ctx) if actions.include?("destroy")
      end

      def emit_singular_resource_routes(base, controller, actions, ctx)
        record_route("GET", "#{base}/new", controller, "new", ctx) if actions.include?("new")
        record_route("POST", base, controller, "create", ctx) if actions.include?("create")
        record_route("GET", base, controller, "show", ctx) if actions.include?("show")
        record_route("GET", "#{base}/edit", controller, "edit", ctx) if actions.include?("edit")
        if actions.include?("update")
          record_route("PATCH", base, controller, "update", ctx)
          record_route("PUT", base, controller, "update", ctx)
        end
        record_route("DELETE", base, controller, "destroy", ctx) if actions.include?("destroy")
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
        pos, opts, string_mapping = extract_args(node, include_string_mapping: true)
        if string_mapping
          raw_path, raw_target = string_mapping
        else
          raw_path = pos.first&.to_s
          raw_target = opts[:to]&.to_s
        end
        return unless raw_path

        effective_prefix =
          case opts[:on]&.to_sym
          when :member then ctx.resource_member_prefix || ctx.path_prefix
          when :collection then ctx.resource_collection_prefix || ctx.path_prefix
          else ctx.path_prefix
          end
        effective_controller =
          %i[member collection].include?(opts[:on]&.to_sym) ? (ctx.resource_controller || ctx.controller) : ctx.controller

        path = join_path(effective_prefix, raw_path)
        controller, action =
          if raw_target
            split_target(raw_target, ctx)
          elsif opts.key?(:to)
            # Dynamic `to:` (e.g. redirect("/new") or Rack app): keep the route path without guessing a controller.
            [nil, nil]
          elsif opts[:controller] || opts[:action]
            ctrl = opts[:controller] ? qualify_controller(opts[:controller].to_s, ctx.module_prefix) : effective_controller
            act = (opts[:action] || raw_path.split("/").last).to_s
            [ctrl, act]
          elsif effective_controller
            [effective_controller, raw_path.delete_prefix("/").tr("-", "_")]
          elsif raw_path.include?("/")
            parts = raw_path.delete_prefix("/").split("/")
            act = parts.pop
            [qualify_controller(parts.join("/"), ctx.module_prefix), act]
          else
            [nil, nil]
          end

        verbs.each do |verb|
          record_route(verb, path, controller, action, ctx)
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

        if ctx.in_local_first
          @local_routes << entry
        else
          @server_routes << entry
        end
      end

      # --- AST-preserving local config/routes.rb emitter ---

      def emit_statements(stmts, ctx)
        lines = []
        stmts.each do |stmt|
          lines.concat(emit_node(stmt, ctx))
        end
        lines
      end

      def emit_node(node, ctx)
        return [] unless node.is_a?(Prism::CallNode) && node.receiver.nil?

        case node.name
        when :local_first
          pos, = extract_args(node)
          declared_name = pos.first ? pos.first.to_s : nil
          active = @island.nil? || declared_name == @island
          return [] unless active && node.block

          child_ctx = ctx.dup
          child_ctx.in_local_first = true
          child_ctx.island_name = declared_name || ctx.island_name
          emit_statements(statements_of(node.block.body), child_ctx)
        when :draw
          pos, = extract_args(node)
          name = pos.first&.to_s
          return [] unless name

          sub_path = resolve_draw_path!(name)
          parsed = load_drawn_ast!(sub_path)
          emit_statements(statements_of(parsed.value.statements), ctx)
        when *CONTAINER_CALLS
          if node.block
            inner = emit_statements(statements_of(node.block.body), ctx)
            return [] if inner.empty? && !ctx.in_local_first

            if ctx.in_local_first && !subtree_has_special_calls?(node.block.body)
              reindent_slice(node.location.slice)
            else
              header = container_header(node)
              closing = node.block.closing_loc.slice
              [header, *inner.map { |line| "  #{line}" }, closing]
            end
          else
            ctx.in_local_first ? reindent_slice(node.location.slice) : []
          end
        when :root, *HTTP_VERBS, :match
          ctx.in_local_first ? reindent_slice(node.location.slice) : []
        else
          []
        end
      end

      def subtree_has_special_calls?(node)
        return false unless node

        found = false
        queue = [node]
        while (current = queue.shift)
          if current.is_a?(Prism::CallNode) && current.receiver.nil? && %i[local_first draw].include?(current.name)
            found = true
            break
          end
          queue.concat(current.compact_child_nodes)
        end
        found
      end

      def container_header(node)
        block = node.block
        source_slice = node.location.slice
        open_offset = block.opening_loc.end_offset - node.location.start_offset
        if block.parameters
          open_offset = block.parameters.location.end_offset - node.location.start_offset
        end
        source_slice[0...open_offset].strip
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

      def resolve_resource_controller(name, opts, ctx, singular:)
        raw =
          if opts[:controller]
            opts[:controller].to_s
          elsif singular
            ActiveSupport::Inflector.pluralize(name)
          else
            name
          end
        mod = opts[:module] ? join_module(ctx.module_prefix, opts[:module].to_s) : ctx.module_prefix
        qualify_controller(raw, mod)
      end

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

      def extract_args(call, include_string_mapping: false)
        pos = []
        opts = {}
        string_mapping = nil

        Array(call.arguments&.arguments).each do |arg|
          if arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)
            arg.elements.each do |assoc|
              next unless assoc.is_a?(Prism::AssocNode)

              key = literal_value(assoc.key)
              val = literal_value(assoc.value)
              if include_string_mapping && val.is_a?(String) && val.include?("#") && string_mapping.nil? &&
                  (key.is_a?(String) || (key.is_a?(Symbol) && !ROUTE_OPTION_KEYS.include?(key)))
                string_mapping = [key.to_s, val]
              elsif key.is_a?(Symbol)
                opts[key] = val
              elsif key.is_a?(String)
                opts[key.to_sym] = val
              end
            end
          else
            pos << literal_value(arg)
          end
        end

        include_string_mapping ? [pos, opts, string_mapping] : [pos, opts]
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
          node.elements.each_with_object({}) do |assoc, hash|
            next unless assoc.is_a?(Prism::AssocNode)

            k = literal_value(assoc.key)
            hash[k] = literal_value(assoc.value) unless k.nil?
          end
        else
          nil
        end
      end
    end
  end
end
