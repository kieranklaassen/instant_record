module InstantRecord
  module Native
    # Raised in CRuby / tests when a screen's rendered `swift` / `component`
    # node does not match the typed contract declared on that screen.
    class ContractError < StandardError; end

    # One scalar, nested object, or list field in a typed native prop contract.
    class ContractField
      SCALAR_TYPES = %w[string int float bool date].freeze
      KINDS = %i[scalar one many many_scalar].freeze

      attr_reader :name, :kind, :type, :optional, :type_name, :fields

      def initialize(name:, kind:, type: nil, optional: false, type_name: nil, fields: [])
        @name = name.to_s
        @kind = kind
        @type = type&.to_s
        @optional = !!optional
        @type_name = type_name&.to_s
        @fields = fields.freeze
        validate_definition!
      end

      def optional? = @optional
      def scalar? = @kind == :scalar
      def one? = @kind == :one
      def many? = @kind == :many
      def many_scalar? = @kind == :many_scalar

      def ==(other)
        other.is_a?(ContractField) &&
          name == other.name &&
          kind == other.kind &&
          type == other.type &&
          optional == other.optional &&
          type_name == other.type_name &&
          fields == other.fields
      end

      private

      def validate_definition!
        unless @name.match?(/\A[a-z][a-zA-Z0-9_]*\z/)
          raise ArgumentError, "Invalid contract field name #{@name.inspect}: use lowerCamelCase or snake_case starting with a letter"
        end
        unless KINDS.include?(@kind)
          raise ArgumentError, "Unknown contract field kind #{@kind.inspect}"
        end
        if (@kind == :scalar || @kind == :many_scalar) && !SCALAR_TYPES.include?(@type)
          raise ArgumentError, "Unknown contract type #{@type.inspect} for field #{@name.inspect} (expected one of #{SCALAR_TYPES.join(', ')})"
        end
        if @type_name && !@type_name.match?(/\A[A-Z][A-Za-z0-9]*\z/)
          raise ArgumentError, "Invalid nested type name #{@type_name.inspect} for field #{@name.inspect}: use PascalCase"
        end
      end
    end

    # One typed parameter on a native action, carried either in `args` or `values`.
    class ActionParam
      SLOTS = %i[arg value].freeze

      attr_reader :name, :type, :slot, :optional

      def initialize(name:, type: "string", slot: :arg, optional: false)
        @name = name.to_s
        @type = type.to_s
        @slot = slot
        @optional = !!optional

        unless @name.match?(/\A[a-z][a-zA-Z0-9_]*\z/)
          raise ArgumentError, "Invalid action parameter name #{@name.inspect}"
        end
        unless ContractField::SCALAR_TYPES.include?(@type)
          raise ArgumentError, "Unknown action parameter type #{@type.inspect} for #{@name.inspect}"
        end
        unless SLOTS.include?(@slot)
          raise ArgumentError, "Unknown action parameter slot #{@slot.inspect}"
        end
      end

      def optional? = @optional
      def arg? = @slot == :arg
      def value? = @slot == :value

      def ==(other)
        other.is_a?(ActionParam) &&
          name == other.name &&
          type == other.type &&
          slot == other.slot &&
          optional == other.optional
      end
    end

    # One typed action a native view can dispatch back to its Ruby screen.
    class ContractAction
      attr_reader :name, :params

      def initialize(name:, params: [])
        @name = name.to_s
        @params = params.freeze
        unless @name.match?(/\A[a-z][a-zA-Z0-9_]*\z/)
          raise ArgumentError, "Invalid contract action name #{@name.inspect}"
        end
      end

      def args = @params.select(&:arg?)
      def values = @params.select(&:value?)

      def ==(other)
        other.is_a?(ContractAction) && name == other.name && params == other.params
      end
    end

    # A declarative typed prop and action contract for a native view component
    # (SwiftUI / Jetpack Compose), acting as the single source of truth for
    # CRuby runtime validation and Prism codegen into Swift/Kotlin.
    class Contract
      attr_reader :component, :screen, :fields, :actions

      def initialize(component:, fields: [], actions: [], screen: nil)
        @component = component.to_s
        @screen = screen&.to_s
        @fields = fields.freeze
        @actions = actions.freeze
        unless @component.match?(/\A[A-Z][A-Za-z0-9]*\z/)
          raise ArgumentError, "Invalid native component name #{@component.inspect}: use PascalCase (e.g. ConversationView)"
        end
      end

      def ==(other)
        other.is_a?(Contract) &&
          component == other.component &&
          fields == other.fields &&
          actions == other.actions
      end

      # Validate a rendered `swift` Node against this contract's fields.
      def validate!(node)
        validate_fields!(node, @fields, @component)
      end

      private

      def validate_fields!(node, expected_fields, path, by_name = index_fields(expected_fields))
        seen = {}

        node.children.each do |child|
          field =
            case child.kind
            when "prop" then validate_prop!(child, by_name, path)
            when "record" then validate_record!(child, by_name, path)
            when "props" then validate_list!(child, by_name, path)
            else raise ContractError, "#{path}: unexpected child node kind #{child.kind.inspect}"
            end
          seen[field.name] = true
        end

        expected_fields.each do |field|
          next if field.optional? || seen[field.name]

          raise ContractError, "#{path}: missing required prop #{field.name.inspect} (#{field.kind == :scalar ? field.type : field.kind})"
        end
      end

      def validate_prop!(node, by_name, path)
        field = declared_field!(node, by_name, path, "prop".freeze)
        raise ContractError, "#{path}.#{field.name}: expected #{field.kind} but emitted scalar prop" unless field.scalar?

        validate_type!(node, field) { "#{path}.#{field.name}" }
        field
      end

      def validate_record!(node, by_name, path)
        field = declared_field!(node, by_name, path, "nested record".freeze)
        field_path = "#{path}.#{field.name}"
        raise ContractError, "#{field_path}: expected #{field.kind} but emitted nested record" unless field.one?

        validate_fields!(node, field.fields, field_path)
        field
      end

      def validate_list!(node, by_name, path)
        field = declared_field!(node, by_name, path, "list prop".freeze)
        field_path = "#{path}.#{field.name}"
        raise ContractError, "#{field_path}: expected #{field.kind} but emitted list" unless field.many? || field.many_scalar?

        by_item_name = nil
        node.children.each_with_index do |item, index|
          if field.many?
            raise ContractError, "#{field_path}[#{index}]: expected record item, got #{item.kind.inspect}" unless item.kind == "record"

            by_item_name ||= index_fields(field.fields)
            validate_fields!(item, field.fields, "#{field_path}[#{index}]", by_item_name)
          else
            raise ContractError, "#{field_path}[#{index}]: expected scalar prop item, got #{item.kind.inspect}" unless item.kind == "prop"

            validate_type!(item, field) { "#{field_path}[#{index}]" }
          end
        end
        field
      end

      def index_fields(fields)
        fields.each_with_object({}) { |field, map| map[field.name] = field }
      end

      def declared_field!(node, by_name, path, label)
        name = node.props["name"].to_s
        by_name[name] || raise(ContractError, "#{path}: undeclared #{label} #{name.inspect}")
      end

      def validate_type!(node, field)
        actual_type = node.props["type"].to_s
        return if actual_type == field.type

        raise ContractError, "#{yield}: expected type #{field.type.inspect}, got #{actual_type.inspect}"
      end
    end

    # Plain-Ruby builder yielded to `contract "Name" do |c| ... end`.
    class ContractBuilder
      def initialize(component, screen: nil, nested: false)
        @component = component
        @screen = screen
        @nested = nested
        @fields = []
        @field_names = {}
        @actions = []
        @action_names = {}
      end

      def prop(name, type = :string, optional: false)
        add_field(ContractField.new(name: name, kind: :scalar, type: type, optional: optional))
      end

      def string(name, optional: false) = prop(name, :string, optional: optional)
      def int(name, optional: false) = prop(name, :int, optional: optional)
      def float(name, optional: false) = prop(name, :float, optional: optional)
      def bool(name, optional: false) = prop(name, :bool, optional: optional)
      def date(name, optional: false) = prop(name, :date, optional: optional)

      def one(name, as: nil, optional: false)
        raise ArgumentError, "one #{name.inspect} requires a block describing its fields" unless block_given?

        nested = ContractBuilder.new(@component, screen: @screen, nested: true)
        yield nested
        add_field(ContractField.new(name: name, kind: :one, optional: optional, type_name: as, fields: nested.fields))
      end

      def many(name, of: nil, as: nil, optional: false)
        if of
          raise ArgumentError, "many #{name.inspect} with of: cannot also take a block" if block_given?

          add_field(ContractField.new(name: name, kind: :many_scalar, type: of, optional: optional))
        else
          raise ArgumentError, "many #{name.inspect} requires either of: or a block" unless block_given?

          nested = ContractBuilder.new(@component, screen: @screen, nested: true)
          yield nested
          add_field(ContractField.new(name: name, kind: :many, optional: optional, type_name: as, fields: nested.fields))
        end
      end

      def action(name)
        raise ArgumentError, "Actions may only be declared at the top level of a contract" if @nested

        key = name.to_s
        raise ArgumentError, "Duplicate contract action #{key.inspect} in #{@component}" if @action_names[key]

        builder = ActionBuilder.new(key)
        yield builder if block_given?
        @action_names[key] = true
        @actions << builder.build
      end

      def fields = @fields

      def build
        Contract.new(component: @component, fields: @fields, actions: @actions, screen: @screen)
      end

      private

      def add_field(field)
        if @field_names[field.name]
          raise ArgumentError, "Duplicate contract field #{field.name.inspect} in #{@component}"
        end
        @field_names[field.name] = true
        @fields << field
      end
    end

    # Plain-Ruby builder yielded to `c.action :reply do |a| ... end`.
    class ActionBuilder
      def initialize(name)
        @name = name
        @params = []
        @param_names = {}
      end

      def arg(name, type = :string, optional: false)
        add_param(ActionParam.new(name: name, type: type, slot: :arg, optional: optional))
      end

      def value(name, type = :string, optional: false)
        add_param(ActionParam.new(name: name, type: type, slot: :value, optional: optional))
      end

      def build
        ContractAction.new(name: @name, params: @params)
      end

      private

      def add_param(param)
        if @param_names[param.name]
          raise ArgumentError, "Duplicate action parameter #{param.name.inspect} in action #{@name}"
        end
        @param_names[param.name] = true
        @params << param
      end
    end

    # Mixin loaded only in CRuby (not vendored into Spinel builds) that adds
    # class-level `contract` declarations and render-time contract validation
    # onto InstantRecord::Native::Screen.
    module ScreenContracts
      module ClassMethods
        def contracts
          @contracts ||= {}
        end

        def contract(name)
          builder = ContractBuilder.new(name.to_s, screen: self.name)
          yield builder if block_given?
          built = builder.build
          if contracts.key?(built.component)
            raise ArgumentError, "Duplicate contract #{built.component.inspect} on #{self.name || 'Screen'}"
          end
          contracts[built.component] = built
        end
      end

      def render
        root = super
        validate_contracts!(root)
        root
      end

      private

      def validate_contracts!(root)
        declared = self.class.contracts
        return if declared.empty?

        validate_tree_contracts!(root, declared)
      end

      def validate_tree_contracts!(node, declared)
        if node.kind == "swift"
          contract = declared[node.text]
          contract.validate!(node) if contract
        else
          node.children.each { |child| validate_tree_contracts!(child, declared) }
        end
      end
    end

    Screen.extend(ScreenContracts::ClassMethods)
    Screen.prepend(ScreenContracts)
  end
end
