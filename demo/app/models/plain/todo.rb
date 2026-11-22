module Plain
  class Todo < ApplicationRecord
    self.table_name = "plain_todos"

    validates :title, presence: true, length: { maximum: 200 }
  end
end
