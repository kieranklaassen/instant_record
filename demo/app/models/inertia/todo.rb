module Inertia
  class Todo < ApplicationRecord
    self.table_name = "inertia_todos"

    validates :title, presence: true, length: { maximum: 200 }
  end
end
