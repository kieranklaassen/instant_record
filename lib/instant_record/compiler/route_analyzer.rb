# frozen_string_literal: true

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
      ROUTE_OPTION_KEYS = %i[to controller action via as on only except path module param constraints defaults format].freeze

      EMPTY_ARRAY = [].freeze
      EMPTY_HASH = {}.freeze
      ROUTE_OPTION_KEYS_SET = ROUTE_OPTION_KEYS.to_h { |k| [k, true] }.freeze
      SINGULAR_RESOURCE_ROUTES = RESOURCE_ROUTES.reject { |action, *| action == "index" }.freeze
      ALL_HTTP_VERBS = %w[GET POST PATCH PUT DELETE OPTIONS].freeze
      DEFAULT_MATCH_VERBS = %w[GET POST].freeze
      INDENTS = Array.new(32) { |i| ("  " * i).freeze }.freeze
      NL_INDENTS = Array.new(32) { |i| ("\n" + "  " * i).freeze }.freeze
      NL_SPACES = Array.new(32) { |i| ("\n" + " " * i).freeze }.freeze
      LESS_INDENT_RES = Array.new(32) { |k| k == 0 ? nil : /\n {0,#{k - 1}}[^ ]/ }.freeze
      BLANK_LINE_RE = /\n[ \t\v\f\0]*(?:\n|\z)/
      private_constant :EMPTY_ARRAY, :EMPTY_HASH, :ROUTE_OPTION_KEYS_SET, :SINGULAR_RESOURCE_ROUTES,
                       :ALL_HTTP_VERBS, :DEFAULT_MATCH_VERBS, :INDENTS, :NL_INDENTS, :NL_SPACES,
                       :LESS_INDENT_RES, :BLANK_LINE_RE

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
          copy = dup
          changes.each { |key, value| copy[key] = value }
          copy
        end
      end

      def self.analyze(source_root:, island: nil)
        new(source_root: source_root, island: island).analyze
      end

      def initialize(source_root:, island: nil)
        @source_root = File.expand_path(source_root.to_s)
        @routes_dir = File.expand_path(File.join(@source_root, "config/routes"))
        @routes_dir_prefix = "#{@routes_dir}#{File::SEPARATOR}"
        @island = island.nil? || island.to_s.empty? ? nil : island.to_s
        @has_local_first = false
        @declared_islands = []
        @local_routes = []
        @server_routes = []
        @overrides = Manifest.normalize_overrides(nil)
        @drawn_files = {}
        @resolved_draw_paths = {}
        @singularize_cache = {}
        @pluralize_cache = {}
        @special_calls_cache = {}.compare_by_identity
        @special_offsets_cache = {}.compare_by_identity
      end

      def analyze
        body, root_source = routes_body

        @path_prefix = ""
        @nested_base = nil
        @nested_name = nil
        @nested_param = nil
        @module_prefix = nil
        @controller = nil
        @in_local_first = false
        @island_name = nil
        @resource_member_prefix = nil
        @resource_collection_prefix = nil
        @resource_controller = nil
        @active_draws = {}

        walk_statements(body)
        check_island_declared!

        if @has_local_first
          local = @local_routes
          override_server_routes = @overrides[:server_routes]
          server = override_server_routes.empty? ? @server_routes : (@server_routes + override_server_routes)
          out = +"Rails.application.routes.draw do\n"
          emit_statements(body, root_source, false, out, 1)
          out << "end\n"
          local_source = out
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

          return [[], ""]
        end

        source = File.read(routes_path)
        statements = parse_ruby!(source, routes_path)
        draw_call = statements.find { |stmt| stmt.is_a?(Prism::CallNode) && stmt.name == :draw && literal_block?(stmt) }
        [draw_call ? statements_of(draw_call.block.body) : statements, source]
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

      def walk_statements(stmts)
        stmts.each { |stmt| walk_node(stmt) }
      end

      def walk_block(node)
        walk_statements(statements_of(node.block.body)) if literal_block?(node)
      end

      # A block passed as an argument (`&blk`) is only known at runtime.
      def literal_block?(node)
        node.block.is_a?(Prism::BlockNode)
      end

      def walk_node(node)
        return unless node.is_a?(Prism::CallNode) && node.receiver.nil?

        # mount is left out: a server-side engine (e.g. InstantRecord::Engine) is not a local controller.
        case node.name
        when :local_first then walk_local_first(node)
        when :draw then walk_draw(node)
        when :namespace then walk_namespace(node)
        when :scope then walk_scope(node)
        when :resources then walk_resources(node, singular: false)
        when :resource then walk_resources(node, singular: true)
        when :member then walk_resource_scope(node, :member)
        when :collection then walk_resource_scope(node, :collection)
        when :constraints, :defaults then walk_block(node)
        when :root then record_root(node)
        when :get then record_http_verb(node, "GET")
        when :post then record_http_verb(node, "POST")
        when :put then record_http_verb(node, "PUT")
        when :patch then record_http_verb(node, "PATCH")
        when :delete then record_http_verb(node, "DELETE")
        when :match then record_http_verb(node, nil)
        end
      end

      def walk_local_first(node)
        @has_local_first = true
        first_pos, opts = extract_first_and_opts(node)
        declared_name = first_pos ? first_pos.to_s : nil
        @declared_islands << declared_name if declared_name

        active = active_island?(declared_name)
        if active && !opts.empty?
          @overrides = Manifest.merge_overrides(@overrides, Manifest.normalize_overrides(opts))
        end

        return unless literal_block?(node)

        prev_in_local_first = @in_local_first
        prev_island_name = @island_name
        @in_local_first = active
        @island_name = declared_name || prev_island_name
        begin
          walk_statements(statements_of(node.block.body))
        ensure
          @in_local_first = prev_in_local_first
          @island_name = prev_island_name
        end
      end

      def declared_island(node)
        args = node.arguments&.arguments
        return nil unless args

        args.each do |arg|
          next if arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)

          val = literal_value(arg)
          return val ? val.to_s : nil
        end
        nil
      end

      def active_island?(declared_name)
        @island.nil? || declared_name == @island
      end

      def walk_draw(node)
        name = first_name(node)
        return unless name

        sub_path = resolve_draw_path!(name)
        stmts, = drawn_file(sub_path)
        @active_draws[sub_path] = true
        begin
          walk_statements(stmts)
        ensure
          @active_draws.delete(sub_path)
        end
      end

      def resolve_draw_path!(name)
        sub_path = @resolved_draw_paths[name]
        unless sub_path
          sub_path = File.expand_path("#{name}.rb", @routes_dir)
          unless sub_path.start_with?(@routes_dir_prefix)
            raise BuildError, "Invalid route draw name #{name.inspect}: escapes config/routes/"
          end
          unless File.file?(sub_path)
            raise BuildError, "Route file config/routes/#{name}.rb referenced by draw(:#{name}) does not exist"
          end
          @resolved_draw_paths[name] = sub_path
        end

        raise BuildError, "Cyclic route draw detected for config/routes/#{name}.rb" if @active_draws[sub_path]

        sub_path
      end

      def drawn_file(sub_path)
        @drawn_files[sub_path] ||= begin
          source = File.read(sub_path)
          [parse_ruby!(source, sub_path), source]
        end
      end

      def walk_namespace(node)
        return unless literal_block?(node)

        first_pos, opts = extract_first_and_opts(node)
        name = first_pos&.to_s
        return unless name

        walk_scoped_block(node, opts, path: opts.fetch(:path, name), mod: opts.fetch(:module, name))
      end

      def walk_scope(node)
        return unless literal_block?(node)

        first_pos, opts = extract_first_and_opts(node)
        walk_scoped_block(node, opts, path: opts.fetch(:path, first_pos), mod: opts[:module])
      end

      def walk_scoped_block(node, opts, path:, mod:)
        prev_path = @path_prefix
        prev_nested_base = @nested_base
        prev_nested_name = @nested_name
        prev_nested_param = @nested_param
        prev_mod = @module_prefix
        prev_ctrl = @controller

        base_path = current_path_prefix
        module_prefix = join_module(prev_mod, mod)
        opt_ctrl = opts[:controller]
        @path_prefix = join_path(base_path, path)
        @nested_base = nil
        @nested_name = nil
        @nested_param = nil
        @module_prefix = module_prefix
        @controller = opt_ctrl ? qualify_controller(opt_ctrl.to_s, module_prefix) : prev_ctrl
        begin
          walk_statements(statements_of(node.block.body))
        ensure
          @path_prefix = prev_path
          @nested_base = prev_nested_base
          @nested_name = prev_nested_name
          @nested_param = prev_nested_param
          @module_prefix = prev_mod
          @controller = prev_ctrl
        end
      end

      def walk_resource_scope(node, on)
        return unless literal_block?(node)

        prefix = on == :member ? @resource_member_prefix : @resource_collection_prefix
        prev_path = @path_prefix
        prev_nested_base = @nested_base
        prev_nested_name = @nested_name
        prev_nested_param = @nested_param
        prev_ctrl = @controller
        @path_prefix = prefix || current_path_prefix
        @nested_base = nil
        @nested_name = nil
        @nested_param = nil
        @controller = @resource_controller || prev_ctrl
        begin
          walk_statements(statements_of(node.block.body))
        ensure
          @path_prefix = prev_path
          @nested_base = prev_nested_base
          @nested_name = prev_nested_name
          @nested_param = prev_nested_param
          @controller = prev_ctrl
        end
      end

      def walk_resources(node, singular:)
        args = node.arguments&.arguments
        return unless args && !args.empty?

        first_pos = nil
        has_pos = false
        extra_pos = nil
        opts = nil

        args.each do |arg|
          if arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)
            opts = extract_hash_options(arg, opts)
          elsif !has_pos
            first_pos = arg
            has_pos = true
          else
            (extra_pos ||= []) << arg
          end
        end
        return unless has_pos

        opts ||= EMPTY_HASH
        only = opts[:only]
        except = opts[:except]
        if only.nil? && except.nil?
          routes_table = singular ? SINGULAR_RESOURCE_ROUTES : RESOURCE_ROUTES
          actions = nil
        else
          actions = filter_actions(singular ? SINGULAR_ACTIONS : PLURAL_ACTIONS, only: only, except: except)
          routes_table = RESOURCE_ROUTES
        end

        opt_module = opts[:module]
        module_prefix = opt_module ? join_module(@module_prefix, opt_module) : @module_prefix
        has_block = literal_block?(node)

        process_resource(first_pos, opts, routes_table, actions, module_prefix, singular, has_block, node)
        return unless extra_pos

        extra_pos.each do |pos_node|
          process_resource(pos_node, opts, routes_table, actions, module_prefix, singular, has_block, node)
        end
      end

      def process_resource(pos_node, opts, routes_table, actions, module_prefix, singular, has_block, node)
        name = literal_string(pos_node)
        path_opt = opts.key?(:path) ? opts[:path] : name
        base = join_path(current_path_prefix, path_opt)
        opt_ctrl = opts[:controller]
        controller = opt_ctrl ? opt_ctrl.to_s : (singular ? pluralize_cached(name) : name)
        controller = qualify_controller(controller, module_prefix)

        param = opts[:param] || "id"
        member = singular ? base : "#{base}/:#{param}"

        unless (actions && actions.empty?) || controller.start_with?("rails/")
          record_resource_routes(base, member, controller, routes_table, actions, singular)
        end

        return unless has_block

        prev_path = @path_prefix
        prev_nested_base = @nested_base
        prev_nested_name = @nested_name
        prev_nested_param = @nested_param
        prev_mod = @module_prefix
        prev_ctrl = @controller
        prev_member = @resource_member_prefix
        prev_collection = @resource_collection_prefix
        prev_res_ctrl = @resource_controller

        if singular
          @path_prefix = base
          @nested_base = nil
          @nested_name = nil
          @nested_param = nil
        else
          # Defer singularize(name) until a nested statement actually reads current_path_prefix.
          @path_prefix = nil
          @nested_base = base
          @nested_name = name
          @nested_param = param
        end
        @module_prefix = module_prefix
        @controller = controller
        @resource_member_prefix = member
        @resource_collection_prefix = base
        @resource_controller = controller
        begin
          walk_statements(statements_of(node.block.body))
        ensure
          @path_prefix = prev_path
          @nested_base = prev_nested_base
          @nested_name = prev_nested_name
          @nested_param = prev_nested_param
          @module_prefix = prev_mod
          @controller = prev_ctrl
          @resource_member_prefix = prev_member
          @resource_collection_prefix = prev_collection
          @resource_controller = prev_res_ctrl
        end
      end

      def record_resource_routes(base, member, controller, routes_table, actions, singular)
        norm_base = Manifest.normalize_route_path(base).freeze
        norm_member = singular ? norm_base : Manifest.normalize_route_path(member).freeze
        target_list = @in_local_first ? @local_routes : @server_routes
        island = @in_local_first ? @island_name : nil

        routes_table.each do |action, verb, on, suffix|
          next if actions && !actions.include?(action)

          prefix_path = on == :member ? norm_member : norm_base
          route_path =
            if suffix.empty?
              prefix_path
            elsif prefix_path == "/"
              suffix
            else
              "#{prefix_path}#{suffix}".freeze
            end

          if island
            target_list << {
              "method" => verb,
              "path" => route_path,
              "controller" => controller,
              "action" => action,
              "island" => island
            }
          else
            target_list << {
              "method" => verb,
              "path" => route_path,
              "controller" => controller,
              "action" => action
            }
          end
        end
      end

      def record_root(node)
        first_pos, opts = extract_first_and_opts(node)
        target = (opts[:to] || first_pos)&.to_s
        return unless target

        controller, action = split_target(target)
        prefix = current_path_prefix
        path = prefix.empty? ? "/" : prefix
        record_route("GET", path, controller, action)
      end

      def record_http_verb(node, verbs)
        args = node.arguments&.arguments
        return unless args && !args.empty?

        first_pos = nil
        has_pos = false
        opts = nil
        map_path = nil
        map_target = nil

        args.each do |arg|
          if arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)
            arg.elements.each do |elem|
              next unless elem.is_a?(Prism::AssocNode)

              key_node = elem.key
              if key_node.is_a?(Prism::SymbolNode)
                key = key_node.unescaped.to_sym
                val = literal_value(elem.value)
                if map_path.nil? && !ROUTE_OPTION_KEYS_SET[key] && val.is_a?(String) && val.include?("#")
                  map_path = key.to_s
                  map_target = val
                else
                  (opts ||= {})[key] = val
                end
              elsif key_node.is_a?(Prism::StringNode)
                key = key_node.unescaped
                val = literal_value(elem.value)
                if map_path.nil? && val.is_a?(String) && val.include?("#")
                  map_path = key
                  map_target = val
                else
                  (opts ||= {})[key.to_sym] = val
                end
              end
            end
          elsif !has_pos
            first_pos = arg
            has_pos = true
          end
        end

        opts ||= EMPTY_HASH
        if map_path
          raw_path = map_path
          raw_target = map_target
        else
          raw_path = has_pos ? literal_optional_string(first_pos) : nil
          return unless raw_path

          to_opt = opts[:to]
          raw_target = to_opt&.to_s
        end

        if verbs.nil?
          via = opts[:via]
          verbs =
            case via
            when Array then via.map { |v| v.to_s.upcase }
            when Symbol, String
              via.to_s == "all" ? ALL_HTTP_VERBS : [via.to_s.upcase]
            else
              DEFAULT_MATCH_VERBS
            end
        end

        on = opts[:on]
        if on == :member || on == "member"
          on_path_prefix = @resource_member_prefix || current_path_prefix
          on_controller = @resource_controller || @controller
        elsif on == :collection || on == "collection"
          on_path_prefix = @resource_collection_prefix || current_path_prefix
          on_controller = @resource_controller || @controller
        else
          on_path_prefix = current_path_prefix
          on_controller = @controller
        end

        path = join_path(on_path_prefix, raw_path)
        controller, action =
          raw_target ? split_target(raw_target) : infer_endpoint(raw_path, opts, on_controller)

        if verbs.is_a?(String)
          record_route(verbs, path, controller, action)
        else
          verbs.each { |verb| record_route(verb, path, controller, action) }
        end
      end

      def infer_endpoint(raw_path, opts, on_controller)
        # Dynamic `to:` (e.g. redirect("/new") or Rack app): keep the route path without guessing a controller.
        return [nil, nil] if opts.key?(:to)

        opt_ctrl = opts[:controller]
        opt_act = opts[:action]
        if opt_ctrl || opt_act
          controller = opt_ctrl ? qualify_controller(opt_ctrl.to_s, @module_prefix) : on_controller
          [controller, (opt_act || raw_path.split("/").last).to_s]
        elsif on_controller
          act = raw_path.getbyte(0) == 47 ? raw_path.delete_prefix("/") : raw_path
          act = act.tr("-", "_") if act.include?("-")
          [on_controller, act]
        elsif raw_path.include?("/")
          trimmed = raw_path.getbyte(0) == 47 ? raw_path.delete_prefix("/") : raw_path
          *parts, action = trimmed.split("/")
          [qualify_controller(parts.join("/"), @module_prefix), action]
        else
          [nil, nil]
        end
      end

      def record_route(method_name, path, controller, action)
        # Skip Rails internal framework endpoints (e.g. rails/health, rails/pwa).
        return if controller&.start_with?("rails/")

        norm_path = Manifest.normalize_route_path(path).freeze
        if @in_local_first
          entry =
            if @island_name
              {
                "method" => method_name,
                "path" => norm_path,
                "controller" => controller,
                "action" => action,
                "island" => @island_name
              }
            else
              {
                "method" => method_name,
                "path" => norm_path,
                "controller" => controller,
                "action" => action
              }
            end
          @local_routes << entry
        else
          @server_routes << {
            "method" => method_name,
            "path" => norm_path,
            "controller" => controller,
            "action" => action
          }
        end
      end

      # --- AST-preserving local config/routes.rb emitter ---

      def emit_statements(stmts, source, local, out, depth)
        stmts.each { |stmt| emit_node(stmt, source, local, out, depth) }
      end

      def emit_node(node, source, local, out, depth)
        return unless node.is_a?(Prism::CallNode) && node.receiver.nil?

        case node.name
        when :local_first
          return unless active_island?(declared_island(node)) && literal_block?(node)

          emit_statements(statements_of(node.block.body), source, true, out, depth)
        when :draw
          name = first_name(node)
          return unless name

          sub_path = resolve_draw_path!(name)
          stmts, sub_source = drawn_file(sub_path)
          @active_draws[sub_path] = true
          begin
            emit_statements(stmts, sub_source, local, out, depth)
          ensure
            @active_draws.delete(sub_path)
          end
        when :namespace, :scope, :resources, :resource, :member, :collection, :constraints, :defaults
          if literal_block?(node)
            emit_container(node, source, local, out, depth)
          else
            emit_call(node, source, local, out, depth)
          end
        when :root, :get, :post, :put, :patch, :delete, :match
          emit_call(node, source, local, out, depth)
        end
      end

      def emit_call(node, source, local, out, depth)
        return unless local

        emit_reindented_loc(node.location, source, out, depth)
      end

      def emit_container(node, source, local, out, depth)
        body = node.block.body
        if local
          unless subtree_has_special_calls?(body, source)
            emit_reindented_loc(node.location, source, out, depth)
            return
          end

          indent = indent_for(depth)
          out << indent << container_header(node, source) << "\n"
          emit_statements(statements_of(body), source, true, out, depth + 1)
          out << indent << node.block.closing_loc.slice << "\n"
        else
          return unless subtree_has_special_calls?(body, source)

          saved_len = out.length
          indent = indent_for(depth)
          out << indent << container_header(node, source) << "\n"
          after_header_bytes = out.bytesize
          emit_statements(statements_of(body), source, false, out, depth + 1)
          if out.bytesize == after_header_bytes
            out.slice!(saved_len, out.length - saved_len)
          else
            out << indent << node.block.closing_loc.slice << "\n"
          end
        end
      end

      def subtree_has_special_calls?(node, source)
        return false unless node

        cached = @special_calls_cache[node]
        return cached unless cached.nil?

        offsets = special_text_offsets(source)
        return (@special_calls_cache[node] = false) if offsets.empty?

        loc = node.location
        start_off = loc.start_offset
        next_off = offsets.bsearch { |off| off >= start_off }
        return (@special_calls_cache[node] = false) unless next_off && next_off < loc.end_offset

        @special_calls_cache[node] = ast_has_special_calls?(node, source)
      end

      def special_text_offsets(source)
        @special_offsets_cache[source] ||= begin
          offsets = []
          pos = 0
          while (idx = source.byteindex("local_first", pos))
            offsets << idx
            pos = idx + 11
          end
          pos = 0
          while (idx = source.byteindex("draw", pos))
            offsets << idx
            pos = idx + 4
          end
          offsets.sort! if offsets.length > 1
          offsets
        end
      end

      def ast_has_special_calls?(node, source)
        if node.is_a?(Prism::StatementsNode)
          node.body.each do |child|
            return true if subtree_has_special_calls?(child, source)
          end
          return false
        end

        if node.is_a?(Prism::CallNode) && node.receiver.nil?
          name = node.name
          return true if name == :local_first || name == :draw
        end

        node.child_nodes.each do |child|
          next unless child

          return true if subtree_has_special_calls?(child, source)
        end
        false
      end

      def container_header(node, source)
        # The parameters of a block that uses _1 or it span the whole block.
        parameters = node.block.parameters
        header = parameters.is_a?(Prism::BlockParametersNode) ? parameters.location : node.block.opening_loc
        start_off = node.location.start_offset
        source.byteslice(start_off, header.end_offset - start_off).strip
      end

      def indent_for(depth)
        INDENTS[depth] || ("  " * depth)
      end

      def emit_reindented_loc(loc, source, out, depth)
        start_off = loc.start_offset
        end_off = loc.end_offset
        return if start_off >= end_off

        indent = indent_for(depth)
        nl = source.byteindex("\n", start_off)
        if nl.nil? || nl >= end_off
          line_end = (end_off > start_off && source.getbyte(end_off - 1) == 13) ? end_off - 1 : end_off
          fs = skip_leading_ascii_whitespace(source, start_off, line_end)
          if fs == line_end
            out << (depth == 1 ? "\n" : "#{indent}\n")
          else
            out << indent << source.byteslice(fs, line_end - fs) << "\n"
          end
          return
        end

        slice = source.byteslice(start_off, end_off - start_off)
        if slice.valid_encoding? && slice.getbyte(0) > 32 && !slice.include?("\r") && !BLANK_LINE_RE.match?(slice)
          last_nl = slice.byterindex("\n")
          k = 0
          pos = last_nl + 1
          len = slice.bytesize
          k += 1 while pos + k < len && slice.getbyte(pos + k) == 32
          if k < 32 && pos + k < len && slice.getbyte(pos + k) > 32 &&
             (k == 0 || !LESS_INDENT_RES[k].match?(slice))
            if k == indent.bytesize
              out << indent << slice << "\n"
            else
              nl_indent = NL_INDENTS[depth] || "\n#{indent}"
              out << indent << slice.gsub(NL_SPACES[k], nl_indent) << "\n"
            end
            return
          end
        end

        emit_reindented_loc_slow(source, start_off, end_off, nl, out, indent, depth)
      end

      def emit_reindented_loc_slow(source, start_off, end_off, nl, out, indent, depth)
        line0_end = (nl > start_off && source.getbyte(nl - 1) == 13) ? nl - 1 : nl
        fs = skip_leading_ascii_whitespace(source, start_off, line0_end)

        # Pass 1: find common leading space indent across non-blank subsequent lines.
        min_indent = nil
        pos = nl + 1
        while pos < end_off
          next_nl = source.byteindex("\n", pos)
          has_nl = next_nl && next_nl < end_off
          raw_end = has_nl ? next_nl : end_off
          line_end = (raw_end > pos && source.getbyte(raw_end - 1) == 13) ? raw_end - 1 : raw_end

          spaces = leading_spaces_in_range(source, pos, line_end)
          if spaces && (min_indent.nil? || spaces < min_indent)
            min_indent = spaces
            break if min_indent == 0
          end
          break unless has_nl

          pos = next_nl + 1
        end
        min_indent ||= 0

        if fs == line0_end
          out << (depth == 1 ? "\n" : "#{indent}\n")
        else
          out << indent << source.byteslice(fs, line0_end - fs) << "\n"
        end

        # Pass 2: emit subsequent lines directly from source without intermediate line arrays.
        pos = nl + 1
        while pos < end_off
          next_nl = source.byteindex("\n", pos)
          has_nl = next_nl && next_nl < end_off
          raw_end = has_nl ? next_nl : end_off
          line_end = (raw_end > pos && source.getbyte(raw_end - 1) == 13) ? raw_end - 1 : raw_end

          if range_blank?(source, pos, line_end)
            out << (depth == 1 ? "\n" : "#{indent}\n")
          else
            content_start = pos + min_indent
            out << indent << source.byteslice(content_start, line_end - content_start) << "\n"
          end
          break unless has_nl

          pos = next_nl + 1
        end
      end

      def skip_leading_ascii_whitespace(source, pos, line_end)
        while pos < line_end
          b = source.getbyte(pos)
          break unless b == 32 || (b >= 9 && b <= 13)

          pos += 1
        end
        pos
      end

      def leading_spaces_in_range(source, pos, line_end)
        return nil if pos >= line_end

        i = pos
        i += 1 while i < line_end && source.getbyte(i) == 32
        return nil if i == line_end
        return i - pos if source.getbyte(i) > 32

        range_blank?(source, i, line_end) ? nil : (i - pos)
      end

      def range_blank?(source, pos, line_end)
        i = pos
        while i < line_end
          b = source.getbyte(i)
          return false unless b == 32 || (b >= 9 && b <= 13) || b == 0

          i += 1
        end
        true
      end

      # --- Helpers ---

      def current_path_prefix
        @path_prefix ||= "#{@nested_base}/:#{singularize_cached(@nested_name)}_#{@nested_param}"
      end

      def singularize_cached(name)
        @singularize_cache[name] ||= ActiveSupport::Inflector.singularize(name)
      end

      def pluralize_cached(name)
        @pluralize_cache[name] ||= ActiveSupport::Inflector.pluralize(name)
      end

      def split_target(target)
        if target.include?("#")
          ctrl, action = target.split("#", 2)
          [qualify_controller(ctrl, @module_prefix), action]
        else
          [@controller, target]
        end
      end

      def qualify_controller(controller, module_prefix)
        return controller.delete_prefix("/") if controller.getbyte(0) == 47
        return controller if module_prefix.nil? || module_prefix.empty?
        if controller.start_with?(module_prefix) && controller.getbyte(module_prefix.bytesize) == 47
          return controller
        end

        "#{module_prefix}/#{controller}"
      end

      def join_path(prefix, segment)
        return prefix if segment.nil?

        seg = segment.is_a?(String) ? segment : segment.to_s
        seg = seg.delete_prefix("/") if seg.getbyte(0) == 47
        return prefix if seg.empty?

        if prefix.nil? || prefix.empty?
          "/#{seg}"
        elsif prefix.getbyte(-1) == 47
          "#{prefix.delete_suffix("/")}/#{seg}"
        else
          "#{prefix}/#{seg}"
        end
      end

      def join_module(prefix, segment)
        return prefix if segment.nil?

        seg = segment.is_a?(String) ? segment : segment.to_s
        seg = seg.delete_prefix("/") if seg.getbyte(0) == 47
        seg = seg.delete_suffix("/") if seg.getbyte(-1) == 47
        return prefix if seg.empty?

        prefix.nil? || prefix.empty? ? seg : "#{prefix}/#{seg}"
      end

      def filter_actions(defaults, only:, except:)
        list = defaults
        if only
          if only.is_a?(Array)
            return EMPTY_ARRAY if only.empty?

            allowed = only.map(&:to_s)
            list = list & allowed
          else
            name = only.to_s
            list = list.include?(name) ? [name] : EMPTY_ARRAY
          end
        end
        if except && !list.empty?
          denied = except.is_a?(Array) ? except.map(&:to_s) : [except.to_s]
          list = list - denied
        end
        list
      end

      def first_name(call)
        args = call.arguments&.arguments
        return nil unless args

        args.each do |arg|
          next if arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)

          return literal_optional_string(arg)
        end
        nil
      end

      def extract_first_and_opts(call)
        args = call.arguments&.arguments
        return [nil, EMPTY_HASH] unless args && !args.empty?

        first_pos = nil
        has_pos = false
        opts = nil
        args.each do |arg|
          if arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)
            opts = extract_hash_options(arg, opts)
          elsif !has_pos
            first_pos = literal_value(arg)
            has_pos = true
          end
        end
        [first_pos, opts || EMPTY_HASH]
      end

      def extract_hash_options(hash_node, opts)
        hash_node.elements.each do |elem|
          next unless elem.is_a?(Prism::AssocNode)

          key_node = elem.key
          if key_node.is_a?(Prism::SymbolNode)
            (opts ||= {})[key_node.unescaped.to_sym] = literal_value(elem.value)
          elsif key_node.is_a?(Prism::StringNode)
            (opts ||= {})[key_node.unescaped.to_sym] = literal_value(elem.value)
          end
        end
        opts
      end

      def literal_string(node)
        case node
        when Prism::SymbolNode, Prism::StringNode then node.unescaped
        else literal_value(node).to_s
        end
      end

      def literal_optional_string(node)
        case node
        when Prism::SymbolNode, Prism::StringNode then node.unescaped
        else
          val = literal_value(node)
          val.nil? ? nil : val.to_s
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
          hash = {}
          node.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)

            key = literal_value(assoc.key)
            hash[key] = literal_value(assoc.value) unless key.nil?
          end
          hash
        end
      end
    end
  end
end
