module Hotwire
  class Todo < ApplicationRecord
    self.table_name = "hotwire_todos"

    validates :title, presence: true, length: { maximum: 200 }
  end
end
