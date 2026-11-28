require "active_support/inflector"
require "action_view"
require "prism"
require "set"
require_relative "manifest"
require_relative "runner"

module InstantRecord
  class Compiler
    # Prism + ActionView::Erubi transitive reachability tracer for Local-First Islands.
    # Starting from local_first routes (plus explicit include overrides and, for
    # native builds, app/screens), stages only reachable controllers, models,
    # views, helpers, and migrations — skipping `server_only` blocks while
    # traversing `browser_only`/`client_only` blocks — and emits crisp
    # missing-symbol diagnostics and dynamic-pattern hints.
    class ReachabilityTracer
      FRAMEWORK_TABLES = %w[
        instant_record_outbox
        instant_record_sync_metadata
        instant_record_changes
        instant_record_applied_mutations
      ].freeze

      ASSOCIATION_MACROS = %i[belongs_to has_many has_one has_and_belongs_to_many].freeze
      NON_TEMPLATE_RENDER_KEYS = %i[json plain html inline body xml js file head nothing].freeze
      DDL_TABLE_CALLS = %i[
        create_table change_table drop_table rename_table
        add_column remove_column change_column change_column_null change_column_default rename_column
        add_index remove_index
        add_reference remove_reference add_belongs_to remove_belongs_to
        add_timestamps remove_timestamps
        add_foreign_key remove_foreign_key
      ].freeze
      DDL_TABLE_CALLS_SET = DDL_TABLE_CALLS.to_h { |name| [name, true] }.freeze

      SQL_TABLE_RE = /\b(?:FROM|INTO|UPDATE|TABLE|ON)\s+["`]?([a-z_][a-z0-9_]*)["`]?/i
      ENCODING_PRAGMA_RE = /\A(?:\xEF\xBB\xBF)?(?:#![^\n]*\n)?[ \t\v\f\r]*#[^\n]*(?:en)?coding[ \t\v\f\r]*[:=]/i
      FULL_APP_INSPECT_RE = /render|const_get|constantize/
      FULL_APP_INSPECT_WITH_LAYOUT_RE = /render|const_get|constantize|layout/
      LOWERCASE_REL_RE = /\A[a-z0-9_\/]+\z/
      ASCII_IDENT_RE = /\A[A-Za-z0-9_]+\z/
      UNDERSCORE_PERCENT_LIT_RE = /%[A-Za-z]?_/
      HELPER_DEF_CANDIDATE_RE = /(?<![A-Za-z0-9_])def(?=[ \t\r\n\f\v]+([A-Za-z_\u0080-\u{10FFFF}][A-Za-z0-9_\u0080-\u{10FFFF}]*[?!]?))/
      HELPER_DEF_TRICKY_RE = /(?<![A-Za-z0-9_])def[ \t\r\n\f\v]*[#\\]/
      ERB_REGEXP = ::Erubi::Engine::DEFAULT_REGEXP
      ERB_BLOCK_EXPR = ActionView::Template::Handlers::ERB::Erubi::BLOCK_EXPR
      ERB_NEWLINES = Array.new(64) { |n| ("\n" * n).freeze }.freeze

      Result = Struct.new(
        :controllers,
        :models,
        :views,
        :helpers,
        :screens,
        :migrations,
        :manifest_migrations,
        :extra_files,
        :model_metadata,
        :diagnostics,
        keyword_init: true
      )

      # Shared base visitor that skips leaf nodes without calling each_child_node
      # and walks hot container nodes directly.
      class FastVisitor < Prism::Visitor
        def visit_string_node(_); end
        def visit_symbol_node(_); end
        def visit_integer_node(_); end
        def visit_float_node(_); end
        def visit_true_node(_); end
        def visit_false_node(_); end
        def visit_nil_node(_); end
        def visit_self_node(_); end
        def visit_local_variable_read_node(_); end
        def visit_instance_variable_read_node(_); end
        def visit_class_variable_read_node(_); end
        def visit_global_variable_read_node(_); end
        def visit_source_file_node(_); end
        def visit_source_line_node(_); end
        def visit_source_encoding_node(_); end
        def visit_rational_node(_); end
        def visit_regular_expression_node(_); end
        def visit_back_reference_read_node(_); end
        def visit_numbered_reference_read_node(_); end
        def visit_required_parameter_node(_); end

        def visit_statements_node(node)
          node.body.each { |child| child.accept(self) }
        end

        def visit_arguments_node(node)
          node.arguments.each { |child| child.accept(self) }
        end

        def visit_array_node(node)
          node.elements.each { |child| child.accept(self) }
        end

        def visit_hash_node(node)
          node.elements.each { |child| child.accept(self) }
        end

        def visit_keyword_hash_node(node)
          node.elements.each { |child| child.accept(self) }
        end

        def visit_assoc_node(node)
          node.key.accept(self)
          node.value.accept(self)
        end

        def visit_call_node(node)
          node.receiver&.accept(self)
          node.arguments&.accept(self)
          node.block&.accept(self)
        end

        def visit_block_node(node)
          node.parameters&.accept(self)
          node.body&.accept(self)
        end

        def visit_def_node(node)
          node.receiver&.accept(self)
          node.parameters&.accept(self)
          node.body&.accept(self)
        end

        def visit_if_node(node)
          node.predicate.accept(self)
          node.statements&.accept(self)
          node.subsequent&.accept(self)
        end

        def visit_else_node(node)
          node.statements&.accept(self)
        end

        def visit_parentheses_node(node)
          node.body&.accept(self)
        end

        def visit_local_variable_write_node(node)
          node.value.accept(self)
        end

        def visit_instance_variable_write_node(node)
          node.value.accept(self)
        end

        def visit_interpolated_string_node(node)
          node.parts.each { |child| child.accept(self) }
        end

        def visit_embedded_statements_node(node)
          node.statements&.accept(self)
        end

        def visit_program_node(node)
          node.statements.accept(self)
        end

        def visit_constant_write_node(node)
          node.value.accept(self)
        end

        def visit_or_node(node)
          node.left.accept(self)
          node.right.accept(self)
        end

        def visit_and_node(node)
          node.left.accept(self)
          node.right.accept(self)
        end

        def visit_unless_node(node)
          node.predicate.accept(self)
          node.statements&.accept(self)
          node.else_clause&.accept(self)
        end

        def visit_return_node(node)
          node.arguments&.accept(self)
        end

        def visit_parameters_node(node)
          node.optionals.each { |child| child.accept(self) }
          node.keywords.each { |child| child.accept(self) }
        end

        def visit_block_parameters_node(node)
          node.parameters&.accept(self)
        end
      end

      # Lightweight visitor that checks if a `server_only` block contains a
      # bare `syncable_to` or `writable_by` policy call.
      class PolicyCallVisitor < FastVisitor
        attr_reader :found

        def initialize
          super()
          @found = false
        end

        def visit_call_node(node)
          return if @found

          if node.receiver.nil? && (node.name == :syncable_to || node.name == :writable_by)
            @found = true
            return
          end

          super
        end

        def visit_statements_node(node)
          node.body.each do |child|
            child.accept(self)
            break if @found
          end
        end
      end

      # Lightweight visitor that extracts only the first constant superclass
      # outside `server_only` blocks, used for unstaged STI checks.
      class SuperclassVisitor < FastVisitor
        attr_reader :superclass

        def initialize
          super()
          @superclass = nil
        end

        def visit_class_node(node)
          return if @superclass

          if node.superclass
            sup = extract_constant_segments(node.superclass)
            if sup
              @superclass = sup.join("::")
              return
            end
          end

          node.body&.accept(self)
        end

        def visit_call_node(node)
          return if @superclass
          return if node.receiver.nil? && node.name == :server_only && node.block

          super
        end

        def visit_statements_node(node)
          node.body.each do |child|
            child.accept(self)
            break if @superclass
          end
        end

        private

        def extract_constant_segments(node)
          case node
          when Prism::ConstantReadNode
            [node.name.to_s]
          when Prism::ConstantPathNode
            if node.parent.nil?
              [node.name.to_s]
            else
              parent = extract_constant_segments(node.parent)
              parent ? parent + [node.name.to_s] : nil
            end
          else
            nil
          end
        end
      end

      # Lightweight visitor for migration files that short-circuits as soon as
      # any DDL call or `execute` SQL string touches a reachable table.
      class MigrationTableVisitor < FastVisitor
        attr_reader :matched

        def initialize(target_tables)
          super()
          @target_tables = target_tables
          @matched = false
        end

        def visit_call_node(node)
          return if @matched

          if node.receiver.nil?
            name = node.name
            if DDL_TABLE_CALLS_SET.key?(name)
              args = node.arguments&.arguments
              if args
                first = args[0]
                if (first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)) &&
                    @target_tables.include?(first.unescaped)
                  @matched = true
                  return
                end
                if name == :rename_table
                  second = args[1]
                  if (second.is_a?(Prism::SymbolNode) || second.is_a?(Prism::StringNode)) &&
                      @target_tables.include?(second.unescaped)
                    @matched = true
                    return
                  end
                end
              end
            elsif name == :execute
              args = node.arguments&.arguments
              first = args && args[0]
              if first.is_a?(Prism::StringNode)
                first.unescaped.scan(SQL_TABLE_RE) do |match|
                  if @target_tables.include?(match[0])
                    @matched = true
                    return
                  end
                end
              end
            end
          end

          super
        end

        def visit_statements_node(node)
          node.body.each do |child|
            child.accept(self)
            break if @matched
          end
        end
      end

      # Extracts constant references, associations, renders, sync macros, and
      # dynamic patterns from a single Ruby AST while ignoring `server_only`.
      class FileVisitor < FastVisitor
        DYNAMIC = Object.new.freeze
        EMPTY_NAMESPACE = [].freeze

        attr_reader :constants, :associations, :renders, :layouts, :helper_decls,
                    :bare_calls, :includes, :superclass, :table_name, :abstract_class,
                    :syncable, :sync_window, :sync_scope_column, :sync_scope_policy,
                    :sync_file, :dynamic_warnings

        def initialize(rel_path:, is_view: false, is_helper: false,
                       collect_edges: true, collect_bare_calls: true, helper_method_names: nil,
                       collect_model_info: true, known_const_leaves: nil)
          super()
          @rel_path = rel_path
          @is_view = is_view
          @is_helper = is_helper
          @collect_edges = collect_edges
          @collect_bare_calls = collect_bare_calls
          @helper_method_names = helper_method_names
          @collect_model_info = collect_model_info
          @known_const_leaves = known_const_leaves
          @namespace = []
          @namespace_snapshot = EMPTY_NAMESPACE
          @constants = []
          @associations = []
          @renders = []
          @layouts = []
          @helper_decls = []
          @bare_calls = Set.new
          @includes = []
          @superclass = nil
          @table_name = nil
          @abstract_class = false
          @syncable = false
          @sync_window = nil
          @sync_scope_column = nil
          @sync_scope_policy = false
          @sync_file = false
          @dynamic_warnings = []
        end

        def visit_module_node(node)
          unless @collect_edges
            node.constant_path.accept(self)
            node.body&.accept(self)
            return
          end

          name = constant_node_segments(node.constant_path)
          if name
            prev = @namespace_snapshot
            @namespace.concat(name)
            @namespace_snapshot = @namespace.dup.freeze
          end
          super
        ensure
          if name
            @namespace.pop(name.length)
            @namespace_snapshot = prev
          end
        end

        def visit_class_node(node)
          if !@collect_edges && !@collect_model_info
            node.body&.accept(self)
            return
          end

          name = @collect_edges ? constant_node_segments(node.constant_path) : nil
          if node.superclass
            sup = constant_node_segments(node.superclass)
            if sup
              @superclass ||= sup.join("::") if @collect_model_info
              if @collect_edges
                @constants << {
                  segments: sup,
                  top_level: top_level_const?(node.superclass),
                  namespace: @namespace_snapshot,
                  line: node.superclass.location.start_line
                }
              end
            end
          end
          if name
            prev = @namespace_snapshot
            @namespace.concat(name)
            @namespace_snapshot = @namespace.dup.freeze
          end
          node.body&.accept(self)
        ensure
          if name
            @namespace.pop(name.length)
            @namespace_snapshot = prev
          end
        end

        def visit_constant_path_node(node)
          unless @collect_edges
            cur = node.parent
            cur = cur.parent while cur.is_a?(Prism::ConstantPathNode)
            cur.accept(self) if cur && !cur.is_a?(Prism::ConstantReadNode)
            return
          end

          segments = constant_node_segments(node)
          if segments
            @constants << {
              segments: segments,
              top_level: top_level_const?(node),
              namespace: @namespace_snapshot,
              line: node.location.start_line
            }
          else
            super
          end
        end

        def visit_constant_read_node(node)
          return unless @collect_edges
          return if @known_const_leaves && !@known_const_leaves.key?(node.name)

          @constants << {
            segments: [node.name.to_s],
            top_level: false,
            namespace: @namespace_snapshot,
            line: node.location.start_line
          }
        end

        def visit_call_node(node)
          receiver = node.receiver
          name = node.name

          if receiver.nil?
            # Strictly skip server_only blocks (only note syncable_to / writable_by policy presence).
            if name == :server_only && node.block
              @sync_scope_policy = true if @collect_model_info && block_calls_policy?(node.block)
              return
            end

            if @collect_model_info
              if name == :table_name=
                args = node.arguments&.arguments
                first = args && args[0]
                @table_name = first.unescaped if first.is_a?(Prism::StringNode)
              elsif name == :abstract_class=
                args = node.arguments&.arguments
                first = args && args[0]
                @abstract_class = true if first.is_a?(Prism::TrueNode)
              end
            end

            if @collect_bare_calls
              if @helper_method_names
                @bare_calls << name if @helper_method_names.key?(name)
              else
                @bare_calls << name.to_s
              end
            end

            inspect_bare_call(node, name)
          else
            if @collect_model_info && receiver.is_a?(Prism::SelfNode)
              if name == :table_name=
                args = node.arguments&.arguments
                first = args && args[0]
                @table_name = first.unescaped if first.is_a?(Prism::StringNode)
              elsif name == :abstract_class=
                args = node.arguments&.arguments
                first = args && args[0]
                @abstract_class = true if first.is_a?(Prism::TrueNode)
              end
            end

            case name
            when :constantize, :safe_constantize, :const_get
              record_dynamic_warning(name.to_s, node.location.start_line,
                "Dynamic constant lookup via #{name}; declare referenced classes in include: { models: [...] } if needed.")
            end
          end

          receiver&.accept(self)
          node.arguments&.accept(self)
          node.block&.accept(self)
        end

        private

        def block_calls_policy?(block_node)
          visitor = PolicyCallVisitor.new
          block_node.accept(visitor)
          visitor.found
        end

        def inspect_bare_call(node, name)
          case name
          when :include, :extend, :prepend
            return unless @collect_model_info

            args = node.arguments&.arguments
            return unless args

            args.each do |arg|
              segs = constant_node_segments(arg)
              next unless segs

              full = segs.join("::")
              @includes << full
              @syncable = true if full == "InstantRecord::Syncable" || full == "Syncable"
            end
          when :sync_window
            extract_sync_window(node) if @collect_model_info
          when :sync_scope
            return unless @collect_model_info

            args = node.arguments&.arguments
            arg = args && args[0]
            if arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode)
              @sync_scope_column = arg.unescaped
            end
          when :syncable_to, :writable_by
            @sync_scope_policy = true if @collect_model_info
          when :sync_file
            @sync_file = true if @collect_model_info
          when :belongs_to, :has_many, :has_one, :has_and_belongs_to_many
            extract_association(node) if @collect_edges
          when :render
            extract_render(node)
          when :layout
            extract_layout(node)
          when :helper
            extract_helper(node) if @collect_edges
          when :const_get
            record_dynamic_warning("const_get", node.location.start_line,
              "Dynamic constant lookup via const_get; declare referenced classes in include: { models: [...] } if needed.")
          end
        end

        def extract_sync_window(node)
          opts = extract_keyword_hash(node)
          limit = opts[:limit]
          return unless limit.is_a?(Integer) && limit.positive?

          partition_by = opts[:partition_by]&.to_s
          @sync_window = {
            "limit" => limit,
            "partition_by" => partition_by && !partition_by.empty? ? partition_by : nil
          }
        end

        def extract_association(node)
          args = node.arguments&.arguments
          first = args && args[0]
          return unless first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)

          opts = extract_keyword_hash(node)
          return if opts[:polymorphic] == true

          assoc_name = first.unescaped
          through = opts.key?(:through)
          source_opt = opts[:source]
          target =
            if opts[:class_name].is_a?(String) && !opts[:class_name].empty?
              opts[:class_name]
            elsif through && (source_opt.is_a?(String) || source_opt.is_a?(Symbol))
              ActiveSupport::Inflector.classify(source_opt.to_s)
            else
              ActiveSupport::Inflector.classify(assoc_name)
            end

          @associations << {
            name: assoc_name,
            class_name: target.delete_prefix("::"),
            namespace: @namespace_snapshot,
            through: through,
            line: node.location.start_line
          }
        end

        def extract_render(node)
          args = node.arguments&.arguments
          first = args && args[0]
          return unless first

          # Read every option before anything is recorded: this raises on a key that is not valid text.
          opts = extract_keyword_hash(node)
          return if !opts.empty? && NON_TEMPLATE_RENDER_KEYS.any? { |key| opts.key?(key) }

          line = node.location.start_line
          in_template = @is_view || @is_helper

          if opts.key?(:partial)
            record_render(:partial, opts[:partial], line) ||
              record_dynamic_warning("render", line, "Dynamic partial render; declare targets in include: { partials: [...] }.")
          elsif opts.key?(:template)
            record_render(:template, opts[:template], line) ||
              record_dynamic_warning("render", line, "Dynamic template render; declare targets in include: { views: [...] }.")
          elsif opts.key?(:action)
            record_render(:template, opts[:action], line)
          elsif !hash_node?(first)
            record_render(in_template ? :partial : :template, literal_name(first), line) ||
              record_dynamic_warning("render", line,
                "Dynamic render expression; declare targets in include: { partials: [...] } or include: { views: [...] }.")
          end

          # Independently handle `layout:` option (e.g. `render partial: "row", layout: "card"`).
          layout = opts[:layout]
          if in_template || opts.key?(:partial)
            record_render(:partial, layout, line)
          elsif layout.is_a?(String) || layout.is_a?(Symbol)
            @layouts << { target: layout.to_s, line: line }
          end
        end

        def record_render(kind, target, line)
          return false unless target.is_a?(String) || target.is_a?(Symbol)

          @renders << { kind: kind, target: target.to_s, line: line }
          true
        end

        # The text of a string or symbol node. Unlike +literal+, keeps the source's
        # encoding: an ASCII Symbol drops it, and messages quote the name by it.
        def literal_name(node)
          node.unescaped if node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode)
        end

        def hash_node?(node)
          node.is_a?(Prism::KeywordHashNode) || node.is_a?(Prism::HashNode)
        end

        def extract_layout(node)
          args = node.arguments&.arguments
          first = args && args[0]
          return unless first.is_a?(Prism::StringNode) || first.is_a?(Prism::SymbolNode)

          @layouts << { target: first.unescaped, line: node.location.start_line }
        end

        def extract_helper(node)
          args = node.arguments&.arguments
          return unless args

          args.each do |arg|
            case arg
            when Prism::SymbolNode, Prism::StringNode
              @helper_decls << { kind: :name, value: arg.unescaped, line: node.location.start_line }
            else
              segs = constant_node_segments(arg)
              @helper_decls << { kind: :const, value: segs.join("::"), line: node.location.start_line } if segs
            end
          end
        end

        def record_dynamic_warning(kind, line, message)
          @dynamic_warnings << {
            "level" => "warning",
            "kind" => kind,
            "file" => @rel_path,
            "line" => line,
            "message" => message
          }
        end

        def constant_node_segments(node)
          case node
          when Prism::ConstantReadNode
            [node.name.to_s]
          when Prism::ConstantPathNode
            if node.parent.nil?
              [node.name.to_s]
            else
              parent = constant_node_segments(node.parent)
              parent ? parent + [node.name.to_s] : nil
            end
          else
            nil
          end
        end

        def top_level_const?(node)
          cur = node
          cur = cur.parent while cur.is_a?(Prism::ConstantPathNode) && cur.parent
          cur.is_a?(Prism::ConstantPathNode) && cur.parent.nil?
        end

        def extract_keyword_hash(call)
          opts = {}
          args = call.arguments&.arguments
          return opts unless args

          args.each do |arg|
            next unless hash_node?(arg)

            arg.elements.each do |assoc|
              next unless assoc.is_a?(Prism::AssocNode)

              key = literal(assoc.key)
              next unless key.is_a?(Symbol) || key.is_a?(String)

              val = literal(assoc.value)
              opts[key.to_sym] = val.nil? ? DYNAMIC : val
            end
          end
          opts
        end

        def literal(node)
          case node
          when Prism::SymbolNode then node.unescaped.to_sym
          when Prism::StringNode then node.unescaped
          when Prism::IntegerNode, Prism::FloatNode then node.value
          when Prism::TrueNode then true
          when Prism::FalseNode then false
          when Prism::NilNode then false
          else nil
          end
        end
      end

      def self.trace(source_root:, route_analysis:, overrides: nil, native: false, migration_paths: nil, overlay_dir: nil)
        new(
          source_root: source_root,
          route_analysis: route_analysis,
          overrides: overrides,
          native: native,
          migration_paths: migration_paths,
          overlay_dir: overlay_dir
        ).trace
      end

      # +overlay_dir+ holds files that replace the app's own under app/ once it
      # is staged (AppStage copies it over last). The trace reads those in place
      # of the originals, so what is staged is what the staged code reaches: a
      # partial only the replaced controller rendered is left behind.
      def initialize(source_root:, route_analysis:, overrides: nil, native: false, migration_paths: nil, overlay_dir: nil)
        @source_root = File.expand_path(source_root.to_s)
        @source_root_prefix = "#{@source_root}#{File::SEPARATOR}"
        @source_root_realpath_prefix = nil
        @overlay_dir = overlay_dir && File.directory?(overlay_dir) ? File.expand_path(overlay_dir.to_s) : nil
        @route_analysis = route_analysis
        @island_mode = !!route_analysis.has_local_first
        @overrides = Manifest.merge_overrides(route_analysis.overrides, overrides)
        @native = native
        @migration_paths = migration_paths
        @acronyms_empty = ActiveSupport::Inflector.inflections.acronyms.empty?

        @staged_controllers = Set.new
        @staged_models = Set.new
        @staged_views = Set.new
        @staged_helpers = Set.new
        @staged_screens = Set.new
        @staged_extra_files = Set.new

        @visited = Set.new
        @queue = []
        @model_metadata = {}
        @concern_syncable = Set.new
        @diagnostics = []
        @errors = []
        @safe_source_files = {}
        @parsed_cache = {}
        @const_resolve_cache = {}
      end

      def trace
        index_app_files!
        if @island_mode
          seed_island!
        else
          seed_full_app!
        end
        process_queue!
        resolve_model_inheritance!
        check_sti_subclasses!
        migrations, manifest_migrations = filter_migrations

        unless @errors.empty?
          raise BuildError, format_errors(@errors)
        end

        Result.new(
          controllers: @staged_controllers.to_a.sort,
          models: @staged_models.to_a.sort,
          views: @staged_views.to_a.sort,
          helpers: @staged_helpers.to_a.sort,
          screens: @staged_screens.to_a.sort,
          migrations: migrations,
          manifest_migrations: manifest_migrations,
          extra_files: @staged_extra_files.to_a.sort,
          model_metadata: @model_metadata,
          diagnostics: @diagnostics.uniq
        )
      end

      private

      def index_app_files!
        @controller_files = glob_dir_rb("app/controllers")
        @model_files = glob_dir_rb("app/models")
        @helper_files = glob_dir_rb("app/helpers")
        @view_files =
          if File.directory?("#{@source_root_prefix}app/views")
            glob_rel("app/views/**/*").select { |rel| File.file?("#{@source_root_prefix}#{rel}") }
          else
            []
          end
        @screen_files = glob_dir_rb("app/screens")
        @non_ascii_view = @view_files.find { |rel| !rel.ascii_only? }

        if @island_mode
          index_view_files!
          index_stageable_constants!
          index_unstaged_constants!
          index_known_const_leaves!
          index_helper_methods!
        else
          inc = @overrides[:include]
          if inc["views"].any? || inc["partials"].any?
            index_view_files!
          else
            @views_by_stem = {}
          end
          if inc["models"].any? || inc["controllers"].any? || inc["helpers"].any?
            index_stageable_constants!
          else
            @stageable_constants = {}
          end
          @unstaged_constants = {}
          @known_const_leaves = nil
          @helper_methods = {}
          @pending_helpers = []
          @candidate_helper_indices = {}
          @possible_helper_methods = {}
        end
      end

      def glob_dir_rb(rel_dir)
        File.directory?("#{@source_root_prefix}#{rel_dir}") ? glob_rel("#{rel_dir}/**/*.rb") : []
      end

      def index_known_const_leaves!
        leaves = {}
        @stageable_constants.each_key do |name|
          sep = name.byterindex("::")
          leaf = sep ? name.byteslice(sep + 2, name.bytesize - sep - 2) : name
          leaves[leaf.to_sym] = true
        end
        @unstaged_constants.each_key do |name|
          sep = name.byterindex("::")
          leaf = sep ? name.byteslice(sep + 2, name.bytesize - sep - 2) : name
          leaves[leaf.to_sym] = true
        end
        @known_const_leaves = leaves
      end

      # Map constant names -> relative file paths for stageable categories.
      def index_stageable_constants!
        @stageable_constants = {}
        register_constants(@controller_files, "app/controllers/")
        register_constants(@model_files, "app/models/", "app/models/concerns/")
        register_constants(@helper_files, "app/helpers/")
        register_constants(@controller_files, "app/controllers/concerns/")
        register_constants(@screen_files, "app/screens/") if @native
      end

      # Names each file after every one of +prefixes+ it lies under. The first file to take a name keeps it.
      def register_constants(files, *prefixes)
        files.each do |rel|
          prefixes.each do |prefix|
            @stageable_constants[const_from_rel(rel, prefix)] ||= rel if rel.start_with?(prefix)
          end
        end
      end

      # Index unstaged app directories (jobs, services, mailers, channels, non-native screens, lib)
      # for crisp missing-symbol diagnostics without re-traversing already-globbed app subtrees.
      def index_unstaged_constants!
        @unstaged_constants = {}
        app_dir = File.join(@source_root, "app")
        if File.directory?(app_dir)
          unstaged_app = []
          Dir.each_child(app_dir) do |entry|
            next if entry.start_with?(".")
            next if entry == "controllers" || entry == "models" || entry == "helpers"
            next if @native && entry == "screens"

            if entry == "views"
              @view_files.each { |rel| unstaged_app << rel if rel.end_with?(".rb") }
            elsif entry == "screens"
              unstaged_app.concat(@screen_files)
            else
              full = File.join(app_dir, entry)
              if !File.symlink?(full) && File.directory?(full)
                Dir.glob("#{entry}/**/*.rb", base: app_dir).each { |rel| unstaged_app << "app/#{rel}" }
              elsif entry.end_with?(".rb") && File.file?(full)
                unstaged_app << "app/#{entry}"
              end
            end
          end

          unstaged_app.sort!
          unstaged_app.each do |rel|
            slash = rel.byteindex("/", 4)
            top_dir = slash ? rel.byteslice(4, slash - 4) : rel.byteslice(4, rel.bytesize - 4)
            @unstaged_constants[const_from_rel(rel, "app/#{top_dir}/")] ||= rel
          end
        end

        lib_dir = File.join(@source_root, "lib")
        if File.directory?(lib_dir)
          glob_rel("lib/**/*.rb").each do |rel|
            @unstaged_constants[const_from_rel(rel, "lib/")] ||= rel unless rel.start_with?("lib/tasks/")
          end
        end
      end

      # Index public helper methods -> helper rel path so views/helpers calling one automatically stage it.
      # For standard UTF-8 helpers without comments/continuations directly after `def`, defer Prism
      # parsing until a bare call actually matches one of the file's candidate `def` names.
      def index_helper_methods!
        @helper_methods = {}
        @pending_helpers = []
        @candidate_helper_indices = {}
        @possible_helper_methods = {}

        @helper_files.each_with_index do |rel, order_idx|
          full = "#{@source_root_prefix}#{rel}"
          source = File.binread(full)
          source.force_encoding(Encoding::UTF_8)

          if ascii_compatible_source?(source)
            next unless source.include?("def")

            if !source.include?("=begin") && !HELPER_DEF_TRICKY_RE.match?(source)
              matched_any = false
              source.scan(HELPER_DEF_CANDIDATE_RE) do |match|
                sym = match[0].to_sym
                (@candidate_helper_indices[sym] ||= []) << order_idx
                @possible_helper_methods[sym] = true
                matched_any = true
              end
              @pending_helpers[order_idx] = [rel, full, source] if matched_any
              next
            end
          end

          parse_and_index_helper!(rel, full, source)
        end
      end

      def parse_and_index_helper!(rel, full, source)
        parsed = Prism.parse(source)
        @parsed_cache[full] = parsed
        return unless parsed.success?

        extract_public_helper_defs(parsed.value).each do |method_name|
          list = (@helper_methods[method_name] ||= [])
          list << rel
          list.sort! if list.length > 1
          @possible_helper_methods[method_name] = true
        end
      end

      def resolve_helper_method(method_name)
        if (indices = @candidate_helper_indices.delete(method_name))
          indices.each do |idx|
            entry = @pending_helpers[idx]
            next unless entry

            @pending_helpers[idx] = nil
            parse_and_index_helper!(entry[0], entry[1], entry[2])
          end
        end
        @helper_methods[method_name]
      end

      # Files each view under its path and under that path cut at each dot, so
      # both "index" and "index.html" find index.html.erb.
      def index_view_files!
        @views_by_stem = {}
        @view_files.each do |rel|
          stem = rel
          loop do
            (@views_by_stem[stem] ||= []) << rel
            dot = stem.rindex(".")
            break unless dot && dot > 0

            stem = stem[0, dot]
          end
        end
      end

      def seed_island!
        enqueue_if_exists("app/controllers/application_controller.rb")
        enqueue_if_exists("app/models/application_record.rb")
        enqueue_if_exists("app/helpers/application_helper.rb")
        glob_rel("app/views/layouts/application.*").each { |rel| enqueue(rel) }

        @route_analysis.local_routes.each do |route|
          controller = route["controller"]
          action = route["action"]
          next if controller.nil? || controller.empty?

          ctrl_rel = "app/controllers/#{controller}_controller.rb"
          if safe_source_file?(ctrl_rel)
            enqueue(ctrl_rel)
          else
            @errors << "Missing controller for local_first route #{route['method']} #{route['path']} " \
                       "-> #{controller}##{action} (expected #{ctrl_rel})."
            next
          end

          if action && !action.empty?
            find_view_files(controller, action, partial: false).each { |rel| enqueue(rel) }
          end

          enqueue_if_exists("app/helpers/#{controller}_helper.rb")
          top_ns = controller.split("/").first
          enqueue_if_exists("app/helpers/#{top_ns}_helper.rb") if controller.include?("/")
        end

        @screen_files.each { |rel| enqueue(rel) } if @native

        apply_explicit_includes!
      end

      def seed_full_app!
        @controller_files.each { |rel| enqueue(rel) }
        @model_files.each { |rel| enqueue(rel) }
        @helper_files.each { |rel| enqueue(rel) }
        @view_files.each { |rel| enqueue(rel) }
        @screen_files.each { |rel| enqueue(rel) } if @native
        apply_explicit_includes!
      end

      def apply_explicit_includes!
        include_each("models", "app/models/") { |entry| resolve_model_override(entry) }
        include_each("controllers", "app/controllers/") { |entry| resolve_controller_override(entry) }
        include_each("helpers", "app/helpers/") { |entry| resolve_helper_override(entry) }
        include_each("views", "app/views/") { |entry| resolve_view_override(entry, partial: false) }
        include_each("partials", "app/views/") { |entry| resolve_view_override(entry, partial: true) }

        @overrides[:include]["files"].each do |entry|
          rel = sanitize_relative_path(entry)
          if rel && safe_source_file?(rel)
            @staged_extra_files << rel
            enqueue(rel) if rel.end_with?(".rb", ".erb")
          else
            @errors << "Explicit include.files entry #{entry.inspect} does not exist inside #{@source_root}."
          end
        end
      end

      # Enqueues the file or files the block finds for each entry of an include list.
      def include_each(kind, dir)
        @overrides[:include][kind].each do |entry|
          found = Array(yield(entry))
          @errors << "Explicit include.#{kind} entry #{entry.inspect} was not found under #{dir}." if found.empty?
          found.each { |rel| enqueue(rel) }
        end
      end

      def process_queue!
        while (rel = @queue.shift)
          next if @visited.include?(rel)

          @visited << rel
          categorize(rel)

          full = overlaid(rel) || File.join(@source_root, rel)
          next unless File.file?(full)

          if rel.end_with?(".rb")
            visit_ruby_file(rel, full)
          elsif rel.end_with?(".erb")
            visit_erb_file(rel, full)
          end
        end
      end

      # The overlay's replacement for an app file, if it has one.
      def overlaid(rel)
        return unless @overlay_dir && rel.start_with?("app/")

        path = File.join(@overlay_dir, rel.delete_prefix("app/"))
        path if File.file?(path)
      end

      def visit_ruby_file(rel, full)
        is_model_concern = rel.start_with?("app/models/concerns/")
        is_model = !is_model_concern && rel.start_with?("app/models/")
        is_helper = rel.start_with?("app/helpers/")

        parsed = @parsed_cache.delete(full)
        unless parsed
          source = File.binread(full)
          source.force_encoding(Encoding::UTF_8)
          if !@island_mode && !is_model && ascii_compatible_source?(source)
            inspect_re = @non_ascii_view ? FULL_APP_INSPECT_WITH_LAYOUT_RE : FULL_APP_INSPECT_RE
            needs_ast = inspect_re.match?(source) || (is_model_concern && source.include?("Syncable"))
            unless needs_ast
              return if Prism.parse_success?(source)

              parsed = Prism.parse(source)
              errors = parsed.errors.map { |e| "line #{e.location.start_line}: #{e.message}" }.join("; ")
              @errors << "Syntax error in #{rel}: #{errors}"
              return
            end
          end
          parsed = Prism.parse(source)
        end

        unless parsed.success?
          errors = parsed.errors.map { |e| "line #{e.location.start_line}: #{e.message}" }.join("; ")
          @errors << "Syntax error in #{rel}: #{errors}"
          return
        end

        track_bare_calls = @island_mode && (is_helper || rel.start_with?("app/controllers/")) && !@possible_helper_methods.empty?
        visitor = FileVisitor.new(
          rel_path: rel,
          is_view: false,
          is_helper: is_helper,
          collect_edges: @island_mode,
          collect_bare_calls: track_bare_calls,
          helper_method_names: track_bare_calls ? @possible_helper_methods : nil,
          collect_model_info: is_model || is_model_concern,
          known_const_leaves: @known_const_leaves
        )
        parsed.value.accept(visitor)

        @diagnostics.concat(visitor.dynamic_warnings)
        if is_model_concern
          if visitor.syncable
            @concern_syncable << const_from_rel(rel, "app/models/concerns/")
            @concern_syncable << const_from_rel(rel, "app/models/")
          end
        elsif is_model
          record_model_metadata(rel, visitor)
        end

        if @island_mode
          resolve_visitor_edges!(rel, visitor, is_view: false, is_helper: is_helper)
        elsif @non_ascii_view
          check_view_encoding_compat!(rel, visitor, is_view: false)
        end
      end

      def visit_erb_file(rel, full)
        erb_source = File.binread(full)
        erb_source.force_encoding(Encoding::UTF_8)
        return if erb_source.valid_encoding? && !erb_source.include?("<%")

        parsed = nil
        if erb_source.valid_encoding?
          wrapped = compile_erb_for_trace(erb_source)

          if !@island_mode
            inspect_re = @non_ascii_view ? FULL_APP_INSPECT_WITH_LAYOUT_RE : FULL_APP_INSPECT_RE
            unless inspect_re.match?(wrapped)
              return if Prism.parse_success?(wrapped, line: 0)

              parsed, ruby_source = parse_erb_with_erubi(rel, erb_source)
              return unless parsed
              return unless inspect_re.match?(ruby_source)
            end
          end

          if parsed.nil?
            parsed = Prism.parse(wrapped, line: 0)
            unless parsed.success?
              parsed, = parse_erb_with_erubi(rel, erb_source)
              return unless parsed
            end
          end
        else
          parsed, = parse_erb_with_erubi(rel, erb_source)
          return unless parsed
        end

        track_bare_calls = @island_mode && !@possible_helper_methods.empty?
        visitor = FileVisitor.new(
          rel_path: rel,
          is_view: true,
          collect_edges: @island_mode,
          collect_bare_calls: track_bare_calls,
          helper_method_names: track_bare_calls ? @possible_helper_methods : nil,
          collect_model_info: false,
          known_const_leaves: @known_const_leaves
        )
        parsed.value.accept(visitor)

        @diagnostics.concat(visitor.dynamic_warnings)
        if @island_mode
          resolve_visitor_edges!(rel, visitor, is_view: true, is_helper: false)
        elsif @non_ascii_view
          check_view_encoding_compat!(rel, visitor, is_view: true)
        end
      end

      # Compiles valid UTF-8 ERB into a minimal Ruby method body for Prism
      # analysis while preserving exact 1-based line numbers, Erubi trim rules,
      # and comment/syntax boundaries. Any syntax failure falls back to
      # ActionView::Template::Handlers::ERB::Erubi for exact error messages.
      def compile_erb_for_trace(input)
        src = +"def _instant_record_template\n"
        char_pos = 0
        byte_pos = 0
        pending_nl = 0
        is_bol = true
        total_bytes = input.bytesize

        while (m = ERB_REGEXP.match(input, char_pos))
          m_byte_begin = m.bytebegin(0)
          ind_b = m.bytebegin(1)
          ch = ind_b ? input.getbyte(ind_b) : nil

          has_lspace = false
          text_end = m_byte_begin
          unless ch == 61 # "="
            if m_byte_begin == byte_pos
              has_lspace = is_bol
            elsif input.getbyte(m_byte_begin - 1) == 10
              has_lspace = true
            else
              idx = m_byte_begin - 1
              while idx >= byte_pos
                b = input.getbyte(idx)
                break unless b == 32 || b == 9

                idx -= 1
              end
              if idx >= byte_pos && input.getbyte(idx) == 10
                has_lspace = true
                text_end = idx + 1
              elsif idx < byte_pos && is_bol
                has_lspace = true
                text_end = byte_pos
              end
            end
          end

          r_b = m.bytebegin(4)
          r_e = r_b ? m.byteend(4) : nil
          has_rspace = !r_b.nil?
          is_bol = has_rspace

          if text_end > byte_pos
            if text_end - byte_pos == 1 && input.getbyte(byte_pos) == 10
              pending_nl += 1
            else
              nl = pending_nl + count_newlines(input, byte_pos, text_end)
              pending_nl = 0
              append_erb_text_placeholder(src, nl)
            end
          end

          code = m[2]
          if ch == 61 # "="
            if pending_nl > 0
              append_erb_text_placeholder(src, pending_nl)
              pending_nl = 0
            end
            if ERB_BLOCK_EXPR.match?(code)
              src << " @_= " << code << ";"
            else
              src << " @_=(" << code << ");"
            end
            if has_rspace && m.bytebegin(3).nil?
              if r_e - r_b == 1 && input.getbyte(r_b) == 10
                pending_nl += 1
              else
                nl = pending_nl + count_newlines(input, r_b, r_e)
                pending_nl = 0
                append_erb_text_placeholder(src, nl)
              end
            end
          elsif ch.nil? || ch == 45 # nil or "-"
            if has_lspace && has_rspace
              if pending_nl > 0
                append_erb_text_placeholder(src, pending_nl)
                pending_nl = 0
              end
              src << input.byteslice(text_end, m_byte_begin - text_end) if text_end < m_byte_begin
              src << code
              src << (r_e - r_b == 1 && input.getbyte(r_b) == 10 ? "\n" : input.byteslice(r_b, r_e - r_b))
            else
              if has_lspace && text_end < m_byte_begin
                nl = pending_nl
                pending_nl = 0
                append_erb_text_placeholder(src, nl)
              end
              if pending_nl > 0
                append_erb_text_placeholder(src, pending_nl)
                pending_nl = 0
              end
              src << code
              src << ";" unless code.getbyte(-1) == 10
              if has_rspace
                if r_e - r_b == 1 && input.getbyte(r_b) == 10
                  pending_nl += 1
                else
                  nl = pending_nl + count_newlines(input, r_b, r_e)
                  pending_nl = 0
                  append_erb_text_placeholder(src, nl)
                end
              end
            end
          elsif ch == 35 # "#"
            n = code.count("\n") + (has_rspace ? 1 : 0)
            if has_lspace && has_rspace
              if pending_nl > 0
                append_erb_text_placeholder(src, pending_nl)
                pending_nl = 0
              end
              src << (n > 0 ? (ERB_NEWLINES[n] || ("\n" * n)) : ";")
            else
              if has_lspace && text_end < m_byte_begin
                nl = pending_nl
                pending_nl = 0
                append_erb_text_placeholder(src, nl)
              end
              if pending_nl > 0
                append_erb_text_placeholder(src, pending_nl)
                pending_nl = 0
              end
              src << (n > 0 ? (ERB_NEWLINES[n] || ("\n" * n)) : ";")
              if has_rspace
                if r_e - r_b == 1 && input.getbyte(r_b) == 10
                  pending_nl += 1
                else
                  nl = pending_nl + count_newlines(input, r_b, r_e)
                  pending_nl = 0
                  append_erb_text_placeholder(src, nl)
                end
              end
            end
          elsif ch == 37 # "%"
            nl = pending_nl + count_newlines(input, m.bytebegin(2), m.byteend(0))
            pending_nl = 0
            append_erb_text_placeholder(src, nl)
          end

          char_pos = m.end(0)
          byte_pos = m.byteend(0)
        end

        if byte_pos < total_bytes
          if total_bytes - byte_pos == 1 && input.getbyte(byte_pos) == 10
            pending_nl += 1
          else
            nl = pending_nl + count_newlines(input, byte_pos, total_bytes)
            pending_nl = 0
            append_erb_text_placeholder(src, nl)
          end
        end

        src << "\n" unless src.getbyte(-1) == 10
        append_erb_text_placeholder(src, pending_nl) if pending_nl > 0
        src << "\nend\n"
        src
      end

      def count_newlines(str, from_byte, to_byte)
        n = 0
        idx = from_byte
        while idx < to_byte && (nl = str.byteindex("\n", idx)) && nl < to_byte
          n += 1
          idx = nl + 1
        end
        n
      end

      def append_erb_text_placeholder(src, newlines)
        if newlines == 0
          src << " '';"
        else
          src << " '"
          src << (ERB_NEWLINES[newlines] || ("\n" * newlines))
          src << "';"
        end
      end

      def parse_erb_with_erubi(rel, erb_source)
        ruby_source = ActionView::Template::Handlers::ERB::Erubi.new(erb_source).src
        # Wrap in a method body so `yield` in layouts is valid Ruby, preserving 1-based line numbers via line: 0.
        parsed = Prism.parse("def _instant_record_template\n#{ruby_source}\nend\n", line: 0)
        unless parsed.success?
          errors = parsed.errors.map { |e| "line #{e.location.start_line}: #{e.message}" }.join("; ")
          @errors << "ERB syntax error in #{rel}: #{errors}"
          return [nil, ruby_source]
        end
        [parsed, ruby_source]
      end

      def check_view_encoding_compat!(rel, visitor, is_view:)
        if visitor.renders.any?
          current_dir = view_dir_for(rel, is_view: is_view)
          visitor.renders.each do |render_ref|
            resolve_render_target(render_ref[:target], current_dir, partial: render_ref[:kind] == :partial)
          end
        end
        visitor.layouts.each do |layout_ref|
          find_view_files("layouts", layout_ref[:target], partial: false)
        end
      end

      def resolve_visitor_edges!(rel, visitor, is_view:, is_helper:)
        # 1. Constant references: check exact/longer matches across BOTH tables before falling back to prefixes.
        visitor.constants.each do |ref|
          kind, target_rel = resolve_constant_with_precedence(ref)
          if kind == :stageable
            enqueue(target_rel)
          elsif kind == :unstaged && @island_mode && !@staged_extra_files.include?(target_rel)
            const_name = ref[:segments].join("::")
            @errors << "Missing symbol #{const_name} referenced at #{rel}:#{ref[:line]} — " \
                       "defined in #{target_rel} (outside local-first island). " \
                       "Wrap server-only code in `server_only do ... end` or add it to `include: { files: [#{target_rel.inspect}] }`."
          end
        end

        # 2. ActiveRecord associations -> stage target model or flag missing model.
        visitor.associations.each do |assoc|
          assoc_ref = { segments: assoc[:class_name].split("::"), top_level: false, namespace: assoc[:namespace] }
          model_rel = lookup_constant(@stageable_constants, assoc_ref)
          if model_rel
            enqueue(model_rel)
          elsif @island_mode && !assoc[:through]
            expected = "app/models/#{ActiveSupport::Inflector.underscore(assoc[:class_name])}.rb"
            unless safe_source_file?(expected)
              @errors << "Missing model #{assoc[:class_name]} for association :#{assoc[:name]} at #{rel}:#{assoc[:line]} " \
                         "(expected #{expected})."
            end
          end
        end

        # 3. Render calls -> stage matching partials/templates or flag missing template.
        if visitor.renders.any?
          current_dir = view_dir_for(rel, is_view: is_view)
          visitor.renders.each do |render_ref|
            is_partial = render_ref[:kind] == :partial
            matches = resolve_render_target(render_ref[:target], current_dir, partial: is_partial)
            if matches.any?
              matches.each { |path| enqueue(path) }
            elsif @island_mode
              kind_label = is_partial ? "partial" : "template"
              hint_key = is_partial ? "partials" : "views"
              @errors << "Missing #{kind_label} #{render_ref[:target].inspect} rendered at #{rel}:#{render_ref[:line]} " \
                         "(searched under app/views/#{current_dir}). Add the file or declare include: { #{hint_key}: [...] }."
            end
          end
        end

        # 4. Controller layout declarations.
        visitor.layouts.each do |layout_ref|
          matches = find_view_files("layouts", layout_ref[:target], partial: false)
          if matches.any?
            matches.each { |path| enqueue(path) }
          elsif @island_mode
            @errors << "Missing layout #{layout_ref[:target].inspect} declared at #{rel}:#{layout_ref[:line]} " \
                       "(expected app/views/layouts/#{layout_ref[:target]}.html.erb)."
          end
        end

        # 5. Controller helper declarations.
        visitor.helper_decls.each do |decl|
          helper_rel =
            if decl[:kind] == :name
              resolve_helper_override(decl[:value])
            else
              candidate = @stageable_constants[decl[:value]]
              candidate&.start_with?("app/helpers/") ? candidate : nil
            end
          if helper_rel
            enqueue(helper_rel)
          elsif @island_mode
            @errors << "Missing helper #{decl[:value].inspect} declared at #{rel}:#{decl[:line]}."
          end
        end

        # 6. Helper method calls in views, controllers, and helpers -> stage helper that defines them.
        if !visitor.bare_calls.empty? && (is_view || is_helper || rel.start_with?("app/controllers/"))
          visitor.bare_calls.each do |method_name|
            helpers = resolve_helper_method(method_name)
            helpers.each { |helper_rel| enqueue(helper_rel) } if helpers
          end
        end
      end

      def record_model_metadata(rel, visitor)
        model_name = const_from_rel(rel, "app/models/")
        sync_scope =
          if visitor.sync_scope_column || visitor.sync_scope_policy
            { "column" => visitor.sync_scope_column, "policy" => visitor.sync_scope_policy }
          end

        @model_metadata[model_name] = {
          "name" => model_name,
          "explicit_table_name" => visitor.table_name,
          "table" => nil,
          "file" => rel,
          "superclass" => visitor.superclass,
          "abstract_class" => visitor.abstract_class || model_name == "ApplicationRecord",
          "includes" => visitor.includes,
          "active_record" => false,
          "syncable" => visitor.syncable,
          "sync_window" => visitor.sync_window,
          "sync_scope" => sync_scope,
          "sync_file" => visitor.sync_file
        }
      end

      # Post-BFS inheritance resolution: handles multi-level STI, abstract base
      # models, and Syncable inherited via superclass or concern.
      def resolve_model_inheritance!
        @model_metadata.each do |name, meta|
          chain = superclass_chain(name)
          is_ar = meta["syncable"] ||
            chain.any? { |sup| sup == "ApplicationRecord" || sup == "ActiveRecord::Base" }
          meta["active_record"] = is_ar

          # Propagate Syncable from included concerns or concrete/abstract ancestors.
          unless meta["syncable"]
            if meta["includes"].any? { |inc| @concern_syncable.include?(inc) } ||
                chain.any? { |sup| @model_metadata.dig(sup, "syncable") }
              meta["syncable"] = true
            end
          end

          # Resolve table name: abstract models own no table; STI children share
          # their highest concrete ActiveRecord ancestor's table.
          next unless is_ar && !meta["abstract_class"]

          meta["table"] =
            if meta["explicit_table_name"]
              meta["explicit_table_name"]
            else
              concrete_ancestors = chain.select do |sup|
                sup_meta = @model_metadata[sup]
                sup_meta && !sup_meta["abstract_class"]
              end
              base = concrete_ancestors.last
              if base
                @model_metadata[base]["explicit_table_name"] || ActiveSupport::Inflector.tableize(base)
              else
                ActiveSupport::Inflector.tableize(name)
              end
            end
        end
      end

      def superclass_chain(model_name)
        chain = []
        seen = Set.new([model_name])
        cur = @model_metadata.dig(model_name, "superclass")
        while cur && !seen.include?(cur)
          seen << cur
          chain << cur
          cur = @model_metadata.dig(cur, "superclass")
        end
        chain
      end

      # Warn if a staged concrete model has STI subclasses in app/models/ that weren't staged.
      def check_sti_subclasses!
        return unless @island_mode

        concrete_staged = @model_metadata.each_with_object(Set.new) do |(name, meta), set|
          set << name unless meta["abstract_class"]
        end
        return if concrete_staged.empty?

        unstaged_models = @model_files.reject { |rel| @staged_models.include?(rel) || rel.start_with?("app/models/concerns/") }
        return if unstaged_models.empty?

        leaves = concrete_staged.map { |name| name.split("::").last }.uniq
        leaf_pattern = word_bounded_union(leaves)
        subclasses_by_parent = Hash.new { |h, k| h[k] = [] }

        unstaged_models.each do |rel|
          full = "#{@source_root_prefix}#{rel}"
          source = File.binread(full)
          source.force_encoding(Encoding::UTF_8)
          if ascii_compatible_source?(source)
            next unless source.include?("<") && leaf_pattern.match?(source)
          end

          parsed = Prism.parse(source)
          next unless parsed.success?

          visitor = SuperclassVisitor.new
          parsed.value.accept(visitor)
          if visitor.superclass && concrete_staged.include?(visitor.superclass)
            subclasses_by_parent[visitor.superclass] << const_from_rel(rel, "app/models/")
          end
        end

        subclasses_by_parent.each do |parent, kids|
          kids.sort!
          @diagnostics << {
            "level" => "warning",
            "kind" => "sti_subclass",
            "file" => @model_metadata.dig(parent, "file"),
            "line" => 1,
            "message" => "Model #{parent} has unstaged subclass(es) #{kids.join(', ')}. " \
                         "If using STI, add include: { models: #{kids.inspect} }."
          }
        end
      end

      def filter_migrations
        dirs = Array(@migration_paths || [File.join(@source_root, "db/migrate")])
        all_files = dirs.flat_map do |dir|
          next [] unless File.directory?(dir)

          Dir.glob("[0-9]*_*.rb", base: dir).map { |name| File.join(dir, name) }
        end.uniq.sort_by { |file| File.basename(file).to_i }

        unless @island_mode
          return [all_files, all_files.map { |f| manifest_migration_label(f) }]
        end

        reachable_tables = FRAMEWORK_TABLES.to_set
        @model_metadata.each_value do |meta|
          reachable_tables << meta["table"] if meta["table"]
        end

        can_prefilter_tables = reachable_tables.none?(&:empty?)
        table_pattern = can_prefilter_tables ? word_bounded_union(reachable_tables.to_a) : nil

        explicit = @overrides[:include]["migrations"]
        matched_explicit = Set.new

        kept = all_files.select do |file|
          unless explicit.empty?
            basename = File.basename(file)
            version = basename.to_i.to_s
            rel = manifest_migration_label(file)

            hit = explicit.find { |item| item == version || item == basename || item == rel || basename.start_with?("#{item}_") }
            if hit
              matched_explicit << hit
              next true
            end
          end

          migration_touches_tables?(file, reachable_tables, table_pattern)
        end

        unless explicit.empty?
          (explicit - matched_explicit.to_a).each do |missing|
            @errors << "Explicit include.migrations entry #{missing.inspect} did not match any migration file."
          end
        end

        [kept, kept.map { |f| manifest_migration_label(f) }]
      end

      def migration_touches_tables?(file, reachable_tables, table_pattern)
        source = File.binread(file)
        source.force_encoding(Encoding::UTF_8)
        if table_pattern && ascii_compatible_source?(source) && !source.include?("\\") && !(source.include?("%") && UNDERSCORE_PERCENT_LIT_RE.match?(source))
          return false unless table_pattern.match?(source)
        end

        parsed = Prism.parse(source)
        return false unless parsed.success?

        visitor = MigrationTableVisitor.new(reachable_tables)
        parsed.value.accept(visitor)
        visitor.matched
      end

      # --- Constant & path resolution helpers ---

      # Check full constant path in both stageable and unstaged indexes before
      # progressively shortening segments, so a parent namespace like `Slack`
      # never shadows `Slack::FakeReplyJob` in app/jobs/.
      def resolve_constant_with_precedence(ref)
        segments = ref[:segments]
        namespace = ref[:namespace]
        top_level = ref[:top_level]

        # Fast path for single-segment constant without enclosing namespace (most references).
        if segments.length == 1 && (top_level || namespace.empty?)
          name = segments[0]
          return [:stageable, @stageable_constants[name]] if @stageable_constants.key?(name)
          return [:unstaged, @unstaged_constants[name]] if @unstaged_constants.key?(name)

          return [nil, nil]
        end

        cache_key = [segments, namespace, top_level]
        cached = @const_resolve_cache[cache_key]
        return cached if cached

        result = [nil, nil]
        segments.length.downto(1) do |len|
          slice = len == segments.length ? segments : segments[0, len]
          candidates = candidate_constant_names(slice, namespace, top_level)
          candidates.each do |name|
            if @stageable_constants.key?(name)
              result = [:stageable, @stageable_constants[name]]
              return @const_resolve_cache[cache_key] = result
            elsif @unstaged_constants.key?(name)
              result = [:unstaged, @unstaged_constants[name]]
              return @const_resolve_cache[cache_key] = result
            end
          end
        end
        @const_resolve_cache[cache_key] = result
      end

      def lookup_constant(table, ref)
        segments = ref[:segments]
        segments.length.downto(1) do |len|
          slice = len == segments.length ? segments : segments[0, len]
          candidate_constant_names(slice, ref[:namespace], ref[:top_level]).each do |name|
            return table[name] if table.key?(name)
          end
        end
        nil
      end

      def candidate_constant_names(segments, namespace, top_level)
        joined = segments.length == 1 ? segments[0] : segments.join("::")
        return [joined] if top_level || namespace.empty?

        list = []
        namespace.length.downto(1) do |depth|
          prefix = depth == namespace.length ? namespace.join("::") : namespace[0, depth].join("::")
          list << "#{prefix}::#{joined}"
        end
        list << joined
        list.uniq
      end

      def resolve_render_target(target, current_dir, partial:)
        cleaned = target.to_s.delete_prefix("/")
        if cleaned.include?("/")
          parts = cleaned.split("/")
          leaf = parts.pop
          dir = parts.join("/")
          find_view_files(dir, leaf, partial: partial)
        else
          find_view_files(current_dir, cleaned, partial: partial)
        end
      end

      def find_view_files(dir, name, partial:)
        prefix = dir.to_s.empty? ? "app/views" : "app/views/#{dir}"
        leaf = partial ? "_#{name.delete_prefix('_')}" : name
        # The dot makes a US-ASCII name UTF-8, as the file names are.
        dotted = "#{prefix}/#{leaf}."

        # Raises when the name's encoding can't be compared with the file names'.
        @non_ascii_view&.start_with?(dotted)
        @views_by_stem.fetch(dotted.chop, [])
      end

      def view_dir_for(rel, is_view:)
        if is_view
          dir = File.dirname(rel).delete_prefix("app/views").delete_prefix("/")
          dir == "." ? "" : dir
        elsif rel.start_with?("app/controllers/")
          rel.delete_prefix("app/controllers/").delete_suffix("_controller.rb")
        else
          ""
        end
      end

      def resolve_model_override(entry)
        rel = sanitize_relative_path(entry)
        return rel if rel&.start_with?("app/models/") && safe_source_file?(rel)

        candidate = @stageable_constants[entry]
        return candidate if candidate&.start_with?("app/models/")

        underscored = sanitize_relative_path("app/models/#{ActiveSupport::Inflector.underscore(entry)}.rb")
        underscored && safe_source_file?(underscored) ? underscored : nil
      end

      def resolve_controller_override(entry)
        rel = sanitize_relative_path(entry)
        return rel if rel&.start_with?("app/controllers/") && safe_source_file?(rel)

        candidate = @stageable_constants[entry]
        return candidate if candidate&.start_with?("app/controllers/")

        normalized = entry.end_with?("_controller") ? entry : "#{ActiveSupport::Inflector.underscore(entry)}_controller"
        candidate_rel = sanitize_relative_path("app/controllers/#{normalized}.rb")
        candidate_rel && safe_source_file?(candidate_rel) ? candidate_rel : nil
      end

      def resolve_helper_override(entry)
        rel = sanitize_relative_path(entry)
        return rel if rel&.start_with?("app/helpers/") && safe_source_file?(rel)

        candidate = @stageable_constants[entry]
        return candidate if candidate&.start_with?("app/helpers/")

        underscored = ActiveSupport::Inflector.underscore(entry)
        underscored = "#{underscored}_helper" unless underscored.end_with?("_helper")
        candidate_rel = sanitize_relative_path("app/helpers/#{underscored}.rb")
        candidate_rel && safe_source_file?(candidate_rel) ? candidate_rel : nil
      end

      def resolve_view_override(entry, partial:)
        rel = sanitize_relative_path(entry)
        return [rel] if rel&.start_with?("app/views/") && safe_source_file?(rel)

        cleaned = entry.delete_prefix("/")
        return [] if cleaned.include?("..")

        if cleaned.include?("/")
          parts = cleaned.split("/")
          leaf = parts.pop
          find_view_files(parts.join("/"), leaf, partial: partial)
        else
          find_view_files("", cleaned, partial: partial)
        end
      end

      def sanitize_relative_path(entry)
        raw = entry.to_s.delete_prefix("/")
        return nil if raw.empty?

        expanded = File.expand_path(raw, @source_root)
        return nil unless expanded.start_with?(@source_root_prefix)

        expanded.delete_prefix(@source_root_prefix)
      end

      def safe_source_file?(rel)
        @safe_source_files.fetch(rel) { @safe_source_files[rel] = inside_source_root?(rel) }
      end

      def inside_source_root?(rel)
        expanded = File.expand_path(rel, @source_root)
        return false unless expanded.start_with?(@source_root_prefix)
        return false unless File.file?(expanded)

        @source_root_realpath_prefix ||= "#{File.realpath(@source_root)}#{File::SEPARATOR}"
        File.realpath(expanded).start_with?(@source_root_realpath_prefix)
      end

      def ascii_compatible_source?(source)
        source.valid_encoding? && !ENCODING_PRAGMA_RE.match?(source)
      end

      def word_bounded_union(names)
        if names.all? { |name| ASCII_IDENT_RE.match?(name) }
          /(?<![A-Za-z0-9_])(?:#{Regexp.union(names)})(?![A-Za-z0-9_])/
        else
          Regexp.union(names)
        end
      end

      def categorize(rel)
        if rel.start_with?("app/controllers/")
          @staged_controllers << rel
        elsif rel.start_with?("app/models/")
          @staged_models << rel
        elsif rel.start_with?("app/views/")
          @staged_views << rel
        elsif rel.start_with?("app/helpers/")
          @staged_helpers << rel
        elsif rel.start_with?("app/screens/")
          @staged_screens << rel
        end
      end

      def enqueue(rel)
        @queue << rel unless @visited.include?(rel)
      end

      def enqueue_if_exists(rel)
        enqueue(rel) if safe_source_file?(rel)
      end

      def glob_rel(pattern)
        Dir.glob(pattern, base: @source_root).sort
      end

      def const_from_rel(rel, prefix)
        stem =
          if rel.start_with?(prefix) && rel.end_with?(".rb")
            rel.byteslice(prefix.bytesize, rel.bytesize - prefix.bytesize - 3)
          else
            rel.delete_prefix(prefix).delete_suffix(".rb")
          end

        if @acronyms_empty && LOWERCASE_REL_RE.match?(stem)
          return stem.capitalize unless stem.include?("_") || stem.include?("/")

          stem_len = stem.bytesize
          out = String.new(encoding: Encoding::UTF_8, capacity: stem_len + 4)
          upcase_next = true
          i = 0
          while i < stem_len
            b = stem.getbyte(i)
            if b == 95 # "_"
              upcase_next = true
            elsif b == 47 # "/"
              out << "::"
              upcase_next = true
            else
              out << (upcase_next && b >= 97 && b <= 122 ? b - 32 : b)
              upcase_next = false
            end
            i += 1
          end
          out
        else
          stem.split("/").map { |part| ActiveSupport::Inflector.camelize(part) }.join("::")
        end
      end

      # Extract top-level public helper method definitions, skipping server_only
      # blocks and methods defined after `private` / `protected`.
      def extract_public_helper_defs(node)
        names = []
        collect_public_defs(node, names)
        names
      end

      def collect_public_defs(node, names)
        return unless node

        case node
        when Prism::ProgramNode
          collect_public_defs(node.statements, names)
        when Prism::ModuleNode
          collect_public_defs(node.body, names)
        when Prism::StatementsNode
          visibility = :public
          node.body.each do |stmt|
            if stmt.is_a?(Prism::CallNode) && stmt.receiver.nil?
              name = stmt.name
              if name == :server_only && stmt.block
                next
              elsif (name == :private || name == :protected) && stmt.arguments.nil?
                visibility = name
                next
              elsif name == :public && stmt.arguments.nil?
                visibility = :public
                next
              elsif (name == :browser_only || name == :client_only) && stmt.block
                collect_public_defs(stmt.block.body, names) if visibility == :public
                next
              end
            end
            if stmt.is_a?(Prism::DefNode) && stmt.receiver.nil? && visibility == :public
              names << stmt.name
            elsif stmt.is_a?(Prism::ModuleNode)
              collect_public_defs(stmt, names)
            end
          end
        end
      end

      # Never leak host build-machine paths into public instant_record.manifest.json.
      def manifest_migration_label(file)
        if file.start_with?(@source_root_prefix)
          file.delete_prefix(@source_root_prefix)
        else
          "db/migrate/#{File.basename(file)}"
        end
      end

      def format_errors(errors)
        header = "Local-first island reachability check failed (#{errors.size} #{errors.size == 1 ? 'error' : 'errors'}):"
        ([header] + errors.map { |err| "  - #{err}" }).join("\n")
      end
    end
  end
end
