module InstantRecord
  # Server-side ordered change log. The auto-increment id is the SSE cursor.
  class Change < ActiveRecord::Base
    self.table_name = "instant_record_changes"

    serialize :attributes_payload, coder: JSON

    scope :after, ->(cursor) { where("id > ?", cursor.to_i).order(:id) }

    def as_event
      {
        type: record_type,
        id: record_id,
        operation: operation,
        version: version,
        attributes: attributes_payload
      }
    end
  end
end
