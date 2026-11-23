module InstantRecord
  # Transforms queued client outbox mutations across schema versions during
  # rolling deploys (both N-1 -> N upcasts and N+1 -> N downcasts).
  #
  # Models declare transforms via `upcast_outbox` (see InstantRecord::Syncable),
  # and apps may also register global or type-level transforms via
  # `InstantRecord.upcast_outbox` (useful for record_type renames).
  module OutboxUpcaster
    class << self
      def registry
        @registry ||= []
      end

      def register(record_type = nil, from: nil, to: nil, operation: nil, &block)
        raise ArgumentError, "upcast_outbox requires a block" unless block

        registry << {
          record_type: record_type&.to_s,
          from: normalize_version(from),
          to: normalize_version(to),
          operation: normalize_operations(operation),
          transform: block
        }
        nil
      end

      def clear!
        registry.clear
      end

      # Apply global upcasters (may rewrite record_type and/or changes).
      # Returns [updated_mutation_hash, updated_changes_hash].
      def apply_global(mutation, changes)
        working_mutation = normalize_mutation(mutation)
        working_changes = stringify_hash(changes)
        version = normalize_version(working_mutation[:schema_version])

        registry.each do |rule|
          next if rule[:record_type] && rule[:record_type] != working_mutation[:record_type].to_s
          next unless applicable?(rule, working_mutation[:operation], version)

          working_changes = invoke(rule[:transform], working_changes, working_mutation)
          version = advance_version(rule, version)
          working_mutation[:schema_version] = version if version
        end

        [working_mutation, working_changes]
      end

      # Apply model-declared `upcast_outbox` transforms to a changes hash.
      def apply_for_model(model, changes, mutation = {})
        return stringify_hash(changes) unless model.respond_to?(:instant_record_outbox_upcasters)

        rules = model.instant_record_outbox_upcasters
        return stringify_hash(changes) if rules.empty?

        working_mutation = normalize_mutation(mutation)
        working_changes = stringify_hash(changes)
        version = normalize_version(working_mutation[:schema_version])

        rules.each do |raw_rule|
          rule = normalize_rule(raw_rule)
          next unless applicable?(rule, working_mutation[:operation], version)

          working_changes = invoke(rule[:transform], working_changes, working_mutation)
          version = advance_version(rule, version)
          working_mutation[:schema_version] = version if version
        end

        working_changes
      end

      private

      def normalize_mutation(mutation)
        hash = mutation.respond_to?(:to_h) ? mutation.to_h : {}
        hash.transform_keys(&:to_sym)
      end

      def stringify_hash(hash)
        (hash || {}).to_h.transform_keys(&:to_s)
      end

      def normalize_version(value)
        return nil if value.nil? || value.to_s.strip.empty?

        Integer(value.to_s, 10)
      end

      def normalize_operations(operation)
        return nil if operation.nil?

        Array(operation).map(&:to_s)
      end

      def normalize_rule(rule)
        {
          from: normalize_version(rule[:from]),
          to: normalize_version(rule[:to]),
          operation: normalize_operations(rule[:operation]),
          transform: rule[:transform]
        }
      end

      def applicable?(rule, operation, version)
        if rule[:operation] && !rule[:operation].include?(operation.to_s)
          return false
        end

        from = rule[:from]
        to = rule[:to]
        return true if from.nil? && to.nil?
        # Legacy/N-1 clients that predate schema_version tagging still run
        # versioned upcasters so their queued mutations are rescued.
        return true if version.nil?

        if from && to
          if from < to
            version < to
          elsif from > to
            version > to
          else
            version == from
          end
        elsif to
          version < to
        else
          version == from
        end
      end

      def advance_version(rule, version)
        return nil if version.nil?

        rule[:to] || version
      end

      def invoke(transform, changes, mutation)
        working = changes.dup
        result =
          case transform.arity
          when 0 then transform.call
          when 1 then transform.call(working)
          else transform.call(working, mutation)
          end
        (result.is_a?(Hash) ? result : working).transform_keys(&:to_s)
      end
    end
  end

  class << self
    # Register a global (or record_type-scoped) outbox upcaster.
    def upcast_outbox(record_type = nil, from: nil, to: nil, operation: nil, &block)
      OutboxUpcaster.register(record_type, from: from, to: to, operation: operation, &block)
    end

    def clear_outbox_upcasters!
      OutboxUpcaster.clear!
    end
  end
end
