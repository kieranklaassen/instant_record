require "json"
require "prism"
require_relative "runner"

module InstantRecord
  class Compiler
    # The entries' `SyncActions.dispatch`: finds each `sync_action` declared under
    # app/models and writes the `case` that calls it.
    module EntryBuilder
      SYNC_ACTION_NAME_PATTERN = /\A[a-z_][a-zA-Z0-9_]*[!?]?\z/

      SYNC_ACTIONS_EMPTY = <<~'RUBY'

        module InstantRecord
          module SyncActions
            def self.dispatch(name, _args)
              raise ArgumentError, "Unknown sync_action: " + name
            end
          end
        end
      RUBY

      SYNC_ACTIONS = <<~'RUBY'

        module InstantRecord
          module SyncActions
            def self.dispatch(name, args)
              case name
        <<cases>>      else raise ArgumentError, "Unknown sync_action: " + name
              end
            end
          end
        end
      RUBY

      module_function

      def discover_sync_actions(app_dir)
        return [] unless app_dir

        models_dir = File.join(app_dir, "app/models")
        return [] unless File.directory?(models_dir)

        discovered = []
        Dir.glob("**/*.rb", base: models_dir).sort.each do |rel|
          path = File.join(models_dir, rel)
          parsed = Prism.parse_file(path)
          raise BuildError, "Could not parse #{path} for sync_action discovery" unless parsed.success?

          collect_sync_actions(parsed.value, [], path, discovered)
        end
        discovered.sort_by { |entry| "#{entry[:class_name]}.#{entry[:action]}" }
      end

      def sync_actions_module(app_dir)
        found = discover_sync_actions(app_dir)
        return SYNC_ACTIONS_EMPTY if found.empty?

        cases = found.map { |entry| "      when #{JSON.generate("#{entry[:class_name]}.#{entry[:action]}")} then #{entry[:call]}\n" }.join
        fill(SYNC_ACTIONS, { "cases" => cases })
      end

      def collect_sync_actions(node, namespace, path, discovered)
        return unless node

        case node
        when Prism::ProgramNode
          collect_sync_actions(node.statements, namespace, path, discovered)
        when Prism::StatementsNode
          node.body.each { |child| collect_sync_actions(child, namespace, path, discovered) }
        when Prism::ModuleNode, Prism::ClassNode
          nested = namespace + (constant_path_parts(node.constant_path) || [])
          collect_class_actions(node, nested.join("::"), path, discovered) if node.is_a?(Prism::ClassNode) && nested.any?
          collect_sync_actions(node.body, nested, path, discovered)
        end
      end

      def collect_class_actions(node, class_name, path, discovered)
        class_defs = {}
        actions = []
        scan_class_body(node.body, class_defs, actions, path)
        actions.each do |action|
          call = format_sync_action_call(class_name, action, class_defs[action], path)
          discovered << { class_name: class_name, action: action, call: call }
        end
      end
      private_class_method :collect_class_actions

      # Adds the class methods in `body` to `class_defs` by name, and the actions it declares to `actions`.
      def scan_class_body(body, class_defs, actions, path)
        return unless body.is_a?(Prism::StatementsNode)

        body.body.each do |stmt|
          case stmt
          when Prism::DefNode
            class_defs[stmt.name.to_s] = stmt if stmt.receiver.is_a?(Prism::SelfNode)
          when Prism::SingletonClassNode
            if stmt.expression.is_a?(Prism::SelfNode) && stmt.body.is_a?(Prism::StatementsNode)
              stmt.body.body.each do |inner|
                class_defs[inner.name.to_s] = inner if inner.is_a?(Prism::DefNode) && inner.receiver.nil?
              end
            end
          when Prism::CallNode
            next unless stmt.receiver.nil? && stmt.name == :sync_action

            action = declared_action_name(stmt, path)
            actions << action unless actions.include?(action)
          end
        end
      end

      def declared_action_name(call, path)
        at = "#{path}:#{call.location.start_line}"
        literal = call.arguments&.arguments&.first
        unless literal.is_a?(Prism::SymbolNode) || literal.is_a?(Prism::StringNode)
          raise BuildError, "#{at}: sync_action requires a literal symbol or string name."
        end

        name = literal.unescaped
        raise BuildError, "#{at}: Invalid sync_action name #{name.inspect}." unless SYNC_ACTION_NAME_PATTERN.match?(name)

        if call.block
          raise BuildError, "#{at}: sync_action :#{name} cannot use a block in compiled builds; define def self.#{name}(args) instead."
        end
        name
      end
      private_class_method :declared_action_name

      # A class method with named keywords and neither leading positionals nor `**rest` gets
      # each keyword from `args`; a `*rest` is ignored. One with no parameters, or only a
      # block, gets nothing. Any other, or one not defined in the class, gets `args` whole.
      def format_sync_action_call(class_name, action_name, def_node, path)
        target = "#{class_name}.#{action_name}"
        return "#{target}(args)" unless def_node

        params = def_node.parameters
        return target unless params

        positionals = params.requireds + params.optionals
        keywords = params.keywords
        return "#{target}(args)" if positionals.any? || params.keyword_rest || (params.rest && keywords.empty?)
        return target if keywords.empty?

        at = "#{path}:#{def_node.location.start_line}"
        "#{target}(#{keywords.map { |keyword| keyword_argument(keyword, at) }.join(', ')})"
      end

      def keyword_argument(keyword, at)
        name = keyword.name.to_s
        key = JSON.generate(name)
        case keyword
        when Prism::RequiredKeywordParameterNode
          "#{name}: args[#{key}]"
        when Prism::OptionalKeywordParameterNode
          default = literal_expr(keyword.value)
          default ? "#{name}: args.key?(#{key}) ? args[#{key}] : #{default}" : "#{name}: args[#{key}]"
        else
          raise BuildError, "#{at}: Unsupported sync_action keyword parameter."
        end
      end
      private_class_method :keyword_argument

      def literal_expr(node)
        case node
        when Prism::NilNode then "nil"
        when Prism::TrueNode then "true"
        when Prism::FalseNode then "false"
        when Prism::IntegerNode, Prism::FloatNode then node.value.inspect
        when Prism::StringNode then JSON.generate(node.unescaped)
        when Prism::SymbolNode then node.unescaped.to_sym.inspect
        else nil
        end
      end

      def constant_path_parts(node)
        case node
        when Prism::ConstantReadNode
          [node.name.to_s]
        when Prism::ConstantPathNode
          parent = node.parent ? constant_path_parts(node.parent) : []
          return nil unless parent

          parent + [node.name.to_s]
        else
          nil
        end
      end
    end
  end
end
