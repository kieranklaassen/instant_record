require "pathname"
require "prism"
require "set"
require_relative "ast_lowerer"
require_relative "runner"

module InstantRecord
  class Compiler
    # Fast pre-Spinel Prism static AOT / 32-bit linter.
    #
    # Catches the three silent/slow AOT failure classes before Roundhouse or
    # Spinel run (and in `instant_record:doctor`):
    #
    # 1. `integer_overflow`: integer literals and constant expressions exceeding
    #    signed 32-bit / 31-bit-magnitude range (-2_147_483_648..2_147_483_647),
    #    which raise RangeError under `-DSP_INT_OVERFLOW_MODE_RAISE`.
    # 2. `untyped_screen_hash`: untyped empty `{}` (or `Hash.new`) passed to
    #    `params:`, `args:`, or `props:` (or defaulted/assigned there) inside
    #    `InstantRecord::Native::Screen` subclasses / `app/screens/`.
    # 3. `server_only_constant`: references from shared / `browser_only` /
    #    `client_only` code to constants defined only inside `server_only`
    #    blocks (or server-only gem constants).
    class StaticLinter
      INT32_MAX = (1 << 31) - 1 #  2_147_483_647 (31 magnitude bits)
      INT32_MIN = -(1 << 31)    # -2_147_483_648
      INT32_RANGE = (INT32_MIN..INT32_MAX)

      SCREEN_HASH_KEYS = %i[params args props].freeze
      SCREEN_HASH_SETTERS = %i[link_params= args= props=].freeze
      SCREEN_HASH_IVARS = %i[@link_params @args @props].freeze

      BYTE_MULTIPLIERS = {
        kilobyte: 1024, kilobytes: 1024, kb: 1024,
        megabyte: 1024**2, megabytes: 1024**2, mb: 1024**2,
        gigabyte: 1024**3, gigabytes: 1024**3, gb: 1024**3,
        terabyte: 1024**4, terabytes: 1024**4, tb: 1024**4,
        petabyte: 1024**5, petabytes: 1024**5, pb: 1024**5
      }.freeze

      SERVER_ONLY_GEM_CONSTANTS = Set.new(%w[
        InstantRecord::Engine
        InstantRecord::Files
        InstantRecord::FileStore
        InstantRecord::MutationApplier
        InstantRecord::AppliedMutation
        InstantRecord::SyncScope
        InstantRecord::Inertia
        InstantRecord::CompiledSite
        InstantRecord::Compiler
      ]).freeze

      NON_COMPILED_PREFIXES = %w[
        db/
        test/
        spec/
        tmp/
        vendor/
        node_modules/
        lib/tasks/
        lib/generators/
      ].freeze

      NON_COMPILED_FILES = Set.new(%w[
        Gemfile
        Rakefile
      ]).freeze

      Diagnostic = Struct.new(:rule, :file, :line, :column, :message, keyword_init: true) do
        def to_s
          "#{file}:#{line}:#{column} [#{rule}] #{message}"
        end
      end

      Result = Struct.new(:files_checked, :diagnostics, keyword_init: true) do
        def ok? = diagnostics.empty?

        def to_s
          return "Static AOT lint passed (#{files_checked} files checked)." if ok?

          lines = ["Static AOT lint failed with #{diagnostics.size} issue(s) across #{files_checked} files:"]
          diagnostics.each { |d| lines << "  #{d}" }
          lines.join("\n")
        end
      end

      def self.lint(root, staged: false, server_only_constants: nil, exclude: [], only_files: nil)
        new(root: root, staged: staged, server_only_constants: server_only_constants, exclude: exclude, only_files: only_files).run
      end

      def self.check!(root, staged: true, server_only_constants: nil, exclude: [], only_files: nil)
        result = lint(root, staged: staged, server_only_constants: server_only_constants, exclude: exclude, only_files: only_files)
        raise BuildError, result.to_s unless result.ok?

        result
      end

      # Collects constants defined strictly inside `server_only` blocks across a
      # directory tree before AstLowerer strips those blocks.
      def self.collect_server_only_constants(root, staged: true, exclude: [], only_files: nil)
        linter = new(root: root, staged: staged, exclude: exclude, only_files: only_files)
        files = linter.discover_files
        linter.scan_constant_definitions(files)
      end

      def initialize(root:, staged: false, server_only_constants: nil, exclude: [], only_files: nil)
        @root = File.expand_path(root.to_s)
        @staged = staged
        @precollected_server_only = server_only_constants
        @exclude = Array(exclude).map { |entry| entry.to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "") }
        @only_files = only_files ? Set.new(Array(only_files).map { |entry| entry.to_s.sub(%r{\A/+}, "") }) : nil
      end

      def run
        files = discover_files
        parsed_files = files.map { |path| [path, relative_path(path), Prism.parse_file(path)] }

        server_only_defs, client_defs =
          if @precollected_server_only
            [@precollected_server_only, collect_defs_from_parsed(parsed_files).last]
          else
            collect_defs_from_parsed(parsed_files)
          end

        effective_server_only = {}
        server_only_defs.each do |name, loc|
          effective_server_only[name] = loc unless client_defs.include?(name)
        end
        SERVER_ONLY_GEM_CONSTANTS.each do |name|
          effective_server_only[name] ||= nil unless client_defs.include?(name)
        end

        diagnostics = []
        parsed_files.each do |_abs, rel, parsed|
          next unless parsed.success?

          lint_file(rel, parsed.value, effective_server_only, diagnostics)
        end

        diagnostics.sort_by! { |d| [d.file, d.line, d.column, d.rule.to_s] }
        Result.new(files_checked: parsed_files.size, diagnostics: diagnostics)
      end

      def discover_files
        root_path = Pathname(@root)
        return [] unless root_path.directory?

        if @only_files
          return @only_files.to_a.sort
            .reject { |rel| excluded_custom?(rel) }
            .map { |rel| File.join(@root, rel) }
            .select { |path| File.file?(path) }
        end

        if @staged
          candidates = Dir.glob("**/*.rb", base: @root).sort
          return candidates.reject { |rel| excluded_staged?(rel) || excluded_custom?(rel) }.map { |rel| File.join(@root, rel) }
        end

        # Raw Rails app root (used by `instant_record:doctor`): scan the folders
        # that actually enter compilation, or fall back to flat `**/*.rb` for
        # standalone fixture directories.
        app_subfolders = %w[app/models app/controllers app/helpers app/screens config/routes]
        app_files = %w[config/application.rb config/routes.rb config/importmap.rb]
        has_rails_layout = app_subfolders.any? { |dir| File.directory?(File.join(@root, dir)) } ||
                           app_files.any? { |file| File.file?(File.join(@root, file)) }

        if has_rails_layout
          found = []
          app_subfolders.each do |folder|
            dir = File.join(@root, folder)
            next unless File.directory?(dir)

            Dir.glob("**/*.rb", base: dir).sort.each { |rel| found << File.join(dir, rel) }
          end
          app_files.each do |file|
            full = File.join(@root, file)
            found << full if File.file?(full)
          end
          found.uniq.reject { |path| excluded_custom?(relative_path(path)) }.sort
        else
          Dir.glob("**/*.rb", base: @root).sort
            .reject { |rel| excluded_staged?(rel) || excluded_custom?(rel) }
            .map { |rel| File.join(@root, rel) }
        end
      end

      def scan_constant_definitions(files)
        parsed_files = files.map { |path| [path, relative_path(path), Prism.parse_file(path)] }
        server_only_defs, client_defs = collect_defs_from_parsed(parsed_files)
        server_only_defs.reject { |name, _| client_defs.include?(name) }
      end

      private

      def relative_path(path)
        Pathname(path).relative_path_from(Pathname(@root)).to_s
      end

      def excluded_staged?(rel)
        return true if NON_COMPILED_FILES.include?(rel)

        NON_COMPILED_PREFIXES.any? { |prefix| rel.start_with?(prefix) }
      end

      def excluded_custom?(rel)
        @exclude.any? { |entry| rel == entry || rel.start_with?("#{entry}/") }
      end

      def collect_defs_from_parsed(parsed_files)
        server_only_defs = {}
        client_defs = Set.new

        parsed_files.each do |_abs, rel, parsed|
          next unless parsed.success?

          walk_defs(parsed.value, rel, [], in_server_only: false, server_only_defs: server_only_defs, client_defs: client_defs)
        end

        [server_only_defs, client_defs]
      end

      def walk_defs(node, rel, namespace, in_server_only:, server_only_defs:, client_defs:)
        return if node.nil?

        case node
        when Prism::CallNode
          if server_only_call?(node)
            walk_defs(node.block&.body, rel, namespace, in_server_only: true, server_only_defs: server_only_defs, client_defs: client_defs)
            return
          end
        when Prism::ClassNode, Prism::ModuleNode
          full_path = qualify_definition(node.constant_path, namespace)
          if full_path
            record_const_def(full_path, rel, node.location.start_line, in_server_only, server_only_defs, client_defs)
            next_ns = full_path.split("::")
          else
            next_ns = namespace
          end
          walk_defs(node.body, rel, next_ns, in_server_only: in_server_only, server_only_defs: server_only_defs, client_defs: client_defs)
          return
        when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode, Prism::ConstantOperatorWriteNode
          full_path = (namespace + [node.name.to_s]).join("::")
          record_const_def(full_path, rel, node.location.start_line, in_server_only, server_only_defs, client_defs)
        when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode, Prism::ConstantPathOperatorWriteNode
          full_path = qualify_definition(node.target, namespace)
          record_const_def(full_path, rel, node.location.start_line, in_server_only, server_only_defs, client_defs) if full_path
        end

        node.compact_child_nodes.each do |child|
          walk_defs(child, rel, namespace, in_server_only: in_server_only, server_only_defs: server_only_defs, client_defs: client_defs)
        end
      end

      def record_const_def(full_path, rel, line, in_server_only, server_only_defs, client_defs)
        if in_server_only
          server_only_defs[full_path] ||= "#{rel}:#{line}"
        else
          client_defs.add(full_path)
        end
      end

      def qualify_definition(path_node, namespace)
        name = AstLowerer.constant_name(path_node)
        return nil unless name

        if name.start_with?("::")
          name.delete_prefix("::")
        elsif namespace.empty?
          name
        else
          (namespace + [name]).join("::")
        end
      end

      def server_only_call?(node)
        node.is_a?(Prism::CallNode) &&
          node.name == :server_only &&
          (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
          node.arguments.nil? &&
          node.block.is_a?(Prism::BlockNode)
      end

      def lint_file(rel, root, effective_server_only, diagnostics)
        in_screen_file = rel.start_with?("app/screens/") ||
                         rel == "lib/instant_record/native/screen.rb" ||
                         rel == "lib/instant_record/native/node.rb"
        state = {
          rel: rel,
          namespace: [],
          in_screen: in_screen_file,
          const_ints: {},
          empty_hash_helpers: Set.new,
          empty_hash_locals: Set.new,
          reported_int_nodes: Set.new,
          server_only: effective_server_only,
          diagnostics: diagnostics
        }
        walk_lint(root, state)
      end

      def walk_lint(node, state)
        return if node.nil?

        case node
        when Prism::DefinedNode
          # `defined?(ServerOnlyConst)` is safe and never raises NameError.
          return
        when Prism::CallNode
          return if server_only_call?(node)

          # Check constant arithmetic expression overflow first (before recursing)
          if constant_int_expr?(node)
            check_int_expression(node, state)
          end

          check_screen_call(node, state) if state[:in_screen]

          # Recurse into receiver, arguments, block
          walk_lint(node.receiver, state)
          walk_lint(node.arguments, state)
          walk_lint(node.block, state)
          return
        when Prism::IntegerNode
          check_int_expression(node, state)
          return
        when Prism::IfNode
          pred = browser_predicate(node.predicate)
          if pred == :true
            walk_lint(node.statements, state)
            return
          elsif pred == :false
            walk_lint(node.subsequent, state)
            return
          end
        when Prism::UnlessNode
          pred = browser_predicate(node.predicate)
          if pred == :true
            walk_lint(node.else_clause, state)
            return
          elsif pred == :false
            walk_lint(node.statements, state)
            return
          end
        when Prism::ClassNode
          walk_lint(node.superclass, state)
          full_path = qualify_definition(node.constant_path, state[:namespace])
          prev_ns = state[:namespace]
          prev_screen = state[:in_screen]
          prev_helpers = state[:empty_hash_helpers]

          state[:namespace] = full_path ? full_path.split("::") : prev_ns
          state[:in_screen] = prev_screen || screen_superclass?(node.superclass)
          state[:empty_hash_helpers] = state[:in_screen] ? collect_empty_hash_helpers(node.body) : Set.new

          walk_lint(node.body, state)
          state[:namespace] = prev_ns
          state[:in_screen] = prev_screen
          state[:empty_hash_helpers] = prev_helpers
          return
        when Prism::ModuleNode
          full_path = qualify_definition(node.constant_path, state[:namespace])
          prev_ns = state[:namespace]
          state[:namespace] = full_path ? full_path.split("::") : prev_ns
          walk_lint(node.body, state)
          state[:namespace] = prev_ns
          return
        when Prism::DefNode
          prev_locals = state[:empty_hash_locals]
          state[:empty_hash_locals] = Set.new
          check_screen_def_params(node, state) if state[:in_screen]
          walk_lint(node.parameters, state)
          walk_lint(node.body, state)
          state[:empty_hash_locals] = prev_locals
          return
        when Prism::LocalVariableWriteNode
          if state[:in_screen]
            if empty_hash_literal?(node.value)
              state[:empty_hash_locals].add(node.name)
            else
              state[:empty_hash_locals].delete(node.name)
            end
          end
        when Prism::InstanceVariableWriteNode
          if state[:in_screen] && SCREEN_HASH_IVARS.include?(node.name) && empty_hash_literal?(node.value)
            report_untyped_hash(node, "#{node.name} = {}", state)
          end
        when Prism::ConstantWriteNode
          val = eval_const_int(node.value, state[:const_ints], state[:namespace])
          if val.is_a?(Integer) && INT32_RANGE.cover?(val)
            full_path = (state[:namespace] + [node.name.to_s]).join("::")
            state[:const_ints][full_path] = val
          end
          walk_lint(node.value, state)
          return
        when Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode, Prism::ConstantOperatorWriteNode
          walk_lint(node.value, state)
          return
        when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode, Prism::ConstantPathOperatorWriteNode
          # Check the parent namespace of `Foo::BAR = 1` in case `Foo` is server_only,
          # without flagging `BAR` itself as a read.
          walk_lint(node.target.parent, state) if node.target.is_a?(Prism::ConstantPathNode) && node.target.parent
          walk_lint(node.value, state)
          return
        when Prism::ConstantPathNode
          check_server_only_const_ref(node, state)
          # If the path is dynamic (e.g. `obj::FOO`), still lint the receiver expression.
          if AstLowerer.constant_name(node).nil?
            walk_lint(node.parent, state)
          end
          return
        when Prism::ConstantReadNode
          check_server_only_const_ref(node, state)
          return
        end

        node.compact_child_nodes.each { |child| walk_lint(child, state) }
      end

      # --- Rule 1: >31-bit integer literals & constant expressions ---

      def constant_int_expr?(node)
        case node
        when Prism::IntegerNode
          true
        when Prism::ParenthesesNode
          body = node.body&.body
          body&.length == 1 && constant_int_expr?(body.first)
        when Prism::CallNode
          if %i[-@ +@ ~].include?(node.name) && node.arguments.nil? && node.block.nil?
            constant_int_expr?(node.receiver)
          elsif BYTE_MULTIPLIERS.key?(node.name) && node.arguments.nil? && node.block.nil?
            constant_int_expr?(node.receiver)
          elsif %i[+ - * / % ** << >> & | ^].include?(node.name) && node.block.nil?
            args = node.arguments&.arguments
            args&.length == 1 && constant_int_expr?(node.receiver) && constant_int_expr?(args.first)
          else
            false
          end
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          true
        else
          false
        end
      end

      def check_int_expression(node, state)
        return if state[:reported_int_nodes].include?(node.object_id)

        val = eval_const_int(node, state[:const_ints], state[:namespace])
        return if val.nil?

        if val == :overflow || (val.is_a?(Integer) && !INT32_RANGE.cover?(val))
          # If an inner child already overflows, let recursion report the tightest offending node
          # unless the current node itself is an IntegerNode or the overflow happens at this op.
          if !node.is_a?(Prism::IntegerNode) && any_child_overflows?(node, state[:const_ints], state[:namespace])
            return
          end

          mark_subtree_reported(node, state[:reported_int_nodes])
          detail = val == :overflow ? "exceeds 32-bit signed integer range" : "evaluates to #{val}, outside 32-bit signed integer range (#{INT32_MIN}..#{INT32_MAX})"
          add_diagnostic(
            state,
            rule: :integer_overflow,
            node: node,
            message: "Integer #{node.slice.inspect} #{detail}; compiled wasm32/Spinel builds raise RangeError on >31-bit values."
          )
        end
      end

      def any_child_overflows?(node, const_ints, namespace)
        children =
          case node
          when Prism::CallNode
            [node.receiver, *Array(node.arguments&.arguments)].compact
          when Prism::ParenthesesNode
            Array(node.body&.body)
          else
            []
          end
        children.any? do |child|
          val = eval_const_int(child, const_ints, namespace)
          val == :overflow || (val.is_a?(Integer) && !INT32_RANGE.cover?(val))
        end
      end

      def mark_subtree_reported(node, set)
        return if node.nil?

        set.add(node.object_id)
        node.compact_child_nodes.each { |child| mark_subtree_reported(child, set) }
      end

      def eval_const_int(node, const_ints, namespace)
        case node
        when Prism::IntegerNode
          node.value
        when Prism::ParenthesesNode
          body = node.body&.body
          body&.length == 1 ? eval_const_int(body.first, const_ints, namespace) : nil
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          resolve_const_int(node, const_ints, namespace)
        when Prism::CallNode
          return nil if node.block

          if node.arguments.nil?
            lhs = eval_const_int(node.receiver, const_ints, namespace)
            return :overflow if lhs == :overflow
            return nil unless lhs.is_a?(Integer)

            case node.name
            when :-@ then -lhs
            when :+@ then +lhs
            when :~ then ~lhs
            else
              mult = BYTE_MULTIPLIERS[node.name]
              mult ? lhs * mult : nil
            end
          elsif node.arguments.arguments.length == 1
            lhs = eval_const_int(node.receiver, const_ints, namespace)
            rhs = eval_const_int(node.arguments.arguments.first, const_ints, namespace)
            return :overflow if lhs == :overflow || rhs == :overflow
            return nil unless lhs.is_a?(Integer) && rhs.is_a?(Integer)

            case node.name
            when :+ then lhs + rhs
            when :- then lhs - rhs
            when :* then lhs * rhs
            when :/ then rhs == 0 ? nil : lhs / rhs
            when :% then rhs == 0 ? nil : lhs % rhs
            when :& then lhs & rhs
            when :| then lhs | rhs
            when :^ then lhs ^ rhs
            when :**
              return nil if rhs < 0
              return :overflow if lhs.abs >= 2 && rhs >= 32

              lhs**rhs
            when :<<
              return nil if rhs < 0
              return :overflow if lhs != 0 && rhs >= 32

              lhs << rhs
            when :>>
              return nil if rhs < 0

              lhs >> rhs
            end
          end
        end
      end

      def resolve_const_int(node, const_ints, namespace)
        raw = AstLowerer.constant_name(node)
        return nil unless raw

        candidates_for(raw, namespace).each do |full|
          return const_ints[full] if const_ints.key?(full)
        end
        nil
      end

      # --- Rule 2: Untyped `{}` hashes in Native::Screen params:/args:/props: ---

      def screen_superclass?(superclass)
        name = AstLowerer.constant_name(superclass)
        return false unless name

        clean = name.delete_prefix("::")
        clean == "InstantRecord::Native::Screen" || clean == "Native::Screen" || clean == "Screen"
      end

      def collect_empty_hash_helpers(body)
        helpers = Set.new
        return helpers unless body

        Array(body.body).each do |stmt|
          next unless stmt.is_a?(Prism::DefNode) && stmt.receiver.nil?
          next if stmt.parameters

          def_stmts = stmt.body&.body
          if def_stmts&.length == 1 && empty_hash_literal?(def_stmts.first)
            helpers.add(stmt.name)
          end
        end
        helpers
      end

      def check_screen_def_params(def_node, state)
        params = def_node.parameters
        return unless params

        Array(params.optionals).each do |opt|
          if SCREEN_HASH_KEYS.include?(opt.name) && empty_hash_literal?(opt.value)
            report_untyped_hash(opt, "#{opt.name} = {}", state)
          end
        end
        Array(params.keywords).each do |kw|
          next unless kw.is_a?(Prism::OptionalKeywordParameterNode)

          if SCREEN_HASH_KEYS.include?(kw.name) && empty_hash_literal?(kw.value)
            report_untyped_hash(kw, "#{kw.name}: {}", state)
          end
        end
      end

      def check_screen_call(call_node, state)
        # Track mutations on local hash variables (e.g. `h["k"] = "v"` makes it typed)
        if %i[[]= store merge! update].include?(call_node.name) && call_node.receiver.is_a?(Prism::LocalVariableReadNode)
          state[:empty_hash_locals].delete(call_node.receiver.name)
        end

        # `node.link_params = {}` / `node.args = {}` / `node.props = {}`
        if SCREEN_HASH_SETTERS.include?(call_node.name)
          val = call_node.arguments&.arguments&.first
          if val && untyped_hash_expr?(val, state)
            report_untyped_hash(val, "#{call_node.name} {}", state)
          end
          return
        end

        # Keyword arguments `params: {}`, `args: {}`, `props: {}`
        Array(call_node.arguments&.arguments).each do |arg|
          next unless arg.is_a?(Prism::KeywordHashNode)

          arg.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::SymbolNode)

            key = assoc.key.unescaped.to_sym
            next unless SCREEN_HASH_KEYS.include?(key)

            if untyped_hash_expr?(assoc.value, state)
              report_untyped_hash(assoc.value, "#{key}: #{assoc.value.slice}", state)
            end
          end
        end
      end

      def empty_hash_literal?(node)
        case node
        when Prism::HashNode
          node.elements.empty?
        when Prism::CallNode
          node.name == :new &&
            %w[Hash ::Hash].include?(AstLowerer.constant_name(node.receiver)) &&
            node.arguments.nil? &&
            node.block.nil?
        when Prism::ParenthesesNode
          body = node.body&.body
          body&.length == 1 && empty_hash_literal?(body.first)
        else
          false
        end
      end

      def untyped_hash_expr?(node, state)
        return true if empty_hash_literal?(node)

        case node
        when Prism::LocalVariableReadNode
          state[:empty_hash_locals].include?(node.name)
        when Prism::CallNode
          node.receiver.nil? && node.arguments.nil? && node.block.nil? &&
            state[:empty_hash_helpers].include?(node.name)
        when Prism::IfNode
          branch_has_empty_hash?(node.statements, state) ||
            (node.subsequent.is_a?(Prism::ElseNode) && branch_has_empty_hash?(node.subsequent.statements, state)) ||
            (node.subsequent.is_a?(Prism::IfNode) && untyped_hash_expr?(node.subsequent, state))
        when Prism::UnlessNode
          branch_has_empty_hash?(node.statements, state) ||
            (node.else_clause && branch_has_empty_hash?(node.else_clause.statements, state))
        when Prism::ParenthesesNode
          body = node.body&.body
          body&.length == 1 && untyped_hash_expr?(body.first, state)
        else
          false
        end
      end

      def branch_has_empty_hash?(stmts, state)
        return false unless stmts && stmts.body.any?

        untyped_hash_expr?(stmts.body.last, state)
      end

      def report_untyped_hash(node, snippet, state)
        add_diagnostic(
          state,
          rule: :untyped_screen_hash,
          node: node,
          message: "Untyped empty hash in Native::Screen (#{snippet}); use InstantRecord::Native::Node.strings so Spinel types it as Hash[String, String]."
        )
      end

      # --- Rule 3: server_only constant references from shared code ---

      def check_server_only_const_ref(node, state)
        raw = AstLowerer.constant_name(node)
        return unless raw

        candidates_for(raw, state[:namespace]).each do |full|
          matched = matching_server_only_constant(full, state[:server_only])
          next unless matched

          defined_at = state[:server_only][matched]
          origin = defined_at ? " (defined inside server_only at #{defined_at})" : " (server-only gem constant)"
          add_diagnostic(
            state,
            rule: :server_only_constant,
            node: node,
            message: "Shared/client code references server_only constant `#{matched}`#{origin}; wrap in `server_only` or define a client counterpart."
          )
          return
        end
      end

      def matching_server_only_constant(full_name, server_only)
        return full_name if server_only.key?(full_name)

        # Also catch `ServerOnlyClass::SUB` when `ServerOnlyClass` itself is server_only.
        parts = full_name.split("::")
        (parts.length - 1).downto(1) do |len|
          prefix = parts[0, len].join("::")
          return prefix if server_only.key?(prefix)
        end
        nil
      end

      def candidates_for(raw, namespace)
        if raw.start_with?("::")
          [raw.delete_prefix("::")]
        else
          list = []
          namespace.length.downto(0) do |depth|
            prefix = namespace[0, depth]
            list << (prefix.empty? ? raw : (prefix + [raw]).join("::"))
          end
          list
        end
      end

      def browser_predicate(node)
        case node
        when Prism::ParenthesesNode
          body = node.body&.body
          body&.length == 1 ? browser_predicate(body.first) : nil
        when Prism::CallNode
          if node.name == :browser? && node.arguments.nil? && node.block.nil?
            recv = AstLowerer.constant_name(node.receiver)
            return :true if recv == "InstantRecord" || recv == "::InstantRecord"
          elsif node.name == :! && node.arguments.nil? && node.block.nil?
            inner = browser_predicate(node.receiver)
            return inner == :true ? :false : :true if inner
          end
          nil
        end
      end

      def add_diagnostic(state, rule:, node:, message:)
        loc = node.location
        state[:diagnostics] << Diagnostic.new(
          rule: rule,
          file: state[:rel],
          line: loc.start_line,
          column: loc.start_column + 1,
          message: message
        )
      end
    end
  end
end
