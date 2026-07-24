class AddParentMessageToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :parent_message_id, :string
    add_index :messages, [ :parent_message_id, :created_at ]
  end
end
