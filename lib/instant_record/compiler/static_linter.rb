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
        InstantRecord::Inertia::Renderer
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

      # Where compiled code lives in a Rails app.
      RAILS_FOLDERS = %w[app/models app/controllers app/helpers app/screens config/routes].freeze
      RAILS_FILES = %w[config/application.rb config/routes.rb config/importmap.rb].freeze
      private_constant :RAILS_FOLDERS, :RAILS_FILES

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
        parsed_files = parse(discover_files)

        server_only_defs, client_defs = collect_defs(parsed_files)
        server_only_defs = @precollected_server_only if @precollected_server_only

        # Constant name => where it is defined, nil for a gem constant.
        @server_only = {}
        server_only_defs.each do |name, loc|
          @server_only[name] = loc unless client_defs.include?(name)
        end
        SERVER_ONLY_GEM_CONSTANTS.each do |name|
          @server_only[name] ||= nil unless client_defs.include?(name)
        end

        @diagnostics = []
        parsed_files.each do |rel, parsed|
          lint_file(rel, parsed.value) if parsed.success?
        end

        @diagnostics.sort_by! { |d| [d.file, d.line, d.column, d.rule.to_s] }
        Result.new(files_checked: parsed_files.size, diagnostics: @diagnostics)
      end

      def discover_files
        return [] unless File.directory?(@root)

        candidates =
          if @only_files
            @only_files
          elsif !@staged && rails_layout?
            # Raw Rails app root (used by `instant_record:doctor`): scan only
            # what enters compilation.
            rails_files
          else
            # Staged tree or standalone fixture directory.
            Dir.glob("**/*.rb", base: @root).reject { |rel| excluded_staged?(rel) }
          end

        paths = candidates.reject { |rel| excluded_custom?(rel) }.sort.map { |rel| File.join(@root, rel) }
        @only_files ? paths.select { |path| File.file?(path) } : paths
      end

      def scan_constant_definitions(files)
        server_only_defs, client_defs = collect_defs(parse(files))
        server_only_defs.reject { |name, _| client_defs.include?(name) }
      end

      private

      def rails_layout?
        RAILS_FOLDERS.any? { |dir| File.directory?(File.join(@root, dir)) } ||
          RAILS_FILES.any? { |file| File.file?(File.join(@root, file)) }
      end

      def rails_files
        in_folders = RAILS_FOLDERS.flat_map do |folder|
          Dir.glob("**/*.rb", base: File.join(@root, folder)).map { |rel| File.join(folder, rel) }
        end
        in_folders + RAILS_FILES.select { |file| File.file?(File.join(@root, file)) }
      end

      def parse(files)
        files.map { |path| [relative_path(path), Prism.parse_file(path)] }
      end

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

      # --- Constant names ---

      # The first definition of each server_only constant, and the set of
      # constants the client defines.
      def collect_defs(parsed_files)
        server_only_defs = {}
        client_defs = Set.new

        parsed_files.each do |rel, parsed|
          next unless parsed.success?

          each_definition(parsed.value) do |name, line, in_server_only|
            if in_server_only
              server_only_defs[name] ||= "#{rel}:#{line}"
            else
              client_defs.add(name)
            end
          end
        end

        [server_only_defs, client_defs]
      end

      def each_definition(node, namespace = [], in_server_only = false, &block)
        return if node.nil?

        if server_only_call?(node)
          each_definition(node.block.body, namespace, true, &block)
          return
        end

        name = defined_name(node, namespace)
        yield name, node.location.start_line, in_server_only if name

        case node
        when Prism::ClassNode, Prism::ModuleNode
          each_definition(node.body, name ? name.split("::") : namespace, in_server_only, &block)
        else
          node.compact_child_nodes.each { |child| each_definition(child, namespace, in_server_only, &block) }
        end
      end

      # The full name of the constant `node` defines, nil when it defines none
      # or the name is dynamic.
      def defined_name(node, namespace)
        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = AstLowerer.constant_name(node.constant_path)
        when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode, Prism::ConstantOperatorWriteNode
          name = node.name.to_s
        when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode, Prism::ConstantPathOperatorWriteNode
          name = AstLowerer.constant_name(node.target)
        end
        # A definition takes the innermost name.
        lookup_names(name, namespace).first if name
      end

      # Every full name `name` may stand for, innermost namespace first.
      def lookup_names(name, namespace)
        return [name.delete_prefix("::")] if name.start_with?("::")
        return [name] if namespace.empty?

        namespace.length.downto(0).map { |depth| [*namespace.first(depth), name].join("::") }
      end

      # Every full name a constant reference may stand for; none when dynamic.
      def referenced_names(node)
        name = AstLowerer.constant_name(node)
        name ? lookup_names(name, @namespace) : []
      end

      def server_only_call?(node)
        node.is_a?(Prism::CallNode) &&
          node.name == :server_only &&
          (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
          node.arguments.nil? &&
          node.block.is_a?(Prism::BlockNode)
      end

      # --- Walk ---

      def lint_file(rel, root)
        @rel = rel
        @namespace = []
        @in_screen = rel.start_with?("app/screens/") ||
                     rel == "lib/instant_record/native/screen.rb" ||
                     rel == "lib/instant_record/native/node.rb"
        @const_ints = {}
        @empty_hash_helpers = Set.new
        @empty_hash_locals = Set.new
        @reported_int_nodes = Set.new.compare_by_identity
        walk(root)
      end

      # A branch that returns decides itself which children are walked.
      def walk(node)
        return if node.nil?

        case node
        when Prism::DefinedNode
          # `defined?(ServerOnlyConst)` is safe and never raises NameError.
          return
        when Prism::CallNode
          return if server_only_call?(node)

          check_int(node) if integer_operation?(node.name)
          check_screen_call(node) if @in_screen
        when Prism::IntegerNode
          check_int(node)
        when Prism::IfNode
          case browser_predicate(node.predicate)
          when true then return walk(node.statements)
          when false then return walk(node.subsequent)
          end
        when Prism::UnlessNode
          case browser_predicate(node.predicate)
          when true then return walk(node.else_clause)
          when false then return walk(node.statements)
          end
        when Prism::ClassNode
          return walk_class(node)
        when Prism::ModuleNode
          return walk_namespace(node)
        when Prism::DefNode
          return walk_def(node)
        when Prism::LocalVariableWriteNode
          track_empty_hash_local(node) if @in_screen
        when Prism::InstanceVariableWriteNode
          if @in_screen && SCREEN_HASH_IVARS.include?(node.name) && empty_hash_literal?(node.value)
            report_untyped_hash(node, "#{node.name} = {}")
          end
        when Prism::ConstantWriteNode
          value = eval_const_int(node.value)
          @const_ints[defined_name(node, @namespace)] = value if value.is_a?(Integer) && !overflow?(value)
        when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode, Prism::ConstantPathOperatorWriteNode
          # Check the parent namespace of `Foo::BAR = 1` in case `Foo` is server_only,
          # without flagging `BAR` itself as a read.
          walk(node.target.parent)
          return walk(node.value)
        when Prism::ConstantPathNode
          check_server_only_const_ref(node)
          # If the path is dynamic (e.g. `obj::FOO`), still lint the receiver expression.
          walk(node.parent) unless AstLowerer.constant_name(node)
          return
        when Prism::ConstantReadNode
          check_server_only_const_ref(node)
        end

        node.compact_child_nodes.each { |child| walk(child) }
      end

      def walk_namespace(node)
        outer = @namespace
        @namespace = defined_name(node, outer)&.split("::") || outer
        walk(node.body)
        @namespace = outer
      end

      def walk_class(node)
        walk(node.superclass)
        outer_screen = @in_screen
        outer_helpers = @empty_hash_helpers

        @in_screen ||= screen_superclass?(node.superclass)
        @empty_hash_helpers = @in_screen ? collect_empty_hash_helpers(node) : Set.new
        walk_namespace(node)

        @in_screen = outer_screen
        @empty_hash_helpers = outer_helpers
      end

      def walk_def(node)
        outer_locals = @empty_hash_locals
        @empty_hash_locals = Set.new
        check_screen_def_params(node.parameters) if @in_screen && node.parameters
        walk(node.parameters)
        walk(node.body)
        @empty_hash_locals = outer_locals
      end

      # true or false when the condition is `InstantRecord.browser?` or its
      # negation, nil for any other condition.
      def browser_predicate(node)
        case node
        when Prism::ParenthesesNode
          browser_predicate(only_statement(node))
        when Prism::CallNode
          return unless node.arguments.nil? && node.block.nil?

          case node.name
          when :browser?
            true if %w[InstantRecord ::InstantRecord].include?(AstLowerer.constant_name(node.receiver))
          when :!
            inner = browser_predicate(node.receiver)
            inner.nil? ? nil : !inner
          end
        end
      end

      # The single statement in a method body or a pair of parentheses, else nil.
      def only_statement(node)
        statements = body_statements(node)
        statements.first if statements.length == 1
      end

      # The statements in a class body, a method body or a pair of parentheses. A
      # body with a rescue or ensure keeps its own statements one level deeper.
      def body_statements(node)
        body = node.body
        body = body.statements if body.is_a?(Prism::BeginNode)
        body.is_a?(Prism::StatementsNode) ? body.body : []
      end

      # --- Rule 1: >31-bit integer literals & constant expressions ---

      # Operators and byte multipliers. Any other call is never reported, so this
      # only saves evaluating it.
      def integer_operation?(name)
        BYTE_MULTIPLIERS.key?(name) || name.match?(/\A[^[:word:]]/)
      end

      def check_int(node)
        return if @reported_int_nodes.include?(node)

        value = eval_const_int(node)
        return unless overflow?(value)

        # When an operand already overflows, the walk reports that one instead.
        if node.is_a?(Prism::CallNode)
          operands = [node.receiver, *node.arguments&.arguments]
          return if operands.any? { |operand| overflow?(eval_const_int(operand)) }
        end

        mark_subtree_reported(node)
        detail = value == :overflow ? "exceeds 32-bit signed integer range" : "evaluates to #{value}, outside 32-bit signed integer range (#{INT32_MIN}..#{INT32_MAX})"
        add_diagnostic(
          rule: :integer_overflow,
          node: node,
          message: "Integer #{node.slice.inspect} #{detail}; compiled wasm32/Spinel builds raise RangeError on >31-bit values."
        )
      end

      def mark_subtree_reported(node)
        @reported_int_nodes.add(node)
        node.compact_child_nodes.each { |child| mark_subtree_reported(child) }
      end

      def overflow?(value)
        value == :overflow || (value.is_a?(Integer) && !INT32_RANGE.cover?(value))
      end

      # The Integer a constant expression evaluates to, :overflow when it is too
      # large to compute, nil when it is not a constant integer. Before Ruby 3.4
      # a huge power can also give Float::INFINITY, which is never reported.
      def eval_const_int(node)
        case node
        when Prism::IntegerNode
          node.value
        when Prism::ParenthesesNode
          eval_const_int(only_statement(node))
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          name = referenced_names(node).find { |full| @const_ints.key?(full) }
          @const_ints[name]
        when Prism::CallNode
          return if node.block

          args = node.arguments&.arguments || []
          return if args.length > 1

          operands = [node.receiver, *args].map { |operand| eval_const_int(operand) }
          return :overflow if operands.include?(:overflow)
          return unless operands.all?(Integer)

          args.empty? ? eval_unary(node.name, *operands) : eval_binary(node.name, *operands)
        end
      end

      def eval_unary(name, value)
        case name
        when :-@ then -value
        when :+@ then value
        when :~ then ~value
        else
          multiplier = BYTE_MULTIPLIERS[name]
          value * multiplier if multiplier
        end
      end

      def eval_binary(name, lhs, rhs)
        case name
        when :+ then lhs + rhs
        when :- then lhs - rhs
        when :* then lhs * rhs
        when :/ then lhs / rhs unless rhs == 0
        when :% then lhs % rhs unless rhs == 0
        when :& then lhs & rhs
        when :| then lhs | rhs
        when :^ then lhs ^ rhs
        when :**
          return if rhs < 0

          lhs.abs >= 2 && rhs >= 32 ? :overflow : lhs**rhs
        when :<<
          return if rhs < 0

          lhs != 0 && rhs >= 32 ? :overflow : lhs << rhs
        when :>> then lhs >> rhs unless rhs < 0
        end
      end

      # --- Rule 2: Untyped `{}` hashes in Native::Screen params:/args:/props: ---

      def screen_superclass?(superclass)
        name = AstLowerer.constant_name(superclass)&.delete_prefix("::")
        %w[InstantRecord::Native::Screen Native::Screen Screen].include?(name)
      end

      def collect_empty_hash_helpers(class_node)
        helpers = Set.new
        body_statements(class_node).each do |stmt|
          next unless stmt.is_a?(Prism::DefNode) && stmt.receiver.nil? && stmt.parameters.nil?

          helpers.add(stmt.name) if empty_hash_literal?(only_statement(stmt))
        end
        helpers
      end

      def track_empty_hash_local(write_node)
        if empty_hash_literal?(write_node.value)
          @empty_hash_locals.add(write_node.name)
        else
          @empty_hash_locals.delete(write_node.name)
        end
      end

      def check_screen_def_params(params)
        params.optionals.each { |param| check_screen_default(param, "#{param.name} = {}") }
        params.keywords.grep(Prism::OptionalKeywordParameterNode) do |param|
          check_screen_default(param, "#{param.name}: {}")
        end
      end

      def check_screen_default(param, snippet)
        return unless SCREEN_HASH_KEYS.include?(param.name) && empty_hash_literal?(param.value)

        report_untyped_hash(param, snippet)
      end

      def check_screen_call(call_node)
        args = call_node.arguments&.arguments || []

        # Track mutations on local hash variables (e.g. `h["k"] = "v"` makes it typed)
        if %i[[]= store merge! update].include?(call_node.name) && call_node.receiver.is_a?(Prism::LocalVariableReadNode)
          @empty_hash_locals.delete(call_node.receiver.name)
        end

        # `node.link_params = {}` / `node.args = {}` / `node.props = {}`
        if SCREEN_HASH_SETTERS.include?(call_node.name)
          report_untyped_hash(args.first, "#{call_node.name} {}") if untyped_hash_expr?(args.first)
          return
        end

        # Keyword arguments `params: {}`, `args: {}`, `props: {}`
        args.grep(Prism::KeywordHashNode).flat_map(&:elements).each do |assoc|
          next unless assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::SymbolNode)

          key = assoc.key.unescaped.to_sym
          if SCREEN_HASH_KEYS.include?(key) && untyped_hash_expr?(assoc.value)
            report_untyped_hash(assoc.value, "#{key}: #{assoc.value.slice}")
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
          empty_hash_literal?(only_statement(node))
        else
          false
        end
      end

      # Whether the expression is, or may return, an empty hash.
      def untyped_hash_expr?(node)
        return true if empty_hash_literal?(node)

        case node
        when Prism::LocalVariableReadNode
          @empty_hash_locals.include?(node.name)
        when Prism::CallNode
          node.receiver.nil? && node.arguments.nil? && node.block.nil? &&
            @empty_hash_helpers.include?(node.name)
        when Prism::IfNode
          untyped_hash_expr?(node.statements) || untyped_hash_expr?(node.subsequent)
        when Prism::UnlessNode
          untyped_hash_expr?(node.statements) || untyped_hash_expr?(node.else_clause)
        when Prism::ElseNode
          untyped_hash_expr?(node.statements)
        when Prism::StatementsNode
          untyped_hash_expr?(node.body.last)
        when Prism::ParenthesesNode
          untyped_hash_expr?(only_statement(node))
        else
          false
        end
      end

      def report_untyped_hash(node, snippet)
        add_diagnostic(
          rule: :untyped_screen_hash,
          node: node,
          message: "Untyped empty hash in Native::Screen (#{snippet}); use InstantRecord::Native::Node.strings so Spinel types it as Hash[String, String]."
        )
      end

      # --- Rule 3: server_only constant references from shared code ---

      def check_server_only_const_ref(node)
        matched = nil
        referenced_names(node).find { |full| matched = matching_server_only_constant(full) }
        return unless matched

        defined_at = @server_only[matched]
        origin = defined_at ? " (defined inside server_only at #{defined_at})" : " (server-only gem constant)"
        add_diagnostic(
          rule: :server_only_constant,
          node: node,
          message: "Shared/client code references server_only constant `#{matched}`#{origin}; wrap in `server_only` or define a client counterpart."
        )
      end

      # The name itself or the closest namespace around it that is server_only:
      # `ServerOnlyClass::SUB` matches `ServerOnlyClass`.
      def matching_server_only_constant(full_name)
        until @server_only.key?(full_name)
          full_name, separator, = full_name.rpartition("::")
          return if separator.empty?
        end
        full_name
      end

      def add_diagnostic(rule:, node:, message:)
        loc = node.location
        @diagnostics << Diagnostic.new(
          rule: rule,
          file: @rel,
          line: loc.start_line,
          column: loc.start_column + 1,
          message: message
        )
      end
    end
  end
end
