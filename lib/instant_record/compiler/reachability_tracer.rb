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

      # Extracts constant references, associations, renders, sync macros, and
      # dynamic patterns from a single Ruby AST while ignoring `server_only`.
      class FileVisitor < Prism::Visitor
        DYNAMIC = Object.new.freeze

        attr_reader :constants, :associations, :renders, :layouts, :helper_decls,
                    :bare_calls, :includes, :superclass, :table_name, :abstract_class,
                    :syncable, :sync_window, :sync_scope_column, :sync_scope_policy,
                    :sync_file, :dynamic_warnings

        def initialize(rel_path:, is_view: false, is_helper: false)
          super()
          @rel_path = rel_path
          @is_view = is_view
          @is_helper = is_helper
          @namespace = []
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
          name = constant_node_segments(node.constant_path)
          @namespace.concat(name) if name
          super
        ensure
          @namespace.pop(name.length) if name
        end

        def visit_class_node(node)
          name = constant_node_segments(node.constant_path)
          if node.superclass
            sup = constant_node_segments(node.superclass)
            if sup
              @superclass ||= sup.join("::")
              @constants << {
                segments: sup,
                top_level: top_level_const?(node.superclass),
                namespace: @namespace.dup,
                line: node.superclass.location.start_line
              }
            end
          end
          @namespace.concat(name) if name
          visit(node.body) if node.body
        ensure
          @namespace.pop(name.length) if name
        end

        def visit_constant_path_node(node)
          segments = constant_node_segments(node)
          if segments
            @constants << {
              segments: segments,
              top_level: top_level_const?(node),
              namespace: @namespace.dup,
              line: node.location.start_line
            }
          else
            super
          end
        end

        def visit_constant_read_node(node)
          @constants << {
            segments: [node.name.to_s],
            top_level: false,
            namespace: @namespace.dup,
            line: node.location.start_line
          }
        end

        def visit_call_node(node)
          # Strictly skip server_only blocks (only note syncable_to / writable_by policy presence).
          if node.receiver.nil? && node.name == :server_only && node.block
            @sync_scope_policy = true if block_calls_policy?(node.block)
            return
          end

          # Detect self.table_name = "..." and self.abstract_class = true
          if node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
            if node.name == :table_name=
              arg = Array(node.arguments&.arguments).first
              @table_name = arg.unescaped if arg.is_a?(Prism::StringNode)
            elsif node.name == :abstract_class=
              arg = Array(node.arguments&.arguments).first
              @abstract_class = true if arg.is_a?(Prism::TrueNode)
            end
          end

          if node.receiver.nil?
            @bare_calls << node.name.to_s
            inspect_bare_call(node)
          else
            inspect_receiver_call(node)
          end

          super
        end

        private

        def block_calls_policy?(block_node)
          queue = [block_node]
          while (current = queue.shift)
            if current.is_a?(Prism::CallNode) && current.receiver.nil? &&
                %i[syncable_to writable_by].include?(current.name)
              return true
            end
            queue.concat(current.compact_child_nodes)
          end
          false
        end

        def inspect_bare_call(node)
          case node.name
          when :include, :extend, :prepend
            Array(node.arguments&.arguments).each do |arg|
              segs = constant_node_segments(arg)
              next unless segs

              full = segs.join("::")
              @includes << full
              @syncable = true if full == "InstantRecord::Syncable" || full == "Syncable"
            end
          when :sync_window
            extract_sync_window(node)
          when :sync_scope
            arg = Array(node.arguments&.arguments).first
            if arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode)
              @sync_scope_column = arg.unescaped
            end
          when :syncable_to, :writable_by
            @sync_scope_policy = true
          when :sync_file
            @sync_file = true
          when *ASSOCIATION_MACROS
            extract_association(node)
          when :render
            extract_render(node)
          when :layout
            extract_layout(node)
          when :helper
            extract_helper(node)
          when :const_get
            record_dynamic_warning("const_get", node.location.start_line,
              "Dynamic constant lookup via const_get; declare referenced classes in include: { models: [...] } if needed.")
          end
        end

        def inspect_receiver_call(node)
          if %i[constantize safe_constantize const_get].include?(node.name)
            record_dynamic_warning(node.name.to_s, node.location.start_line,
              "Dynamic constant lookup via #{node.name}; declare referenced classes in include: { models: [...] } if needed.")
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
          args = Array(node.arguments&.arguments)
          first = args.first
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
            namespace: @namespace.dup,
            through: through,
            line: node.location.start_line
          }
        end

        def extract_render(node)
          args = Array(node.arguments&.arguments)
          return if args.empty?

          opts = extract_keyword_hash(node)
          return if (opts.keys & NON_TEMPLATE_RENDER_KEYS).any?

          if opts.key?(:partial)
            val = opts[:partial]
            if val.is_a?(String) || val.is_a?(Symbol)
              @renders << { kind: :partial, target: val.to_s, line: node.location.start_line }
            else
              record_dynamic_warning("render", node.location.start_line,
                "Dynamic partial render; declare targets in include: { partials: [...] }.")
            end
          elsif opts.key?(:template)
            val = opts[:template]
            if val.is_a?(String) || val.is_a?(Symbol)
              @renders << { kind: :template, target: val.to_s, line: node.location.start_line }
            else
              record_dynamic_warning("render", node.location.start_line,
                "Dynamic template render; declare targets in include: { views: [...] }.")
            end
          elsif opts.key?(:action)
            val = opts[:action]
            if val.is_a?(String) || val.is_a?(Symbol)
              @renders << { kind: :template, target: val.to_s, line: node.location.start_line }
            end
          else
            first = args.first
            unless first.is_a?(Prism::KeywordHashNode) || first.is_a?(Prism::HashNode)
              if first.is_a?(Prism::StringNode) || first.is_a?(Prism::SymbolNode)
                kind = (@is_view || @is_helper) ? :partial : :template
                @renders << { kind: kind, target: first.unescaped, line: node.location.start_line }
              else
                record_dynamic_warning("render", node.location.start_line,
                  "Dynamic render expression; declare targets in include: { partials: [...] } or include: { views: [...] }.")
              end
            end
          end

          # Independently handle `layout:` option (e.g. `render partial: "row", layout: "card"`).
          if opts.key?(:layout)
            layout_val = opts[:layout]
            if layout_val.is_a?(String) || layout_val.is_a?(Symbol)
              if @is_view || @is_helper || opts.key?(:partial)
                @renders << { kind: :partial, target: layout_val.to_s, line: node.location.start_line }
              else
                @layouts << { target: layout_val.to_s, line: node.location.start_line }
              end
            end
          end
        end

        def extract_layout(node)
          first = Array(node.arguments&.arguments).first
          return unless first.is_a?(Prism::StringNode) || first.is_a?(Prism::SymbolNode)

          @layouts << { target: first.unescaped, line: node.location.start_line }
        end

        def extract_helper(node)
          Array(node.arguments&.arguments).each do |arg|
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
          Array(call.arguments&.arguments).each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)

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

      def self.trace(source_root:, route_analysis:, overrides: nil, native: false, migration_paths: nil)
        new(
          source_root: source_root,
          route_analysis: route_analysis,
          overrides: overrides,
          native: native,
          migration_paths: migration_paths
        ).trace
      end

      def initialize(source_root:, route_analysis:, overrides: nil, native: false, migration_paths: nil)
        @source_root = File.expand_path(source_root.to_s)
        @route_analysis = route_analysis
        @overrides = Manifest.merge_overrides(route_analysis.overrides, overrides)
        @native = native
        @migration_paths = migration_paths

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
      end

      def trace
        index_app_files!
        if @route_analysis.has_local_first
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
        @controller_files = glob_rel("app/controllers/**/*.rb")
        @model_files = glob_rel("app/models/**/*.rb")
        @helper_files = glob_rel("app/helpers/**/*.rb")
        @view_files = glob_rel("app/views/**/*").select { |rel| File.file?(File.join(@source_root, rel)) }
        @screen_files = glob_rel("app/screens/**/*.rb")

        # Map constant names -> relative file paths for stageable categories.
        @stageable_constants = {}
        @controller_files.each { |rel| register_const_path(@stageable_constants, const_from_rel(rel, "app/controllers/"), rel) }
        @model_files.each do |rel|
          register_const_path(@stageable_constants, const_from_rel(rel, "app/models/"), rel)
          if rel.start_with?("app/models/concerns/")
            register_const_path(@stageable_constants, const_from_rel(rel, "app/models/concerns/"), rel)
          end
        end
        @helper_files.each { |rel| register_const_path(@stageable_constants, const_from_rel(rel, "app/helpers/"), rel) }
        @controller_files.each do |rel|
          if rel.start_with?("app/controllers/concerns/")
            register_const_path(@stageable_constants, const_from_rel(rel, "app/controllers/concerns/"), rel)
          end
        end
        @screen_files.each { |rel| register_const_path(@stageable_constants, const_from_rel(rel, "app/screens/"), rel) } if @native

        # Index unstaged app directories (jobs, services, mailers, channels, non-native screens, lib)
        # for crisp missing-symbol diagnostics.
        @unstaged_constants = {}
        Dir.glob("app/**/*.rb", base: @source_root).sort.each do |rel|
          next if rel.start_with?("app/controllers/", "app/models/", "app/helpers/")
          next if @native && rel.start_with?("app/screens/")

          top_dir = rel.split("/")[1]
          const_name = const_from_rel(rel, "app/#{top_dir}/")
          @unstaged_constants[const_name] ||= rel
        end
        Dir.glob("lib/**/*.rb", base: @source_root).sort.each do |rel|
          next if rel.start_with?("lib/tasks/")

          const_name = const_from_rel(rel, "lib/")
          @unstaged_constants[const_name] ||= rel
        end

        # Index public helper methods -> helper rel path so views/helpers calling one automatically stage it.
        @helper_methods = {}
        @helper_files.each do |rel|
          parsed = Prism.parse_file(File.join(@source_root, rel))
          next unless parsed.success?

          extract_public_helper_defs(parsed.value).each do |method_name|
            (@helper_methods[method_name] ||= []) << rel
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
        inc = @overrides[:include]

        inc["models"].each do |entry|
          rel = resolve_model_override(entry)
          if rel
            enqueue(rel)
          else
            @errors << "Explicit include.models entry #{entry.inspect} was not found under app/models/."
          end
        end

        inc["controllers"].each do |entry|
          rel = resolve_controller_override(entry)
          if rel
            enqueue(rel)
          else
            @errors << "Explicit include.controllers entry #{entry.inspect} was not found under app/controllers/."
          end
        end

        inc["helpers"].each do |entry|
          rel = resolve_helper_override(entry)
          if rel
            enqueue(rel)
          else
            @errors << "Explicit include.helpers entry #{entry.inspect} was not found under app/helpers/."
          end
        end

        inc["views"].each do |entry|
          matches = resolve_view_override(entry, partial: false)
          if matches.any?
            matches.each { |rel| enqueue(rel) }
          else
            @errors << "Explicit include.views entry #{entry.inspect} was not found under app/views/."
          end
        end

        inc["partials"].each do |entry|
          matches = resolve_view_override(entry, partial: true)
          if matches.any?
            matches.each { |rel| enqueue(rel) }
          else
            @errors << "Explicit include.partials entry #{entry.inspect} was not found under app/views/."
          end
        end

        inc["files"].each do |entry|
          rel = sanitize_relative_path(entry)
          if rel && safe_source_file?(rel)
            @staged_extra_files << rel
            enqueue(rel) if rel.end_with?(".rb", ".erb")
          else
            @errors << "Explicit include.files entry #{entry.inspect} does not exist inside #{@source_root}."
          end
        end
      end

      def process_queue!
        while (rel = @queue.shift)
          next if @visited.include?(rel)

          @visited << rel
          categorize(rel)

          full = File.join(@source_root, rel)
          next unless File.file?(full)

          if rel.end_with?(".rb")
            visit_ruby_file(rel, full)
          elsif rel.end_with?(".erb")
            visit_erb_file(rel, full)
          end
        end
      end

      def visit_ruby_file(rel, full)
        source = File.read(full)
        parsed = Prism.parse(source)
        unless parsed.success?
          errors = parsed.errors.map { |e| "line #{e.location.start_line}: #{e.message}" }.join("; ")
          @errors << "Syntax error in #{rel}: #{errors}"
          return
        end

        is_helper = rel.start_with?("app/helpers/")
        visitor = FileVisitor.new(rel_path: rel, is_view: false, is_helper: is_helper)
        parsed.value.accept(visitor)

        @diagnostics.concat(visitor.dynamic_warnings)
        if rel.start_with?("app/models/concerns/")
          if visitor.syncable
            @concern_syncable << const_from_rel(rel, "app/models/concerns/")
            @concern_syncable << const_from_rel(rel, "app/models/")
          end
        elsif rel.start_with?("app/models/")
          record_model_metadata(rel, visitor)
        end

        resolve_visitor_edges!(rel, visitor, is_view: false, is_helper: is_helper)
      end

      def visit_erb_file(rel, full)
        erb_source = File.read(full)
        ruby_source = ActionView::Template::Handlers::ERB::Erubi.new(erb_source).src
        # Wrap in a method body so `yield` in layouts is valid Ruby, preserving 1-based line numbers via line: 0.
        parsed = Prism.parse("def _instant_record_template\n#{ruby_source}\nend\n", line: 0)
        unless parsed.success?
          errors = parsed.errors.map { |e| "line #{e.location.start_line}: #{e.message}" }.join("; ")
          @errors << "ERB syntax error in #{rel}: #{errors}"
          return
        end

        visitor = FileVisitor.new(rel_path: rel, is_view: true)
        parsed.value.accept(visitor)

        @diagnostics.concat(visitor.dynamic_warnings)
        resolve_visitor_edges!(rel, visitor, is_view: true, is_helper: false)
      end

      def resolve_visitor_edges!(rel, visitor, is_view:, is_helper:)
        # 1. Constant references: check exact/longer matches across BOTH tables before falling back to prefixes.
        visitor.constants.each do |ref|
          kind, target_rel = resolve_constant_with_precedence(ref)
          if kind == :stageable
            enqueue(target_rel)
          elsif kind == :unstaged && @route_analysis.has_local_first && !@staged_extra_files.include?(target_rel)
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
          elsif @route_analysis.has_local_first && !assoc[:through]
            expected = "app/models/#{ActiveSupport::Inflector.underscore(assoc[:class_name])}.rb"
            unless safe_source_file?(expected)
              @errors << "Missing model #{assoc[:class_name]} for association :#{assoc[:name]} at #{rel}:#{assoc[:line]} " \
                         "(expected #{expected})."
            end
          end
        end

        # 3. Render calls -> stage matching partials/templates or flag missing template.
        current_dir = view_dir_for(rel, is_view: is_view)
        visitor.renders.each do |render_ref|
          is_partial = render_ref[:kind] == :partial
          matches = resolve_render_target(render_ref[:target], current_dir, partial: is_partial)
          if matches.any?
            matches.each { |path| enqueue(path) }
          elsif @route_analysis.has_local_first
            kind_label = is_partial ? "partial" : "template"
            hint_key = is_partial ? "partials" : "views"
            @errors << "Missing #{kind_label} #{render_ref[:target].inspect} rendered at #{rel}:#{render_ref[:line]} " \
                       "(searched under app/views/#{current_dir}). Add the file or declare include: { #{hint_key}: [...] }."
          end
        end

        # 4. Controller layout declarations.
        visitor.layouts.each do |layout_ref|
          matches = find_view_files("layouts", layout_ref[:target], partial: false)
          if matches.any?
            matches.each { |path| enqueue(path) }
          elsif @route_analysis.has_local_first
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
          elsif @route_analysis.has_local_first
            @errors << "Missing helper #{decl[:value].inspect} declared at #{rel}:#{decl[:line]}."
          end
        end

        # 6. Helper method calls in views, controllers, and helpers -> stage helper that defines them.
        if is_view || is_helper || rel.start_with?("app/controllers/")
          visitor.bare_calls.each do |method_name|
            Array(@helper_methods[method_name]).each { |helper_rel| enqueue(helper_rel) }
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
        return unless @route_analysis.has_local_first

        concrete_staged = @model_metadata.each_with_object(Set.new) do |(name, meta), set|
          set << name unless meta["abstract_class"]
        end
        return if concrete_staged.empty?

        unstaged_models = @model_files.reject { |rel| @staged_models.include?(rel) || rel.start_with?("app/models/concerns/") }
        return if unstaged_models.empty?

        subclasses_by_parent = Hash.new { |h, k| h[k] = [] }
        unstaged_models.each do |rel|
          parsed = Prism.parse_file(File.join(@source_root, rel))
          next unless parsed.success?

          visitor = FileVisitor.new(rel_path: rel)
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

        unless @route_analysis.has_local_first
          return [all_files, all_files.map { |f| manifest_migration_label(f) }]
        end

        reachable_tables = FRAMEWORK_TABLES.to_set
        @model_metadata.each_value do |meta|
          reachable_tables << meta["table"] if meta["table"]
        end

        explicit = @overrides[:include]["migrations"]
        matched_explicit = Set.new

        kept = all_files.select do |file|
          basename = File.basename(file)
          version = basename.to_i.to_s
          rel = manifest_migration_label(file)

          hit = explicit.find { |item| item == version || item == basename || item == rel || basename.start_with?("#{item}_") }
          if hit
            matched_explicit << hit
            next true
          end

          tables = migration_tables(file)
          tables.any? { |tbl| reachable_tables.include?(tbl) }
        end

        (explicit - matched_explicit.to_a).each do |missing|
          @errors << "Explicit include.migrations entry #{missing.inspect} did not match any migration file."
        end

        [kept, kept.map { |f| manifest_migration_label(f) }]
      end

      def migration_tables(file)
        parsed = Prism.parse_file(file)
        return [] unless parsed.success?

        tables = Set.new
        queue = [parsed.value]
        while (node = queue.shift)
          if node.is_a?(Prism::CallNode) && node.receiver.nil?
            if DDL_TABLE_CALLS.include?(node.name)
              first = Array(node.arguments&.arguments).first
              tables << first.unescaped if first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)
              if node.name == :rename_table
                second = Array(node.arguments&.arguments)[1]
                tables << second.unescaped if second.is_a?(Prism::SymbolNode) || second.is_a?(Prism::StringNode)
              end
            elsif node.name == :execute
              first = Array(node.arguments&.arguments).first
              if first.is_a?(Prism::StringNode)
                first.unescaped.scan(/\b(?:FROM|INTO|UPDATE|TABLE|ON)\s+["`]?([a-z_][a-z0-9_]*)["`]?/i).each do |match|
                  tables << match.first
                end
              end
            end
          end
          queue.concat(node.compact_child_nodes)
        end
        tables.to_a
      end

      # --- Constant & path resolution helpers ---

      # Check full constant path in both stageable and unstaged indexes before
      # progressively shortening segments, so a parent namespace like `Slack`
      # never shadows `Slack::FakeReplyJob` in app/jobs/.
      def resolve_constant_with_precedence(ref)
        segments = ref[:segments]
        segments.length.downto(1) do |len|
          slice = segments[0, len]
          candidates = candidate_constant_names(slice, ref[:namespace], ref[:top_level])
          candidates.each do |name|
            return [:stageable, @stageable_constants[name]] if @stageable_constants.key?(name)
            return [:unstaged, @unstaged_constants[name]] if @unstaged_constants.key?(name)
          end
        end
        [nil, nil]
      end

      def lookup_constant(table, ref)
        segments = ref[:segments]
        segments.length.downto(1) do |len|
          slice = segments[0, len]
          candidate_constant_names(slice, ref[:namespace], ref[:top_level]).each do |name|
            return table[name] if table.key?(name)
          end
        end
        nil
      end

      def candidate_constant_names(segments, namespace, top_level)
        joined = segments.join("::")
        return [joined] if top_level || namespace.empty?

        list = []
        namespace.length.downto(1) do |depth|
          list << (namespace[0, depth] + segments).join("::")
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
        stem = partial ? "_#{name.delete_prefix('_')}" : name
        exact_prefix = "#{prefix}/#{stem}."
        exact_path = "#{prefix}/#{stem}"

        @view_files.select { |rel| rel == exact_path || rel.start_with?(exact_prefix) }
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
        return nil unless expanded.start_with?("#{@source_root}#{File::SEPARATOR}")

        expanded.delete_prefix("#{@source_root}#{File::SEPARATOR}")
      end

      def safe_source_file?(rel)
        expanded = File.expand_path(rel, @source_root)
        return false unless expanded.start_with?("#{@source_root}#{File::SEPARATOR}")
        return false unless File.file?(expanded)

        File.realpath(expanded).start_with?("#{File.realpath(@source_root)}#{File::SEPARATOR}")
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
        rel.delete_prefix(prefix).delete_suffix(".rb").split("/").map { |part| ActiveSupport::Inflector.camelize(part) }.join("::")
      end

      def register_const_path(map, const_name, rel)
        map[const_name] ||= rel
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
              if stmt.name == :server_only && stmt.block
                next
              elsif %i[private protected].include?(stmt.name) && stmt.arguments.nil?
                visibility = stmt.name
                next
              elsif stmt.name == :public && stmt.arguments.nil?
                visibility = :public
                next
              elsif %i[browser_only client_only].include?(stmt.name) && stmt.block
                collect_public_defs(stmt.block.body, names) if visibility == :public
                next
              end
            end
            if stmt.is_a?(Prism::DefNode) && stmt.receiver.nil? && visibility == :public
              names << stmt.name.to_s
            elsif stmt.is_a?(Prism::ModuleNode)
              collect_public_defs(stmt, names)
            end
          end
        end
      end

      # Never leak host build-machine paths into public instant_record.manifest.json.
      def manifest_migration_label(file)
        prefix = "#{@source_root}#{File::SEPARATOR}"
        if file.start_with?(prefix)
          file.delete_prefix(prefix)
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
