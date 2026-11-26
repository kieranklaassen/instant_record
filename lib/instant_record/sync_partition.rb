module InstantRecord
  # Multi-tenant partition declaration on a Syncable model (`sync_partition :column`).
  # Partitioned models sync only when a request selects a matching partition,
  # keeping per-account / per-workspace rows and change feeds isolated.
  class SyncPartition
    attr_reader :model, :column, :name

    def initialize(model, column, name: nil)
      @model = model
      @column = column.to_s
      @name = (name || column).to_s
    end

    # Extracts the partition value for this model from a client-supplied
    # specifier, or returns nil when the specifier does not apply to this model.
    #
    # Accepted forms:
    #   "support"                        -> "support"
    #   "mailbox_id:support"             -> "support" (matches name or column)
    #   "mailbox_id=support"             -> "support" (matches name or column)
    #   { "mailbox_id" => "support" }    -> "support" (Hash keyed by name or column)
    def extract(spec)
      return nil if spec.nil?

      if spec.is_a?(Hash)
        value = spec[@name]
        value = spec[@name.to_sym] if value.nil?
        value = spec[@column] if value.nil?
        value = spec[@column.to_sym] if value.nil?
        text = value.to_s
        return text.empty? ? nil : text
      end

      raw = spec.to_s.strip
      return nil if raw.empty?

      if raw.include?(":")
        prefix, value = raw.split(":", 2)
        return (prefix == @name || prefix == @column) && !value.to_s.empty? ? value : nil
      elsif raw.include?("=")
        prefix, value = raw.split("=", 2)
        return (prefix == @name || prefix == @column) && !value.to_s.empty? ? value : nil
      end

      raw
    end

    # Canonical key stored on InstantRecord::Change#partition so two models
    # partitioned by different columns never collide.
    def change_key(value)
      text = value.to_s
      text.empty? ? nil : "#{@name}:#{text}"
    end

    # A compiled model's `[]` takes a Symbol only.
    def change_partition_for(record)
      change_key(record[@column.to_sym])
    end

    def scope_relation(relation, value)
      relation.where(@column => value)
    end
  end
end
