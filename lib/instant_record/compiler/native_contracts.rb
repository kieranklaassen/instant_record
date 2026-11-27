require "prism"
require_relative "../native/contract"
require_relative "runner"

module InstantRecord
  class Compiler
    # Statically extracts `InstantRecord::Native::Contract` definitions from
    # `app/screens/**/*.rb` using Ruby's Prism parser without booting Rails or
    # evaluating application code.
    module NativeContracts
      SCALAR_METHODS = %i[string int float bool date].freeze

      module_function

      def extract_dir(screens_dir)
        return [] unless screens_dir && File.directory?(screens_dir)

        contracts = []
        seen = {}

        Dir.glob("**/*.rb", base: screens_dir).sort.each do |rel|
          path = File.join(screens_dir, rel)
          extract_file(path).each do |contract|
            if (previous = seen[contract.component])
              raise BuildError,
                "Duplicate native contract #{contract.component.inspect} in #{path} (already declared in #{previous})"
            end
            seen[contract.component] = path
            contracts << contract
          end
        end

        contracts.sort_by(&:component)
      end

      def extract_file(path)
        extract_source(File.read(path), path: path)
      end

      def extract_source(source, path: "<screen>")
        parsed = Prism.parse(source)
        unless parsed.success?
          details = parsed.errors.map { |err| "#{path}:#{err.location.start_line}: #{err.message}" }.join("\n  ")
          raise BuildError, "Could not parse native screen for contract codegen:\n  #{details}"
        end

        Extractor.new(path).extract(parsed.value)
      end

      # Walks a Prism AST to extract class-level `contract` blocks.
      class Extractor
        def initialize(path)
          @path = path
        end

        def extract(root)
          contracts = []
          walk(root, [], contracts)
          contracts
        end

        private

        def walk(node, namespace, contracts)
          return unless node

          case node
          when Prism::ProgramNode
            walk(node.statements, namespace, contracts)
          when Prism::StatementsNode
            node.body.each { |stmt| walk(stmt, namespace, contracts) }
          when Prism::ModuleNode
            walk(node.body, namespace + [constant_name(node.constant_path)], contracts)
          when Prism::ClassNode
            class_name = (namespace + [constant_name(node.constant_path)]).compact.join("::")
            if node.body.is_a?(Prism::StatementsNode)
              node.body.body.each do |stmt|
                if stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && stmt.name == :contract
                  contracts << parse_contract(stmt, class_name)
                else
                  walk(stmt, namespace + [constant_name(node.constant_path)], contracts)
                end
              end
            else
              walk(node.body, namespace + [constant_name(node.constant_path)], contracts)
            end
          end
        end

        def parse_contract(call, screen_name)
          positional, kwargs = split_arguments(call)
          if positional.length != 1 || !kwargs.empty?
            fail_at!(call, "contract expects a single component name literal (e.g. contract \"ConversationView\" do |c| ... end)")
          end

          component = literal_name(positional.first, call, "component name")
          builder = Native::ContractBuilder.new(component, screen: screen_name)

          if call.block
            parse_contract_block(call.block, builder, allow_actions: true)
          end

          builder.build
        rescue ArgumentError => e
          fail_at!(call, e.message)
        end

        def parse_contract_block(block, builder, allow_actions:)
          fail_at!(block, "contract expects a `do |c| ... end` block") unless block.is_a?(Prism::BlockNode)

          param_name = block_param_name(block)
          return unless block.body

          statements = block.body.is_a?(Prism::StatementsNode) ? block.body.body : [block.body]
          statements.each do |stmt|
            fail_at!(stmt, "Only declarative contract calls are allowed inside a contract block") unless stmt.is_a?(Prism::CallNode)
            check_receiver!(stmt, param_name)

            case stmt.name
            when *SCALAR_METHODS
              parse_scalar_field(stmt, stmt.name, builder)
            when :prop
              parse_prop_field(stmt, builder)
            when :one
              parse_one_field(stmt, builder)
            when :many
              parse_many_field(stmt, builder)
            when :action
              fail_at!(stmt, "Actions may only be declared at the top level of a contract") unless allow_actions
              parse_action(stmt, builder)
            else
              fail_at!(stmt, "Unknown contract declaration #{stmt.name.inspect}")
            end
          rescue ArgumentError => e
            fail_at!(stmt, e.message)
          end
        end

        def parse_scalar_field(call, type, builder)
          positional, kwargs = split_arguments(call)
          fail_at!(call, "#{call.name} expects a field name") unless positional.length == 1
          fail_at!(call, "#{call.name} does not take a block") if call.block

          name = literal_name(positional.first, call, "field name")
          optional = extract_optional!(kwargs, call, allowed: %i[optional])
          builder.prop(name, type, optional: optional)
        end

        def parse_prop_field(call, builder)
          positional, kwargs = split_arguments(call)
          unless positional.length == 1 || positional.length == 2
            fail_at!(call, "prop expects (name, type = :string, optional: false)")
          end
          fail_at!(call, "prop does not take a block") if call.block

          name = literal_name(positional[0], call, "field name")
          type = positional[1] ? literal_name(positional[1], call, "field type") : "string"
          optional = extract_optional!(kwargs, call, allowed: %i[optional])
          builder.prop(name, type, optional: optional)
        end

        def parse_one_field(call, builder)
          positional, kwargs = split_arguments(call)
          fail_at!(call, "one expects a field name and a block") unless positional.length == 1 && call.block

          name = literal_name(positional.first, call, "field name")
          optional = extract_optional!(kwargs, call, allowed: %i[optional as])
          as = kwargs.key?(:as) ? literal_name(kwargs[:as], call, "as:") : nil

          builder.one(name, as: as, optional: optional) do |nested|
            parse_contract_block(call.block, nested, allow_actions: false)
          end
        end

        def parse_many_field(call, builder)
          positional, kwargs = split_arguments(call)
          fail_at!(call, "many expects a field name") unless positional.length == 1

          name = literal_name(positional.first, call, "field name")
          optional = extract_optional!(kwargs, call, allowed: %i[optional as of])
          as = kwargs.key?(:as) ? literal_name(kwargs[:as], call, "as:") : nil
          of = kwargs.key?(:of) ? literal_name(kwargs[:of], call, "of:") : nil

          if of
            fail_at!(call, "many #{name.inspect} with of: cannot also take a block") if call.block
            fail_at!(call, "many #{name.inspect} with of: cannot also specify as:") if as
            builder.many(name, of: of, optional: optional)
          else
            fail_at!(call, "many #{name.inspect} requires either of: or a block") unless call.block
            builder.many(name, as: as, optional: optional) do |nested|
              parse_contract_block(call.block, nested, allow_actions: false)
            end
          end
        end

        def parse_action(call, builder)
          positional, kwargs = split_arguments(call)
          fail_at!(call, "action expects a single action name") unless positional.length == 1 && kwargs.empty?

          name = literal_name(positional.first, call, "action name")
          if call.block
            builder.action(name) { |action_builder| parse_action_block(call.block, action_builder) }
          else
            builder.action(name)
          end
        end

        def parse_action_block(block, action_builder)
          fail_at!(block, "action expects a `do |a| ... end` block") unless block.is_a?(Prism::BlockNode)

          param_name = block_param_name(block)
          return unless block.body

          statements = block.body.is_a?(Prism::StatementsNode) ? block.body.body : [block.body]
          statements.each do |stmt|
            fail_at!(stmt, "Only arg/value declarations are allowed inside an action block") unless stmt.is_a?(Prism::CallNode)
            check_receiver!(stmt, param_name)
            fail_at!(stmt, "Unknown action parameter declaration #{stmt.name.inspect} (expected arg or value)") unless %i[arg value].include?(stmt.name)
            fail_at!(stmt, "#{stmt.name} does not take a block") if stmt.block

            positional, kwargs = split_arguments(stmt)
            unless positional.length == 1 || positional.length == 2
              fail_at!(stmt, "#{stmt.name} expects (name, type = :string, optional: false)")
            end

            name = literal_name(positional[0], stmt, "parameter name")
            type = positional[1] ? literal_name(positional[1], stmt, "parameter type") : "string"
            optional = extract_optional!(kwargs, stmt, allowed: %i[optional])

            if stmt.name == :arg
              action_builder.arg(name, type, optional: optional)
            else
              action_builder.value(name, type, optional: optional)
            end
          end
        rescue ArgumentError => e
          fail_at!(block, e.message)
        end

        def block_param_name(block)
          params = block.parameters
          return nil unless params.is_a?(Prism::BlockParametersNode) && params.parameters

          requireds = params.parameters.requireds
          return nil if requireds.empty?

          if requireds.length != 1 || !requireds.first.is_a?(Prism::RequiredParameterNode)
            fail_at!(block, "Contract blocks expect a single builder parameter (e.g. do |c|)")
          end
          requireds.first.name
        end

        def check_receiver!(call, param_name)
          if param_name
            unless call.receiver.is_a?(Prism::LocalVariableReadNode) && call.receiver.name == param_name
              fail_at!(call, "Call #{call.name} on the block builder `#{param_name}`")
            end
          elsif call.receiver
            fail_at!(call, "Unexpected receiver on #{call.name}")
          end
        end

        def split_arguments(call)
          return [[], {}] unless call.arguments

          positional = []
          kwargs = {}
          call.arguments.arguments.each do |arg|
            if arg.is_a?(Prism::KeywordHashNode)
              arg.elements.each do |element|
                unless element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode)
                  fail_at!(element, "Contract keyword arguments must use literal symbol keys")
                end
                kwargs[element.key.unescaped.to_sym] = element.value
              end
            else
              positional << arg
            end
          end
          [positional, kwargs]
        end

        def extract_optional!(kwargs, call, allowed:)
          unknown = kwargs.keys - allowed
          unless unknown.empty?
            fail_at!(call, "Unknown keyword argument(s) #{unknown.map(&:inspect).join(', ')} on #{call.name}")
          end
          return false unless kwargs.key?(:optional)

          literal_bool(kwargs[:optional], call, "optional:")
        end

        def literal_name(node, context, label)
          case node
          when Prism::StringNode
            node.unescaped
          when Prism::SymbolNode
            node.unescaped
          else
            fail_at!(context, "#{label} must be a string or symbol literal")
          end
        end

        def literal_bool(node, context, label)
          case node
          when Prism::TrueNode then true
          when Prism::FalseNode then false
          else
            fail_at!(context, "#{label} must be true or false")
          end
        end

        def constant_name(node)
          case node
          when Prism::ConstantReadNode
            node.name.to_s
          when Prism::ConstantPathNode
            parent = node.parent ? constant_name(node.parent) : nil
            [parent, node.name.to_s].compact.join("::")
          end
        end

        def fail_at!(node, message)
          line = node.location.start_line
          raise BuildError, "#{@path}:#{line}: #{message}"
        end
      end
    end
  end
end
